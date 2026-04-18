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
}

public struct LoopSnapshot: Codable {
    let glucoseInMgDl: Double
    let predictedGlucoseInMgDl: Double
    let insulinOnBoard: Double
    let targetGlucoseInMgDl: Double
    let insulinSensitivity: Double
    let basalRate: Double

    let decision: DosingDecision
    let safetyResult: SafetyResult
    let pidTempBasalResult: PIDTempBasalResult

    let mlDurationInSeconds: TimeInterval
    let safetyDurationInSeconds: TimeInterval
    let proportionalControllerDurationInSeconds: TimeInterval

    let predictedAddedGlucoseInMgDlPerHour: Double
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
