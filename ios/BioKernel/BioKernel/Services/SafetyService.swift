//
//  SafetyService.swift
//  BioKernel
//
//  Created by Sam King on 1/18/24.
//

import Foundation
import LoopKit

protocol SafetyService {
    func tempBasal(at: Date, safetyTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async -> SafetyTempBasal
    func updateAfterProgrammingPump(at: Date, programmedTempBasalUnitsPerHour: Double, safetyTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval, programmedMicroBolus: Double, safetyMicroBolus: Double, machineLearningMicroBolus: Double, biologicalInvariantViolation: Bool) async
}

struct SafetyTempBasal {
    let tempBasal: Double
    let machineLearningInsulinLastThreeHours: Double
}

public struct SafetyState: Codable {
    let at: Date
    let duration: TimeInterval
    let programmedTempBasalUnitsPerHour: Double
    let safetyTempBasalUnitsPerHour: Double
    let machineLearningTempBasalUnitsPerHour: Double
    let programmedMicroBolus: Double
    let safetyMicroBolus: Double
    let machineLearningMicroBolus: Double
    let biologicalInvariantViolation: Bool
    
    private func deltaUnitsTempBasal(from: Date, to: Date) -> Double {
        guard !safetyTempBasalUnitsPerHour.roughlyEqual(to: programmedTempBasalUnitsPerHour) else { return 0.0 }
        let start = max(at, from)
        let end = min(at + duration, to)
        // make sure that this temp basal command ran for at least 1 second
        guard end > (start + 1) else { return 0.0 }
        let durationInSeconds = end.timeIntervalSince(start)
        let deltaTempBasal = programmedTempBasalUnitsPerHour - safetyTempBasalUnitsPerHour
        return deltaTempBasal * durationInSeconds / 1.hoursToSeconds()
    }
    
    private func deltaUnitsMicroBolus(from: Date, to: Date) -> Double {
        guard !safetyMicroBolus.roughlyEqual(to: programmedMicroBolus) else { return 0.0 }
        guard at >= from, at < to else { return 0.0 }
        return programmedMicroBolus - safetyMicroBolus
    }
    
    func deltaUnitsDeliveredByMachineLearning(from: Date, to: Date) -> Double {
        return deltaUnitsTempBasal(from: from, to: to) + deltaUnitsMicroBolus(from: from, to: to)
    }
}

actor LocalSafetyService: SafetyService {
    static let shared = LocalSafetyService()
    
    // FIXME: these should all be settings
    let upperBoundInsulinUnits: Double
    let lowerBoundInsulinUnits: Double
    let timeHorizon: TimeInterval
    
    var safetyStates: [SafetyState]
    private let storage = getStoredObject().create(fileName: "safety_states.json")
    
    init() {
        safetyStates = (try? storage.read()) ?? []
        upperBoundInsulinUnits = 9.0
        lowerBoundInsulinUnits = -9.0
        timeHorizon = 3.hoursToSeconds()
    }
    
    init(lowerBoundInsulinUnits: Double, upperBoundInsulinUnits: Double) {
        safetyStates = (try? storage.read()) ?? []
        self.upperBoundInsulinUnits = upperBoundInsulinUnits
        self.lowerBoundInsulinUnits = lowerBoundInsulinUnits
        timeHorizon = 3.hoursToSeconds()
    }
    
    static func forUnitTests() -> LocalSafetyService {
        return LocalSafetyService(lowerBoundInsulinUnits: -3, upperBoundInsulinUnits: 2)
    }
    
    // Note: we ignore actual insulin delivered and use the
    // programmed values for the safety service
    func tempBasal(at: Date, safetyTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async ->  SafetyTempBasal {
        
        let start = at - timeHorizon
        let events = safetyStates.filter { $0.at >= (start - duration) && $0.at < at }

        let nextTimes = events.dropFirst().map { $0.at } + [at]
        var historicalMlInsulin = 0.0
        for (event, nextTime) in zip(events, nextTimes) {
            historicalMlInsulin += event.deltaUnitsDeliveredByMachineLearning(from: start, to: nextTime)
        }
                
        // convert tempBasal rates to units of insulin, assuming it runs for the entire 30m
        let mlTempBasalUnits = machineLearningTempBasalUnitsPerHour * duration / 1.hoursToSeconds()
        let safetyTempBasalUnits = safetyTempBasalUnitsPerHour * duration / 1.hoursToSeconds()
        
        // make sure that the upperBound doesn't go below 0
        // and that the lowerBound doesn't go above 0
        let upperBound = max(upperBoundInsulinUnits - historicalMlInsulin, 0)
        let lowerBound = min(lowerBoundInsulinUnits - historicalMlInsulin, 0)
        let deltaUnits = (mlTempBasalUnits - safetyTempBasalUnits).clamp(low: lowerBound, high: upperBound)

        // now convert units back to tempBasal and add it to our safety value
        let deltaTempBasal = deltaUnits * 1.hoursToSeconds() / duration
        
        return SafetyTempBasal(tempBasal: safetyTempBasalUnitsPerHour + deltaTempBasal,
                               machineLearningInsulinLastThreeHours: historicalMlInsulin)
    }
    
    func updateAfterProgrammingPump(at: Date, programmedTempBasalUnitsPerHour: Double, safetyTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval, programmedMicroBolus: Double, safetyMicroBolus: Double, machineLearningMicroBolus: Double, biologicalInvariantViolation: Bool) async {

        safetyStates.append(SafetyState(at: at, duration: duration, programmedTempBasalUnitsPerHour: programmedTempBasalUnitsPerHour, safetyTempBasalUnitsPerHour: safetyTempBasalUnitsPerHour, machineLearningTempBasalUnitsPerHour: machineLearningTempBasalUnitsPerHour, programmedMicroBolus: programmedMicroBolus, safetyMicroBolus: safetyMicroBolus, machineLearningMicroBolus: machineLearningMicroBolus, biologicalInvariantViolation: biologicalInvariantViolation))

        // Only keep 24 hours worth of data
        safetyStates = safetyStates.sorted { $0.at < $1.at }
        if let mostRecent = safetyStates.last {
            safetyStates = safetyStates.filter { $0.at >= (mostRecent.at - 24.hoursToSeconds()) }
        }
        
        try? storage.write(safetyStates)
    }
}
