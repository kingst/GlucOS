//
//  ClosedLoopDataTypes.swift
//  BioKernel
//
//  Created by Sam King on 12/30/24.
//

import Foundation

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
    let actualTempBasal: Double
    let machineLearningMicroBolus: Double
    let physiologicalMicroBolus: Double
    let actualMicroBolus: Double
    let machineLearningInsulinLastThreeHours: Double
    let biologicalInvariantMgDlPerHour: Double?
    let biologicalInvariantViolation: Bool
    
    static func withTempBasal(machineLearningTempBasal: Double, physiologicalTempBasal: Double, actualTempBasal: Double, machineLearningInsulinLastThreeHours: Double, biologicalInvariantMgDlPerHour: Double?) -> SafetyResult {
        
        return SafetyResult(machineLearningTempBasal: machineLearningTempBasal, physiologicalTempBasal: physiologicalTempBasal, actualTempBasal: actualTempBasal, machineLearningMicroBolus: 0.0, physiologicalMicroBolus: 0.0, actualMicroBolus: 0.0, machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariantMgDlPerHour, biologicalInvariantViolation: false)
    }
    
    static func withMicroBolus(machineLearningMicroBolus: Double, physiologicalMicroBolus: Double, actualMicroBolus: Double, machineLearningInsulinLastThreeHours: Double, biologicalInvariantMgDlPerHour: Double?) -> SafetyResult {

        return SafetyResult(machineLearningTempBasal: 0.0, physiologicalTempBasal: 0.0, actualTempBasal: 0.0, machineLearningMicroBolus: machineLearningMicroBolus, physiologicalMicroBolus: physiologicalMicroBolus, actualMicroBolus: actualMicroBolus, machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariantMgDlPerHour, biologicalInvariantViolation: false)
    }
    
    static func withBiologicalInvariantViolation(biologicalInvariantMgDlPerHour: Double, machineLearningInsulinLastThreeHours: Double) -> SafetyResult {
        return SafetyResult(machineLearningTempBasal: 0, physiologicalTempBasal: 0, actualTempBasal: 0, machineLearningMicroBolus: 0, physiologicalMicroBolus: 0, actualMicroBolus: 0, machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours, biologicalInvariantMgDlPerHour: biologicalInvariantMgDlPerHour, biologicalInvariantViolation: true)
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
    let targetGlucoseInMgDl: Double?
    
    init(at: Date, action: ClosedLoopAction, settings: CodableSettings, glucoseInMgDl: Double?, predictedGlucoseInMgDl: Double?, insulinOnBoard: Double?, insulinSensitivity: Double?, basalRate: Double?, tempBasal: Double?, shadowTempBasal: Double?, shadowPredictedAddedGlucose: Double?, shadowMlAddedGlucose: Double?, shadowAddedGlucoseDataFrame: [AddedGlucoseDataRow]?, safetyResult: SafetyResult?, mlDuration: TimeInterval, safetyDuration: TimeInterval, proportionalControllerDuration: TimeInterval, microBolusAmount: Double?, cgmPumpMetadata: CgmPumpMetadata, pidTempBasalResult: PIDTempBasalResult?, targetGlucoseInMgDl: Double?) {
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
        self.targetGlucoseInMgDl = targetGlucoseInMgDl
    }
    
    static func withError(at: Date, action: ClosedLoopAction, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata) -> ClosedLoopResult {
        return ClosedLoopResult(at: at, action: action, settings: settings, glucoseInMgDl: nil, predictedGlucoseInMgDl: nil, insulinOnBoard: nil, insulinSensitivity: nil, basalRate: nil, tempBasal: nil, shadowTempBasal: nil, shadowPredictedAddedGlucose: nil, shadowMlAddedGlucose: nil, shadowAddedGlucoseDataFrame: nil, safetyResult: nil, mlDuration: 0, safetyDuration: 0, proportionalControllerDuration: 0, microBolusAmount: nil, cgmPumpMetadata: cgmPumpMetadata, pidTempBasalResult: nil, targetGlucoseInMgDl: nil)
    }
    
    static func withResult(at: Date, action: ClosedLoopAction, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata, glucoseInMgDl: Double, insulinOnBoard: Double, closedLoopAlgorithmResult: ClosedLoopAlgorithmResult) -> ClosedLoopResult {
        return ClosedLoopResult(at: at, action: action, settings: settings, glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: closedLoopAlgorithmResult.predictedGlucoseInMgDl, insulinOnBoard: insulinOnBoard, insulinSensitivity: closedLoopAlgorithmResult.learnedInsulinSensitivity, basalRate: closedLoopAlgorithmResult.learnedBasalRate, tempBasal: closedLoopAlgorithmResult.tempBasal, shadowTempBasal: closedLoopAlgorithmResult.shadowTempBasal, shadowPredictedAddedGlucose: closedLoopAlgorithmResult.shadowPredictedAddedGlucose, shadowMlAddedGlucose: closedLoopAlgorithmResult.shadowMlAddedGlucose, shadowAddedGlucoseDataFrame: closedLoopAlgorithmResult.shadowAddedGlucoseDataFrame, safetyResult: closedLoopAlgorithmResult.safetyResult, mlDuration: closedLoopAlgorithmResult.mlDurationInSeconds, safetyDuration: closedLoopAlgorithmResult.safetyDurationInSeconds, proportionalControllerDuration: closedLoopAlgorithmResult.proportionalControllerDurationInSeconds, microBolusAmount: closedLoopAlgorithmResult.microBolusAmount,
                                cgmPumpMetadata: cgmPumpMetadata, pidTempBasalResult: closedLoopAlgorithmResult.pidTempBasalResult, targetGlucoseInMgDl: closedLoopAlgorithmResult.targetGlucoseInMgDl)
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
    let targetGlucoseInMgDl: Double
}
