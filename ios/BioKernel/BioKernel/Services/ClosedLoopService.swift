//
//  ClosedLoopService.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//
// Here is the logic from Loop
// checkPumpAndLoop:
//   - ensureCurrentPumpData
//   - loop
//
// refreshCgm: (aka checkCgmAndLoop)
//   - fetches data from the CGM explicitly
//   - processes the new readings
//   - checkPumpAndLoop if it's been > 6 minutes since the last loop
//
// pumpManagerBLEHeartbeatDidFire (the pump will limit to > 2m between calls):
//   - refreshCGM
//   - NOTE: I think the use 2 minutes to get closer to a CGM reading
//
// refreshDeviceData (called by the LoopUI)
//   - refreshCGM
//   - ensureCurrentPumpData
//
// cgmManagerHasNewReadings: (called by the CGM, only happens every 5 minutes)
//    - process the new readings
//    - checkPumpAndLoop
//
// So in other words
//    - if we get a pump heartbeat, get the latest CGM readings and run at most every 4.2 minutes
//    - if we get a CGM event, get the latest pump readings and run (it'll only happen every 5 minutes)
//    - if the UI requests a refresh, refresh the CGM data, loop if at least 4.2 minutes since the last run, then get pump data

import Foundation
import LoopKit

protocol ClosedLoopService {
    func loop(at: Date) async -> Bool
    func latestClosedLoopResult() async -> ClosedLoopResult?
}

public enum ClosedLoopAction: String, Codable {
    case setTempBasal
    case openLoop
    case glucoseReadingStale
    case pumpReadingStale
    case noPumpManager
    case pumpError
}

public struct SafetyResult: Codable {
    let machineLearningTempBasal: Double
    let physiologicalTempBasal: Double
    let tempBasalAfterSafetyChecks: Double
    let machineLearningMicroBolus: Double
    let physiologicalMicroBolus: Double
    let actualMicroBolus: Double
    let machineLearningInsulinLastThreeHours: Double
    let biologicalInvariantMgDlPerHour: Double?
    let biologicalInvariantViolation: Bool
    
    static func withTempBasal(machineLearningTempBasal: Double, physiologicalTempBasal: Double, tempBasalAfterSafetyChecks: Double, machineLearningInsulinLastThreeHours: Double, biologicalInvariantMgDlPerHour: Double?) -> SafetyResult {
        
        return SafetyResult(machineLearningTempBasal: machineLearningTempBasal, physiologicalTempBasal: physiologicalTempBasal, tempBasalAfterSafetyChecks: tempBasalAfterSafetyChecks, machineLearningMicroBolus: 0.0, physiologicalMicroBolus: 0.0, actualMicroBolus: 0.0, machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariantMgDlPerHour, biologicalInvariantViolation: false)
    }
    
    static func withMicroBolus(machineLearningMicroBolus: Double, physiologicalMicroBolus: Double, actualMicroBolus: Double, machineLearningInsulinLastThreeHours: Double, biologicalInvariantMgDlPerHour: Double?) -> SafetyResult {

        return SafetyResult(machineLearningTempBasal: 0.0, physiologicalTempBasal: 0.0, tempBasalAfterSafetyChecks: 0.0, machineLearningMicroBolus: machineLearningMicroBolus, physiologicalMicroBolus: physiologicalMicroBolus, actualMicroBolus: actualMicroBolus, machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariantMgDlPerHour, biologicalInvariantViolation: false)
    }
    
    static func withBiologicalInvariantViolation(biologicalInvariantMgDlPerHour: Double, machineLearningInsulinLastThreeHours: Double) -> SafetyResult {
        return SafetyResult(machineLearningTempBasal: 0, physiologicalTempBasal: 0, tempBasalAfterSafetyChecks: 0, machineLearningMicroBolus: 0, physiologicalMicroBolus: 0, actualMicroBolus: 0, machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariantMgDlPerHour, biologicalInvariantViolation: true)
    }
}

public struct ClosedLoopResult: Codable {
    let at: Date
    let action: ClosedLoopAction
    let settings: CodableSettings
    let glucoseInMgDl: Double?
    let predictedGlucoseInMgDl: Double?
    let insulinOnBoard: Double?
    let insulinSensitivity: Double?
    let basalRate: Double?
    let tempBasal: Double?
    let shadowTempBasal: Double?
    let shadowPredictedAddedGlucose: Double?
    let shadowMlAddedGlucose: Double?
    let shadowAddedGlucoseDataFrame: [AddedGlucoseDataRow]?
    let safetyResult: SafetyResult?
    let durationInSeconds: TimeInterval
    let mlDurationInSeconds: TimeInterval
    let safetyDurationInSeconds: TimeInterval
    let proportionalControllerDurationInSeconds: TimeInterval
    let microBolusAmount: Double?
    let cgmPumpMetadata: CgmPumpMetadata
    let pidTempBasalResult: PIDTempBasalResult?
    
    init(at: Date, action: ClosedLoopAction, settings: CodableSettings, glucoseInMgDl: Double?, predictedGlucoseInMgDl: Double?, insulinOnBoard: Double?, insulinSensitivity: Double?, basalRate: Double?, tempBasal: Double?, shadowTempBasal: Double?, shadowPredictedAddedGlucose: Double?, shadowMlAddedGlucose: Double?, shadowAddedGlucoseDataFrame: [AddedGlucoseDataRow]?, safetyResult: SafetyResult?, mlDuration: TimeInterval, safetyDuration: TimeInterval, proportionalControllerDuration: TimeInterval, microBolusAmount: Double?, cgmPumpMetadata: CgmPumpMetadata, pidTempBasalResult: PIDTempBasalResult?) {
        self.at = at
        self.action = action
        self.settings = settings
        self.glucoseInMgDl = glucoseInMgDl
        self.predictedGlucoseInMgDl = predictedGlucoseInMgDl
        self.insulinOnBoard = insulinOnBoard
        self.insulinSensitivity = insulinSensitivity
        self.basalRate = basalRate
        self.tempBasal = tempBasal
        self.shadowTempBasal = shadowTempBasal
        self.shadowPredictedAddedGlucose = shadowPredictedAddedGlucose
        self.shadowMlAddedGlucose = shadowMlAddedGlucose
        self.shadowAddedGlucoseDataFrame = shadowAddedGlucoseDataFrame
        self.safetyResult = safetyResult
        self.durationInSeconds = Date().timeIntervalSince(self.at)
        self.mlDurationInSeconds = mlDuration
        self.safetyDurationInSeconds = safetyDuration
        self.proportionalControllerDurationInSeconds = proportionalControllerDuration
        self.microBolusAmount = microBolusAmount
        self.cgmPumpMetadata = cgmPumpMetadata
        self.pidTempBasalResult = pidTempBasalResult
    }
    
    static func withError(at: Date, action: ClosedLoopAction, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata) -> ClosedLoopResult {
        return ClosedLoopResult(at: at, action: action, settings: settings, glucoseInMgDl: nil, predictedGlucoseInMgDl: nil, insulinOnBoard: nil, insulinSensitivity: nil, basalRate: nil, tempBasal: nil, shadowTempBasal: nil, shadowPredictedAddedGlucose: nil, shadowMlAddedGlucose: nil, shadowAddedGlucoseDataFrame: nil, safetyResult: nil, mlDuration: 0, safetyDuration: 0, proportionalControllerDuration: 0, microBolusAmount: nil, cgmPumpMetadata: cgmPumpMetadata, pidTempBasalResult: nil)
    }
    
    static func withResult(at: Date, action: ClosedLoopAction, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata, glucoseInMgDl: Double, insulinOnBoard: Double, closedLoopAlgorithmResult: ClosedLoopAlgorithmResult) -> ClosedLoopResult {
        return ClosedLoopResult(at: at, action: action, settings: settings, glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: closedLoopAlgorithmResult.predictedGlucoseInMgDl, insulinOnBoard: insulinOnBoard, insulinSensitivity: closedLoopAlgorithmResult.learnedInsulinSensitivity, basalRate: closedLoopAlgorithmResult.learnedBasalRate, tempBasal: closedLoopAlgorithmResult.tempBasal, shadowTempBasal: closedLoopAlgorithmResult.shadowTempBasal, shadowPredictedAddedGlucose: closedLoopAlgorithmResult.shadowPredictedAddedGlucose, shadowMlAddedGlucose: closedLoopAlgorithmResult.shadowMlAddedGlucose, shadowAddedGlucoseDataFrame: closedLoopAlgorithmResult.shadowAddedGlucoseDataFrame, safetyResult: closedLoopAlgorithmResult.safetyResult, mlDuration: closedLoopAlgorithmResult.mlDurationInSeconds, safetyDuration: closedLoopAlgorithmResult.safetyDurationInSeconds, proportionalControllerDuration: closedLoopAlgorithmResult.proportionalControllerDurationInSeconds, microBolusAmount: closedLoopAlgorithmResult.microBolusAmount,
                                cgmPumpMetadata: cgmPumpMetadata, pidTempBasalResult: closedLoopAlgorithmResult.pidTempBasalResult)
    }
}

struct ClosedLoopAlgorithmResult {
    let tempBasal: Double
    let microBolusAmount: Double
    let shadowTempBasal: Double // remove
    let shadowPredictedAddedGlucose: Double // remove
    let learnedInsulinSensitivity: Double
    let learnedBasalRate: Double
    let shadowMlAddedGlucose: Double? // remove
    let shadowAddedGlucoseDataFrame: [AddedGlucoseDataRow]? // rename
    let safetyResult: SafetyResult? // not optional
    let mlDurationInSeconds: TimeInterval
    let safetyDurationInSeconds: TimeInterval
    let proportionalControllerDurationInSeconds: TimeInterval
    let predictedGlucoseInMgDl: Double
    let pidTempBasalResult: PIDTempBasalResult
}

actor LocalClosedLoopService: ClosedLoopService {
    static let shared = LocalClosedLoopService()
    
    var lastClosedLoopRun: ClosedLoopResult? = nil
    let replayLogger = getEventLogger()
    var lastMicroBolus: Date? = nil
    
    func latestClosedLoopResult() async -> ClosedLoopResult? {
        return lastClosedLoopRun
    }
    
    func loop(at: Date) async -> Bool {
        let lastRun: ClosedLoopResult = await loop(at: at)
        await replayLogger.add(events: [lastRun])
        lastClosedLoopRun = lastRun
        return lastRun.action == .setTempBasal
    }
    
    func microBolusAmount(tempBasal: Double, settings: CodableSettings, glucoseInMgDl: Double, basalRate: Double, predictedGlucoseInMgDl: Double, at: Date) async -> Double? {
        // make sure that we haven't issued a micro bolus in the last 4.2 minutes
        guard lastMicroBolus.map({ Date().timeIntervalSince($0) > 4.2.minutesToSeconds() }) ?? true else { return nil }

        // make sure we're at least 20 mg/dl above our target
        let glucoseThreshold = settings.targetGlucoseInMgDl + 20
        guard glucoseInMgDl >= glucoseThreshold else { return nil }
        
        // make sure that our glucose is rising or close to flat. The
        // reason that we want to allow flat glucose is that sometimes
        // the sensor can get saturated at 400 mg/dl, and we want
        // to micro bolus in this case
        guard predictedGlucoseInMgDl > (glucoseInMgDl - 2) else { return nil }
        
        // convert the temp basal to the amount of insulin the closed loop algorithm
        // decided to deliver, subtracting off the basal rate so that we're
        // only delivering the correction
        // Calculate the insulin amount based on temp basal and basal rate
        let correctionDurationHours = settings.correctionDurationInSeconds / 60.minutesToSeconds()
        
        guard correctionDurationHours > 0 else {
            return nil
        }

        // convert the temp basal to the amount of insulin the closed loop algorithm
        // decided to deliver, subtracting off the basal rate so that we're
        // only delivering the correction
        
        let insulin = (tempBasal - basalRate) * correctionDurationHours
        guard insulin > 0 else { return nil } // Ensure insulin amount is positive
    
        // Calculate the micro-bolus amount and clamp within valid bounds
        let maxBolus = settings.maxBasalRateUnitsPerHour * correctionDurationHours
        
        // Deliver part for now so that if nothing changes we deliver the full amount over 15-30 minutes
        let amount = (settings.getMicroBolusDoseFactor() * insulin).clamp(low: 0, high: maxBolus)
    
        // Round to the nearest supported bolus volume
        return await getDeviceDataManager().pumpManager?.roundToSupportedBolusVolume(units: amount) ?? amount
    }
    
    func loop(at: Date) async -> ClosedLoopResult {
        let settings = await getSettingsStorage().snapshot()
        let freshnessInterval = settings.freshnessIntervalInSeconds
        let cgmPumpMetadata = await getDeviceDataManager().cgmPumpMetadata()
        
        print("Looping!")
        guard settings.closedLoopEnabled else {
            print("Open loop mode, bailing")
            return ClosedLoopResult.withError(at: at, action: .openLoop, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }
        
        guard let glucoseReading = await getGlucoseStorage().lastReading(), at.timeIntervalSince(glucoseReading.date) < freshnessInterval else {
            print("Unable to get fresh glucose reading")
            return ClosedLoopResult.withError(at: at, action: .glucoseReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }
        
        guard let lastPumpSync = await getInsulinStorage().lastPumpSync(), at.timeIntervalSince(lastPumpSync) < freshnessInterval else {
            print("Unable to get fresh insulin data from the pump")
            return ClosedLoopResult.withError(at: at, action: .pumpReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }
        
        // FIXME: should we care if data is from the future???
        
        guard let pumpManager = await getDeviceDataManager().pumpManager else {
            print("no pump manager")
            return ClosedLoopResult.withError(at: at, action: .noPumpManager, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }
        
        let glucoseInMgDl = glucoseReading.quantity.doubleValue(for: .milligramsPerDeciliter)
        let insulinOnBoard = await getInsulinStorage().insulinOnBoard(at: at)
        
        let round = { (tempBasal: Double) -> Double in
            pumpManager.roundToSupportedBasalRate(unitsPerHour: tempBasal)
        }
        
        let closedLoopAlgorithmResult = await closedLoopAlgorithm(settings: settings, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, at: at, roundToSupportedBasalRate: round)
        print("Looping, glucose: \(glucoseInMgDl) mg/dl, iob: \(insulinOnBoard), tempBasal: \(closedLoopAlgorithmResult.tempBasal)")
        
        let correctionDuration = settings.correctionDurationInSeconds
        if let pumpError = await pumpManager.enactTempBasal(unitsPerHour: closedLoopAlgorithmResult.tempBasal, for: correctionDuration) {
            print("Pump error: \(String(describing: pumpError))")
            return ClosedLoopResult.withResult(at: at, action: .pumpError, settings: settings, cgmPumpMetadata: cgmPumpMetadata, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, closedLoopAlgorithmResult: closedLoopAlgorithmResult)
        }

        if closedLoopAlgorithmResult.microBolusAmount > 0.025 && settings.isMicroBolusEnabled() {
            let units = pumpManager.roundToSupportedBolusVolume(units: closedLoopAlgorithmResult.microBolusAmount)
            if let pumpError = await pumpManager.enactBolus(units: units, activationType: .automatic) {
                print("Pump error: \(String(describing: pumpError))")
                return ClosedLoopResult.withResult(at: at, action: .pumpError, settings: settings, cgmPumpMetadata: cgmPumpMetadata, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, closedLoopAlgorithmResult: closedLoopAlgorithmResult)
            }
            lastMicroBolus = Date()
        }
        
        // if we got here the temp basal command was sent to the pump
        // successfully
        if let safetyResult = closedLoopAlgorithmResult.safetyResult {
            await getSafetyService().updateAfterProgrammingPump(at: at, programmedTempBasalUnitsPerHour: safetyResult.tempBasalAfterSafetyChecks, safetyTempBasalUnitsPerHour: safetyResult.physiologicalTempBasal, machineLearningTempBasalUnitsPerHour: safetyResult.machineLearningTempBasal, duration: settings.correctionDurationInSeconds, programmedMicroBolus: safetyResult.actualMicroBolus, safetyMicroBolus: safetyResult.physiologicalMicroBolus, machineLearningMicroBolus: safetyResult.machineLearningMicroBolus, biologicalInvariantViolation: safetyResult.biologicalInvariantViolation)
        }

        
        // FIXME: I think I got the beeping to stop
        // podExpiring
        
        pumpManager.acknowledgeAlert(alertIdentifier: "userPodExpiration") { error in
            print("alert acknowledged \(String(describing: error))")
        }
        pumpManager.acknowledgeAlert(alertIdentifier: "podExpiring") { error in
            print("alert acknowledged \(String(describing: error))")
        }
        
        return ClosedLoopResult.withResult(at: at, action: .setTempBasal, settings: settings, cgmPumpMetadata: cgmPumpMetadata, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, closedLoopAlgorithmResult: closedLoopAlgorithmResult)
    }
    
    /// Pre conditions:
    ///  - targetGlucose >= 75
    ///  - insulinSensitivity > 0
    ///  - maxBasalRate > 0
    /// Post conditions:
    ///  - return is between 0 and maxBasalRate
    ///  Invariants:
    ///  - no numerical underflow or overflow
    func closedLoopAlgorithm(settings: CodableSettings, glucoseInMgDl: Double, insulinOnBoard: Double, at: Date, roundToSupportedBasalRate: (Double) -> Double) async -> ClosedLoopAlgorithmResult {
        
        // create a dataframe to pass to all of the callers
        let dataFrame = await AddedGlucoseDataFrame.createDataFrame(at: at, numberOfRows: 24, minNumberOfGlucoseSamples: 20)
        let basalRate = settings.learnedBasalRate(at: at)
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: at)
        let predictedGlucoseInMgDl = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: at) ?? glucoseInMgDl
        
        let proportionalControllerStart = Date()
        let pidTempBasal = await getPhysiologicalModels().tempBasal(settings: settings, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, dataFrame: dataFrame, at: at)

        let physiologicalTempBasal = applyGuardrails(glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: predictedGlucoseInMgDl, newBasalRateRaw: pidTempBasal.tempBasal, settings: settings, roundToSupportedBasalRate: roundToSupportedBasalRate)
        let proportionalControllerDuration = Date().timeIntervalSince(proportionalControllerStart)
        
        // calculate the ML-based tempBasal
        let mlStart = Date()
        let mlTempBasalRaw = await getMachineLearning().tempBasal(settings: settings, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, dataFrame: dataFrame, at: at) ?? physiologicalTempBasal
        let mlTempBasal = applyGuardrails(glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: predictedGlucoseInMgDl, newBasalRateRaw: mlTempBasalRaw, settings: settings, roundToSupportedBasalRate: roundToSupportedBasalRate)
        let mlDuration = Date().timeIntervalSince(mlStart)
        
        // run it through the safety service
        let safetyStart = Date()
        let safetyTempBasalResult = await getSafetyService().tempBasal(at: at, safetyTempBasalUnitsPerHour: physiologicalTempBasal, machineLearningTempBasalUnitsPerHour: mlTempBasal, duration: settings.correctionDurationInSeconds)
        let safetyTempBasal = applyGuardrails(glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: predictedGlucoseInMgDl, newBasalRateRaw: safetyTempBasalResult.tempBasal, settings: settings, roundToSupportedBasalRate: roundToSupportedBasalRate)
        let safetyDuration = Date().timeIntervalSince(safetyStart)
        
        // calculate the micro bolus candidates and the biological invariant
        // IMPORTANT: you must run the mlTempBasal through the safety logic and use only
        // that temp basal for micro bolus calculations, or you can use the physiological temp basal
        let microBolusSafety = await microBolusAmount(tempBasal: safetyTempBasal, settings: settings, glucoseInMgDl: glucoseInMgDl, basalRate: basalRate, predictedGlucoseInMgDl: predictedGlucoseInMgDl, at: at) ?? 0.0
        let microBolusPhysiological = await microBolusAmount(tempBasal: physiologicalTempBasal, settings: settings, glucoseInMgDl: glucoseInMgDl, basalRate: basalRate, predictedGlucoseInMgDl: predictedGlucoseInMgDl, at: at) ?? 0.0
        let biologicalInvariant = await getPhysiologicalModels().deltaGlucoseError(settings: settings, dataFrame: dataFrame, at: at)
        
        let dose = determineDose(settings: settings, safetyTempBasalResult: safetyTempBasalResult, physiologicalTempBasal: physiologicalTempBasal, mlTempBasal: mlTempBasal, safetyTempBasal: safetyTempBasal, microBolusPhysiological: microBolusPhysiological, microBolusSafety: microBolusSafety, biologicalInvariant: biologicalInvariant)
        
        return ClosedLoopAlgorithmResult(tempBasal: dose.tempBasal, microBolusAmount: dose.microBolus, shadowTempBasal: 0.0, shadowPredictedAddedGlucose: 0.0, learnedInsulinSensitivity: insulinSensitivity, learnedBasalRate: basalRate, shadowMlAddedGlucose: 0.0, shadowAddedGlucoseDataFrame: dataFrame, safetyResult: dose.safetyResult, mlDurationInSeconds: mlDuration, safetyDurationInSeconds: safetyDuration, proportionalControllerDurationInSeconds: proportionalControllerDuration, predictedGlucoseInMgDl: predictedGlucoseInMgDl, pidTempBasalResult: pidTempBasal)
    }
    
    /// post condition: either tempBasal _or_ microBolus can be > 0 but not both
    func determineDose(settings: CodableSettings, safetyTempBasalResult: SafetyTempBasal, physiologicalTempBasal: Double, mlTempBasal: Double, safetyTempBasal: Double, microBolusPhysiological: Double, microBolusSafety: Double, biologicalInvariant: Double?) -> (tempBasal: Double, microBolus: Double, safetyResult: SafetyResult) {
        var tempBasal: Double
        var microBolus: Double
        var microBolusCandidate: Double
        var safetyResult: SafetyResult
        
        if settings.useMachineLearningClosedLoop {
            tempBasal = safetyTempBasal
            microBolusCandidate = microBolusSafety
        } else {
            tempBasal = physiologicalTempBasal
            microBolusCandidate = microBolusPhysiological
        }
        
        if settings.isBiologicalInvariantEnabled(), let biologicalInvariant = biologicalInvariant, biologicalInvariant < -35 {
            microBolus = 0.0
            tempBasal = 0.0
            safetyResult = SafetyResult.withBiologicalInvariantViolation(biologicalInvariantMgDlPerHour: biologicalInvariant, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        } else if settings.isMicroBolusEnabled(), microBolusCandidate > 0.025 {
            microBolus = microBolusCandidate
            tempBasal = 0.0
            safetyResult = SafetyResult.withMicroBolus(machineLearningMicroBolus: microBolusSafety, physiologicalMicroBolus: microBolusPhysiological, actualMicroBolus: microBolus, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariant)
        } else {
            microBolus = 0.0
            safetyResult = SafetyResult.withTempBasal(machineLearningTempBasal: mlTempBasal, physiologicalTempBasal: physiologicalTempBasal, tempBasalAfterSafetyChecks: safetyTempBasal, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariant)
        }
        
        return (tempBasal: tempBasal, microBolus: microBolus, safetyResult: safetyResult)
    }
    
    func applyGuardrails(glucoseInMgDl: Double, predictedGlucoseInMgDl: Double, newBasalRateRaw: Double, settings: CodableSettings, roundToSupportedBasalRate: (Double) -> Double) -> Double {
        // now get it ready to send to the pump
        var newBasalRate = roundToSupportedBasalRate(newBasalRateRaw)
        
        if newBasalRate > settings.maxBasalRateUnitsPerHour {
            newBasalRate = settings.maxBasalRateUnitsPerHour
        }
        
        if newBasalRate < 0.0 {
            newBasalRate = 0.0
        }
        
        let shutOffGlucose = settings.shutOffGlucoseInMgDl
        if glucoseInMgDl <= shutOffGlucose || predictedGlucoseInMgDl <= shutOffGlucose {
            newBasalRate = 0.0
        }
        
        return newBasalRate
    }
}
