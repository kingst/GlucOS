//
//  PhysiologicalModels.swift
//  BioKernel
//
//  Created by Sam King on 1/18/24.
//

import Foundation
import LoopKit

public struct PIDTempBasalResult: Codable {
    public let at: Date
    public let Kp: Double
    public let Ki: Double
    public let Kd: Double
    public let error: Double
    public let tempBasal: Double
    public let accumulatedError: Double
    public let derivative: Double?
    public let lastGlucose: Double?
    public let lastGlucoseAt: Date?
    public let deltaGlucoseError: Double?
    
    public init(at: Date, Kp: Double, Ki: Double, Kd: Double, error: Double, tempBasal: Double, accumulatedError: Double, derivative: Double?, lastGlucose: Double?, lastGlucoseAt: Date?, deltaGlucoseError: Double?) {
        self.at = at
        self.Kp = Kp
        self.Ki = Ki
        self.Kd = Kd
        self.error = error
        self.tempBasal = tempBasal
        self.accumulatedError = accumulatedError
        self.derivative = derivative
        self.lastGlucose = lastGlucose
        self.lastGlucoseAt = lastGlucoseAt
        self.deltaGlucoseError = deltaGlucoseError
    }
}

public protocol PhysiologicalModels {
    func tempBasal(settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [AddedGlucoseDataRow]?, at: Date) async -> PIDTempBasalResult
    func predictGlucoseIn15Minutes(from: Date) async -> Double?
    func deltaGlucoseError(settings: CodableSettings, dataFrame: [AddedGlucoseDataRow]?, at: Date) async -> Double?
}

struct PhysiologicalUtilities {
    static func calculateBasalBaselineInsulinOnBoard(basalRate: Double, insulinType: InsulinType) -> Double {
        let now = Date()
        // we use basalBaselineInsulinOnBoard to figure out how much iob we should have in steady state
        // when we're operating at our basal rate
        return DoseEntry(type: .basal, startDate: now - 6.hoursToSeconds(), endDate: now, value: basalRate, unit: .unitsPerHour, insulinType: insulinType, isMutable: false).insulinOnBoard(at: now)
    }
}

actor LocalPhysiologicalModels: PhysiologicalModels {
    func predictGlucoseIn15Minutes(from now: Date) async -> Double? {
        let glucoseFull = await getGlucoseStorage().readingsBetween(startDate: now - 30.minutesToSeconds(), endDate: now).sorted { $0.date < $1.date }
        
        // we need at least 2 data points to make a prediction
        guard glucoseFull.count >= 2 else { return nil }
        
        // grab up to 5 of the most recent readings
        let glucose = {
            if glucoseFull.count > 5 {
                return Array(glucoseFull.dropFirst(glucoseFull.count - 5))
            } else {
                return glucoseFull
            }
        }()
        
        let x = glucose.map { $0.date.timeIntervalSince(now) }
        let y = glucose.map { $0.quantity.doubleValue(for: .milligramsPerDeciliter) }
        
        guard let (slope, intercept) = MLUtilities.leastSquaresFit(x: x, y: y) else { return nil }
        let prediction = 15.minutesToSeconds() * slope + intercept
        return prediction
    }
    
    static let shared = LocalPhysiologicalModels()
    
    var lastGlucose: Double?
    var lastGlucoseAt: Date?
    var accumulatedError = 0.0
    
    func deltaGlucoseError(settings: CodableSettings, dataFrame: [AddedGlucoseDataRow]?, at: Date) -> Double? {
        let numSteps = 4
        let digestionThreshold = 40.0
        
        guard let dataFrame = dataFrame else { return nil }
        let frame = dataFrame.dropFirst(dataFrame.count - numSteps - 1)
        assert(frame.count == (numSteps+1))
        guard let first = frame.first, let last = frame.last else { return nil }
        
        let deltaGlucose = (last.glucose - first.glucose) * 12 / Double(numSteps)
        let insulinDelivered = frame.dropFirst().map({ $0.insulinDelivered }).reduce(0, +)
        let insulinActive = first.insulinOnBoard - last.insulinOnBoard + insulinDelivered
        
        let basalRate = settings.learnedBasalRate(at: at)
        let insulinSensitivity  = settings.learnedInsulinSensitivity(at: at)
        let basalInsulin =  basalRate * Double(numSteps) / 12
        let theoreticalDeltaGlucose = ((basalInsulin - insulinActive) * insulinSensitivity) * 12 / Double(numSteps)
        
        print("PID> bi: \(basalInsulin) ia: \(insulinActive)")
        print("PID> dg: \(deltaGlucose) tdg: \(theoreticalDeltaGlucose)")
        
        let error = deltaGlucose - theoreticalDeltaGlucose
        guard error < digestionThreshold else { return nil }
        
        return error
    }
    
    func tempBasal(settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [AddedGlucoseDataRow]?, at: Date) async -> PIDTempBasalResult {
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: at)
        let correctionDuration = settings.correctionDurationInSeconds
        let basalRate = settings.learnedBasalRate(at: at)
        let insulinType = await getInsulinStorage().currentInsulinType()
        let basalBaselineInsulinOnBoard = PhysiologicalUtilities .calculateBasalBaselineInsulinOnBoard(basalRate: basalRate, insulinType: insulinType)
        let deltaGlucoseError = deltaGlucoseError(settings: settings, dataFrame: dataFrame, at: at)
        
        // PID controller
        let error = glucoseInMgDl - targetGlucoseInMgDl
        var derivative = 0.0
        if let dt = lastGlucoseAt.map({ at.timeIntervalSince($0) }), dt < 11.minutesToSeconds(), let lastGlucose = lastGlucose {
            // these are slighly non-standard for PID but we do it this
            // way to keep our derivative and integral in glucose units
            // to make it easier to set Ki and Kd
            derivative = (glucoseInMgDl - lastGlucose)
            
            // with this check we're trying to only accumulate errors
            // when we're outside of digestion and accumulate deltaGlucose
            // errors rather than target glucose errors
            if let deltaGlucoseError = deltaGlucoseError {
                accumulatedError += deltaGlucoseError
                accumulatedError = accumulatedError.clamp(low: -240, high: 240)
            }
        }
        
        let Kp = 1.0
        let Ki = settings.getPidIntegratorGain()
        let Kd = settings.getPidDerivativeGain()
        
        let pidOutput = Kp * error + Ki * accumulatedError + Kd * derivative
        print("PID> error: \(error) accumulatedError: \(accumulatedError) derivative: \(derivative) pidOutput: \(pidOutput)")
        print("PID> IoB: \(insulinOnBoard) basalIoB: \(basalBaselineInsulinOnBoard)")
        
        let insulinNeeded = pidOutput / insulinSensitivity
        // this is a form of clamping to deal with integrator anti-windup
        // What happens is if someone goes below the safety threshold and
        // their IoB drops below the basalBaselineInsulinOnBoard then when
        // they come back above the safety threshold the system will try
        // to deliver a bunch of insulin at exactly the wrong time. This
        // check fixes that problem.
        let netInsulin = max(insulinOnBoard - basalBaselineInsulinOnBoard, 0)
        let correctionAmount = insulinNeeded - netInsulin
        // add the basalRate back in so that our default when the correctionAmount is 0 is basalRate
        let tempBasal = correctionAmount * 1.hoursToSeconds() / correctionDuration + basalRate
        
        let result = PIDTempBasalResult(at: at, Kp: Kp, Ki: Ki, Kd: Kd, error: error, tempBasal: tempBasal, accumulatedError: accumulatedError, derivative: derivative, lastGlucose: lastGlucose, lastGlucoseAt: lastGlucoseAt, deltaGlucoseError: deltaGlucoseError)
        lastGlucose = glucoseInMgDl
        lastGlucoseAt = at
        
        return result
    }
}
