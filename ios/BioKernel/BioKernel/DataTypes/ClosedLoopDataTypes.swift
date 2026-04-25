//
//  ClosedLoopDataTypes.swift
//  BioKernel
//
//  Created by Sam King on 12/30/24.
//

import Foundation

public enum DosingDecision: Codable, Equatable {
    case tempBasal(unitsPerHour: Double)
    case microBolus(units: Double)
    case suspendForBiologicalInvariant(mgDlPerHour: Double)
    
    var tempBasalUnitsPerHour: Double? {
        if case .tempBasal(let unitsPerHour) = self { return unitsPerHour }
        return nil
    }
    
    var microBolusUnits: Double? {
        if case .microBolus(let units) = self { return units }
        return nil
    }
}

public enum SkipReason: String, Codable {
    case openLoop
    case glucoseReadingStale
    case pumpReadingStale
    case noPumpManager
}

public enum LoopOutcome: Codable {
    case skipped(SkipReason)
    case dosed(LoopSnapshot)
    case pumpError(attempted: LoopSnapshot)
}

public extension LoopOutcome {
    var skipReason: SkipReason? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }

    var snapshot: LoopSnapshot? {
        switch self {
        case .dosed(let snapshot): return snapshot
        case .pumpError(let snapshot): return snapshot
        case .skipped: return nil
        }
    }
}

public struct SafetyAnalysis: Codable {
    let machineLearningTempBasal: Double
    let physiologicalTempBasal: Double
    let machineLearningMicroBolus: Double
    let physiologicalMicroBolus: Double
    let machineLearningInsulinLastThreeHours: Double
    let biologicalInvariantMgDlPerHour: Double?
}

/// Pre conditions:
///  - settings.maxBasalRateUnitsPerHour > 0
/// Post conditions:
///  - clamp() returns a value in [0, settings.maxBasalRateUnitsPerHour]
///  - returns 0 when glucose <= shutOff or predictedGlucose <= shutOff
///  - returns 0 when raw < 0
public struct Guardrails {
    let settings: CodableSettings
    let glucoseInMgDl: Double
    let predictedGlucoseInMgDl: Double
    let roundToSupportedBasalRate: (Double) -> Double

    func clamp(_ raw: Double) -> Double {
        var newBasalRate = roundToSupportedBasalRate(raw)
        if newBasalRate > settings.maxBasalRateUnitsPerHour {
            newBasalRate = settings.maxBasalRateUnitsPerHour
        }
        if newBasalRate < 0.0 {
            newBasalRate = 0.0
        }
        if shouldShutOff() {
            newBasalRate = 0.0
        }
        return newBasalRate
    }

    func shouldShutOff() -> Bool {
        let shutOffGlucose = settings.shutOffGlucoseInMgDl
        return glucoseInMgDl <= shutOffGlucose || predictedGlucoseInMgDl <= shutOffGlucose
    }
}

public struct MicroBolusPolicy {
    let throttleInSeconds: TimeInterval
    let glucoseMarginMgDl: Double

    init(throttleInSeconds: TimeInterval = 252, glucoseMarginMgDl: Double = 20) {
        self.throttleInSeconds = throttleInSeconds
        self.glucoseMarginMgDl = glucoseMarginMgDl
    }

    func amount(
        tempBasal: Double,
        settings: CodableSettings,
        glucoseInMgDl: Double,
        targetGlucoseInMgDl: Double,
        at: Date,
        lastMicroBolus: Date?,
        roundToSupportedBolusVolume: (Double) -> Double
    ) -> Double? {
        guard pastThrottleWindow(at: at, lastMicroBolus: lastMicroBolus) else { return nil }
        guard glucoseAboveGate(glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl) else { return nil }
        guard let insulin = correctionInsulin(tempBasal: tempBasal, settings: settings) else { return nil }

        // Deliver part for now so that if nothing changes we deliver the full amount over 15-30 minutes
        let correctionDurationHours = settings.correctionDurationInSeconds / 60.minutesToSeconds()
        let maxBolus = settings.maxBasalRateUnitsPerHour * correctionDurationHours
        let amount = (settings.getMicroBolusDoseFactor() * insulin).clamp(low: 0, high: min(insulin, maxBolus))

        return roundToSupportedBolusVolume(amount)
    }

    func pastThrottleWindow(at: Date, lastMicroBolus: Date?) -> Bool {
        guard let lastMicroBolus = lastMicroBolus else { return true }
        return at.timeIntervalSince(lastMicroBolus) > throttleInSeconds
    }

    func glucoseAboveGate(glucoseInMgDl: Double, targetGlucoseInMgDl: Double) -> Bool {
        return glucoseInMgDl >= targetGlucoseInMgDl + glucoseMarginMgDl
    }

    /// Converts a temp basal rate to an insulin amount over the correction window.
    /// Returns nil if the duration is non-positive or the resulting insulin is non-positive.
    func correctionInsulin(tempBasal: Double, settings: CodableSettings) -> Double? {
        let correctionDurationHours = settings.correctionDurationInSeconds / 60.minutesToSeconds()
        guard correctionDurationHours > 0 else { return nil }
        let insulin = tempBasal * correctionDurationHours
        guard insulin > 0 else { return nil }
        return insulin
    }
}

public enum DoseSelector {
    static let biologicalInvariantThresholdMgDlPerHour: Double = -35
    static let minimumMicroBolusUnits: Double = 0.025

    /// post condition: exactly one dosing branch is selected per tick
    static func decide(
        settings: CodableSettings,
        physiologicalTempBasal: Double,
        safetyTempBasal: Double,
        microBolusPhysiological: Double,
        microBolusSafety: Double,
        biologicalInvariant: Double?
    ) -> DosingDecision {
        let tempBasalCandidate: Double
        let microBolusCandidate: Double

        if settings.useMachineLearningClosedLoop {
            tempBasalCandidate = safetyTempBasal
            microBolusCandidate = microBolusSafety
        } else {
            tempBasalCandidate = physiologicalTempBasal
            microBolusCandidate = microBolusPhysiological
        }

        if settings.isBiologicalInvariantEnabled(), let biologicalInvariant = biologicalInvariant, biologicalInvariant < biologicalInvariantThresholdMgDlPerHour {
            return .suspendForBiologicalInvariant(mgDlPerHour: biologicalInvariant)
        }

        if settings.isMicroBolusEnabled(), microBolusCandidate > minimumMicroBolusUnits {
            return .microBolus(units: microBolusCandidate)
        }

        return .tempBasal(unitsPerHour: tempBasalCandidate)
    }
}

public struct LoopSnapshotInputs: Codable {
    let glucoseInMgDl: Double
    let insulinOnBoard: Double
}

public struct StageTimings: Codable {
    let pidDurationInSeconds: TimeInterval
    let mlDurationInSeconds: TimeInterval
    let safetyDurationInSeconds: TimeInterval
}

public struct PipelineOutputs: Codable {
    let predictedGlucoseInMgDl: Double
    let targetGlucoseInMgDl: Double
    let insulinSensitivity: Double
    let basalRate: Double
    let pidTempBasalResult: PIDTempBasalResult
    let safetyAnalysis: SafetyAnalysis
    let decision: DosingDecision
    let timings: StageTimings
    let predictedAddedGlucoseInMgDlPerHour: Double
}

public struct LoopSnapshot: Codable {
    let inputs: LoopSnapshotInputs
    let outputs: PipelineOutputs
}

/// Runtime inputs to the dosing pipeline. Not Codable: holds rounding closures that
/// can't be persisted. The persisted subset is `LoopSnapshotInputs`.
public struct LoopInputs {
    let at: Date
    let settings: CodableSettings
    let glucoseInMgDl: Double
    let insulinOnBoard: Double
    let dataFrame: [AddedGlucoseDataRow]?
    let lastMicroBolus: Date?
    let roundToSupportedBasalRate: (Double) -> Double
    let roundToSupportedBolusVolume: (Double) -> Double
}

/// Pure dosing pipeline. Holds no mutable state; depends only on the model services
/// (which are themselves actors). Takes `LoopInputs` and returns `PipelineOutputs`.
struct DosingPipeline {
    let physiological: PhysiologicalModels
    let machineLearning: MachineLearning
    let safety: SafetyService
    let target: TargetGlucoseService
    let microBolusPolicy: MicroBolusPolicy

    init(
        physiological: PhysiologicalModels,
        machineLearning: MachineLearning,
        safety: SafetyService,
        target: TargetGlucoseService,
        microBolusPolicy: MicroBolusPolicy = MicroBolusPolicy()
    ) {
        self.physiological = physiological
        self.machineLearning = machineLearning
        self.safety = safety
        self.target = target
        self.microBolusPolicy = microBolusPolicy
    }

    func run(_ inputs: LoopInputs) async -> PipelineOutputs {
        let settings = inputs.settings
        let at = inputs.at
        let glucoseInMgDl = inputs.glucoseInMgDl
        let insulinOnBoard = inputs.insulinOnBoard
        let dataFrame = inputs.dataFrame

        let basalRate = settings.learnedBasalRate(at: at)
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: at)
        let predictedGlucoseInMgDl = await physiological.predictGlucoseIn15Minutes(from: at) ?? glucoseInMgDl
        let targetGlucoseInMgDl = await target.targetGlucoseInMgDl(at: at, settings: settings)

        let guardrails = Guardrails(
            settings: settings,
            glucoseInMgDl: glucoseInMgDl,
            predictedGlucoseInMgDl: predictedGlucoseInMgDl,
            roundToSupportedBasalRate: inputs.roundToSupportedBasalRate
        )

        let pidStart = Date()
        let pidTempBasal = await physiological.tempBasal(settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, insulinOnBoard: insulinOnBoard, dataFrame: dataFrame, at: at)
        let physiologicalTempBasal = guardrails.clamp(pidTempBasal.tempBasal)
        let pidDuration = Date().timeIntervalSince(pidStart)

        let mlStart = Date()
        let mlTempBasalRaw = await machineLearning.tempBasal(settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, insulinOnBoard: insulinOnBoard, dataFrame: dataFrame, at: at, pidTempBasal: pidTempBasal) ?? physiologicalTempBasal
        let mlTempBasal = guardrails.clamp(mlTempBasalRaw)
        let mlDuration = Date().timeIntervalSince(mlStart)

        let safetyStart = Date()
        let safetyTempBasalResult = await safety.tempBasal(at: at, settings: settings, safetyTempBasalUnitsPerHour: physiologicalTempBasal, machineLearningTempBasalUnitsPerHour: mlTempBasal, duration: settings.correctionDurationInSeconds)
        let safetyTempBasal = guardrails.clamp(safetyTempBasalResult.tempBasal)
        let safetyDuration = Date().timeIntervalSince(safetyStart)

        // IMPORTANT: you must run the mlTempBasal through the safety logic and use only
        // that temp basal for micro bolus calculations, or you can use the physiological temp basal
        let microBolusSafety = microBolusPolicy.amount(tempBasal: safetyTempBasal, settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, at: at, lastMicroBolus: inputs.lastMicroBolus, roundToSupportedBolusVolume: inputs.roundToSupportedBolusVolume) ?? 0.0
        let microBolusPhysiological = microBolusPolicy.amount(tempBasal: physiologicalTempBasal, settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, at: at, lastMicroBolus: inputs.lastMicroBolus, roundToSupportedBolusVolume: inputs.roundToSupportedBolusVolume) ?? 0.0
        let biologicalInvariant = await physiological.deltaGlucoseError(settings: settings, dataFrame: dataFrame, at: at)

        let decision = DoseSelector.decide(
            settings: settings,
            physiologicalTempBasal: physiologicalTempBasal,
            safetyTempBasal: safetyTempBasal,
            microBolusPhysiological: microBolusPhysiological,
            microBolusSafety: microBolusSafety,
            biologicalInvariant: biologicalInvariant
        )

        let safetyAnalysis = SafetyAnalysis(
            machineLearningTempBasal: mlTempBasal,
            physiologicalTempBasal: physiologicalTempBasal,
            machineLearningMicroBolus: microBolusSafety,
            physiologicalMicroBolus: microBolusPhysiological,
            machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours,
            biologicalInvariantMgDlPerHour: biologicalInvariant
        )

        let addedGlucose = dataFrame?.addedGlucosePerHour30m(insulinSensitivity: insulinSensitivity) ?? 0

        return PipelineOutputs(
            predictedGlucoseInMgDl: predictedGlucoseInMgDl,
            targetGlucoseInMgDl: targetGlucoseInMgDl,
            insulinSensitivity: insulinSensitivity,
            basalRate: basalRate,
            pidTempBasalResult: pidTempBasal,
            safetyAnalysis: safetyAnalysis,
            decision: decision,
            timings: StageTimings(
                pidDurationInSeconds: pidDuration,
                mlDurationInSeconds: mlDuration,
                safetyDurationInSeconds: safetyDuration
            ),
            predictedAddedGlucoseInMgDlPerHour: addedGlucose
        )
    }
}

public struct ClosedLoopResult: Codable {
    public let at: Date
    public let durationInSeconds: TimeInterval
    public let settings: CodableSettings
    public let cgmPumpMetadata: CgmPumpMetadata
    public let outcome: LoopOutcome

    private init(at: Date, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata, outcome: LoopOutcome) {
        self.at = at
        self.durationInSeconds = Date().timeIntervalSince(at)
        self.settings = settings
        self.cgmPumpMetadata = cgmPumpMetadata
        self.outcome = outcome
    }

    public static func skipped(at: Date, reason: SkipReason, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata) -> ClosedLoopResult {
        ClosedLoopResult(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, outcome: .skipped(reason))
    }

    public static func dosed(at: Date, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata, snapshot: LoopSnapshot) -> ClosedLoopResult {
        ClosedLoopResult(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, outcome: .dosed(snapshot))
    }

    public static func pumpError(at: Date, settings: CodableSettings, cgmPumpMetadata: CgmPumpMetadata, snapshot: LoopSnapshot) -> ClosedLoopResult {
        ClosedLoopResult(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, outcome: .pumpError(attempted: snapshot))
    }
}
