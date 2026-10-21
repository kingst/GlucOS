//
//  LoopRecord.swift
//  BioKernel
//
//  Created by Sam King on 8/16/26.
//
//  The persisted projection of a `ClosedLoopResult` — exactly the fields the app
//  reads back, and nothing else. See dev/backlog/loop-record-store-grdb.md §4.
//
//  `closed_loop_results.json` was doing two jobs: it was the app's working state
//  (chart data, the micro-bolus throttle, the digestion gauge) and it was an
//  audit log of everything the algorithm saw. Only the first job survives the
//  move to SQLite. `ClosedLoopResult` stays exactly as it is — the in-memory
//  pipeline result, still `Codable` — and this is what goes to disk.
//
//  §2 of the doc has the field-by-field tally of what that leaves behind. The
//  short version is that ~82% of a stored row's bytes were `cgmPumpMetadata`
//  (1,201 constant doubles from the pod driver, re-serialized 288 times a day)
//  and `replay.dataFrame`, and nothing in the app has ever read either one.
//  §9 says what it would take to pick the audit role back up properly, which is
//  a settings-version table and an append-only replay sink, not these columns.
//
//  The shape here deliberately mirrors `LoopOutcome` / `LoopSnapshot` rather
//  than flattening into 28 optionals: a tick that never reached the pipeline has
//  no snapshot, and saying so with the enum makes the schema's NULLs structural
//  instead of a convention every reader has to remember.
//

import Foundation

/// One loop tick, as the store holds it.
public struct LoopRecord {
    public let at: Date
    public let outcome: LoopRecordOutcome
}

/// Mirrors `LoopOutcome`, minus the payload nothing reads.
public enum LoopRecordOutcome {
    case skipped(SkipReason)
    case dosed(LoopRecordSnapshot)
    case pumpError(attempted: LoopRecordSnapshot)
}

public extension LoopRecordOutcome {
    var skipReason: SkipReason? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }

    var snapshot: LoopRecordSnapshot? {
        switch self {
        case .dosed(let snapshot): return snapshot
        case .pumpError(let snapshot): return snapshot
        case .skipped: return nil
        }
    }
}

/// What the pipeline saw and decided on a tick that reached it.
///
/// Flatter than `LoopSnapshot`: `inputs` and the read-back part of `outputs`
/// merge here because the distinction between them was about which struct the
/// pipeline filled in, and nothing reading a stored row cares.
public struct LoopRecordSnapshot {
    // LoopSnapshotInputs
    public let glucoseInMgDl: Double
    public let insulinOnBoard: Double

    // PipelineOutputs, the read-back subset
    public let insulinSensitivity: Double
    public let basalRate: Double
    public let predictedAddedGlucoseInMgDlPerHour: Double
    public let machineLearningInsulinLastThreeHours: Double
    /// What this tick dosed toward, and why. Optional because a row written
    /// before schema v2 has NULL in both, and those rows must keep reading
    /// back (dev/backlog/meal-soon.md §6).
    public let targetGlucoseInMgDl: Double?
    public let targetSource: TargetGlucoseSource?
    public let decision: DosingDecision
    public let candidates: DoseCandidates

    public let pid: LoopRecordPID
}

/// The read-back subset of `PIDTempBasalResult`.
///
/// The gains are stored raw rather than as the three precomputed PID
/// contributions, so the arithmetic that turns them into contributions stays in
/// `DiagnosticViewModel.convertToChartData` where a reader can check it. Moving
/// it into the write path would hide the thing being checked.
///
/// `tempBasal`, `lastGlucose` and `lastGlucoseAt` are not here: the *decision*
/// is read instead of the PID's proposal, and the live controller state the last
/// two belong to is `PIDState`, which has its own file and is the source of
/// truth the controller actually resumes from.
public struct LoopRecordPID {
    public let at: Date
    public let Kp: Double
    public let Ki: Double
    public let Kd: Double
    public let filteredGlucose: Double
    public let error: Double
    public let accumulatedError: Double
    public let derivative: Double?
    public let deltaGlucoseError: Double?
    public let basalRateInsulinOnBoard: Double?
}

// MARK: - Projection

extension LoopRecord {
    /// The one place `ClosedLoopResult` narrows to what gets persisted.
    ///
    /// Everything dropped here is listed in §9 of the doc. Keeping the narrowing
    /// in a single initializer is what makes that list checkable — a field added
    /// to the pipeline is either mapped here or it is documented as audit-only,
    /// and there is no third option where it silently half-persists.
    init(_ result: ClosedLoopResult) {
        self.at = result.at
        switch result.outcome {
        case .skipped(let reason):
            self.outcome = .skipped(reason)
        case .dosed(let snapshot):
            self.outcome = .dosed(LoopRecordSnapshot(snapshot))
        case .pumpError(let snapshot):
            self.outcome = .pumpError(attempted: LoopRecordSnapshot(snapshot))
        }
    }
}

extension LoopRecordSnapshot {
    init(_ snapshot: LoopSnapshot) {
        self.glucoseInMgDl = snapshot.inputs.glucoseInMgDl
        self.insulinOnBoard = snapshot.inputs.insulinOnBoard
        self.insulinSensitivity = snapshot.outputs.insulinSensitivity
        self.basalRate = snapshot.outputs.basalRate
        self.predictedAddedGlucoseInMgDlPerHour = snapshot.outputs.predictedAddedGlucoseInMgDlPerHour
        self.machineLearningInsulinLastThreeHours = snapshot.outputs.machineLearningInsulinLastThreeHours
        self.targetGlucoseInMgDl = snapshot.outputs.targetGlucoseInMgDl
        self.targetSource = snapshot.outputs.targetSource
        self.decision = snapshot.outputs.decision
        self.candidates = snapshot.outputs.candidates
        self.pid = LoopRecordPID(snapshot.outputs.pidTempBasalResult)
    }
}

extension LoopRecordPID {
    init(_ pid: PIDTempBasalResult) {
        self.at = pid.at
        self.Kp = pid.Kp
        self.Ki = pid.Ki
        self.Kd = pid.Kd
        self.filteredGlucose = pid.filteredGlucose
        self.error = pid.error
        self.accumulatedError = pid.accumulatedError
        self.derivative = pid.derivative
        self.deltaGlucoseError = pid.deltaGlucoseError
        self.basalRateInsulinOnBoard = pid.basalRateInsulinOnBoard
    }
}
