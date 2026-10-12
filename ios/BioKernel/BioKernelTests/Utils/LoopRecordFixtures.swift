//
//  LoopRecordFixtures.swift
//  BioKernelTests
//
//  Created by Sam King on 8/16/26.
//
//  Builders for `LoopRecord` and the ledger entries beside it.
//
//  The defaults are deliberately distinct, non-round, non-repeating numbers.
//  A `loop_result` row is 22 `Double?` columns and the failure this guards is a
//  value landing one column over — which every field being `1.0` would hide
//  completely.
//

import Foundation
@testable import BioKernel

enum LoopRecordFixtures {

    static func pid(at: Date) -> LoopRecordPID {
        return LoopRecordPID(
            at: at,
            Kp: 1.1,
            Ki: 2.2,
            Kd: 3.3,
            filteredGlucose: 141.5,
            error: 41.5,
            accumulatedError: 512.25,
            derivative: -0.75,
            deltaGlucoseError: -12.5,
            basalRateInsulinOnBoard: 1.875
        )
    }

    /// Every optional PID field nil, which is the shape `MockPhysiologicalModels`
    /// produces and the one a round trip is most likely to get wrong.
    static func pidWithNilOptionals(at: Date) -> LoopRecordPID {
        return LoopRecordPID(
            at: at,
            Kp: 1.1,
            Ki: 2.2,
            Kd: 3.3,
            filteredGlucose: 141.5,
            error: 41.5,
            accumulatedError: 512.25,
            derivative: nil,
            deltaGlucoseError: nil,
            basalRateInsulinOnBoard: nil
        )
    }

    static func candidates() -> DoseCandidates {
        return DoseCandidates(
            physiologicalTempBasal: 0.95,
            mlTempBasal: 1.35,
            physiologicalMicroBolus: 0.2,
            mlMicroBolus: 0.3
        )
    }

    static func snapshot(
        decision: DosingDecision = .tempBasal(unitsPerHour: 1.25),
        candidates: DoseCandidates = candidates(),
        pid: LoopRecordPID? = nil,
        at: Date
    ) -> LoopRecordSnapshot {
        return LoopRecordSnapshot(
            glucoseInMgDl: 152.5,
            insulinOnBoard: 2.375,
            insulinSensitivity: 46.5,
            basalRate: 0.85,
            predictedAddedGlucoseInMgDlPerHour: 18.25,
            machineLearningInsulinLastThreeHours: 0.625,
            decision: decision,
            candidates: candidates,
            pid: pid ?? Self.pid(at: at - 30)
        )
    }

    static func dosed(
        at: Date,
        decision: DosingDecision = .tempBasal(unitsPerHour: 1.25),
        candidates: DoseCandidates = candidates(),
        pid: LoopRecordPID? = nil
    ) -> LoopRecord {
        return LoopRecord(
            at: at,
            outcome: .dosed(snapshot(decision: decision, candidates: candidates, pid: pid, at: at))
        )
    }

    static func skipped(at: Date, reason: SkipReason = .openLoop) -> LoopRecord {
        return LoopRecord(at: at, outcome: .skipped(reason))
    }

    static func pumpError(at: Date, decision: DosingDecision = .microBolus(units: 0.45)) -> LoopRecord {
        return LoopRecord(
            at: at,
            outcome: .pumpError(attempted: snapshot(decision: decision, at: at))
        )
    }

    /// A dosed tick and the ledger entry it earned, the pairing the loop writes.
    static func dosedWithLedger(
        at: Date,
        decision: DosingDecision,
        candidates: DoseCandidates = candidates(),
        duration: TimeInterval = 30.minutesToSeconds()
    ) -> (record: LoopRecord, safetyState: SafetyState) {
        return (
            dosed(at: at, decision: decision, candidates: candidates),
            SafetyState(at: at, decision: decision, candidates: candidates, duration: duration)
        )
    }
}
