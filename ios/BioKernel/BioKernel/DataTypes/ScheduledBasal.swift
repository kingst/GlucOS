//
//  ScheduledBasal.swift
//  BioKernel
//
//  What the pod was programmed with, and when. See
//  dev/backlog/scheduled-basal-history.md.
//
//  `InsulinRecordTimeline.derive` used to take a `scheduledRateInUnitsPerHour`
//  supplied from `settingsStorage().snapshot().pumpBasalRateUnitsPerHour` — a
//  **now** value applied to **then**. Against 90-day retention every
//  retrospective derivation silently re-ran history at today's rate, and worse,
//  the setting is what the user asked for rather than what the pod accepted
//  (§1.1): `persistUpdatedSettings` writes it to disk *before* pushing it to the
//  pod, and a failed sync leaves the two divergent with nothing recording the
//  divergence.
//
//  So a rate record is keyed on the pod's **resume**, which per §2 is not merely
//  an acknowledgment but the instant the new rate begins running:
//  `PodCommsSession.setBasalSchedule` sets `suspendState = .resumed(now)` and
//  mints the resume at that same `now`. Nothing is delivered at the new rate
//  before it — a schedule change on a live pod cancels all delivery first
//  (`OmniPumpManager.setBasalSchedule` → `handleCancelDosing`), and an activation
//  has nothing to suspend.
//

import Foundation

// MARK: - The record

/// A rate the pod acknowledged, keyed by the resume that programmed it.
///
/// **There is no stored timestamp.** `effectiveAt` is `pump_event.date` for
/// `resumeSyncIdentifier`, read by join in the same transaction as everything
/// else (§3.1). An earlier design stored a copy of it and required the two
/// doubles to be bit-identical, because `effectiveAt <= gapStart` is only correct
/// at a boundary if they are — a real invariant with nothing enforcing it, whose
/// symptom when broken is a few seconds of segment at the wrong rate.
///
/// With no copy there is no equality to preserve, and the load-bearing comparison
/// disappears rather than acquiring an epsilon: `ScheduledBasalHistory.changes`
/// hands the derivation the *record*, so a sub-segment beginning at a rate change
/// reads its rate from that record instead of looking it up at the boundary.
struct ScheduledBasalRecord: Equatable {
    enum Source: String {
        /// Minted by a resume, either consuming a pending program (§4.1) or
        /// re-asserting the rate already on the pod. A positive fact, observed at
        /// the instant the pod acknowledged it, never retroactively revised.
        case acknowledged
        /// Written once by the migration, for resumes that predate this table
        /// (§4.2). An assumption about the past rather than an observation —
        /// which is why it is labeled, why nothing reads the label as evidence,
        /// and why nothing writes another.
        case backfilled

        static func from(rawValue: String) -> Source {
            return Source(rawValue: rawValue) ?? .backfilled
        }
    }

    /// The primary key, and the identity of the acknowledgment: *this rate was
    /// programmed by that resume*.
    let resumeSyncIdentifier: String
    /// The resume's own `date`, joined rather than copied. See the type comment.
    let effectiveAt: Date
    let rateUnitsPerHour: Double
    let source: Source
    let recordedAt: Date
}

// MARK: - The history

/// The rate history over the span one derivation can reach, fetched in the same
/// transaction as the dose rows so the two cannot disagree (§5).
///
/// Same I3 shape as suspension: the newest record at or before `inferenceStart`,
/// plus every record in `(inferenceStart, at]`.
struct ScheduledBasalHistory: Equatable {
    /// Ordered by `effectiveAt`. The first entry is at or before
    /// `inferenceStart`, so every instant the derivation can reach has a rate —
    /// which the clamp is what actually guarantees (§7).
    let records: [ScheduledBasalRecord]

    /// Whether each record's rate differs from the record before it.
    ///
    /// Precomputed over the whole array rather than per query, because
    /// "differs from its predecessor" is a property of the history and not of the
    /// range being asked about. The first record is never a change: it has no
    /// predecessor to differ from, and it cannot fall strictly inside a piece the
    /// derivation reaches (if it did, `record(at: pieceStart)` would be nil and
    /// the piece would not be derived at all).
    private let isChange: [Bool]

    /// Rates are pod-programmed multiples of 0.05 U/hr, so anything this close is
    /// the same rate arriving through a different arithmetic path.
    static let rateEpsilon = 1e-9

    static let empty = ScheduledBasalHistory(records: [])

    init(records: [ScheduledBasalRecord]) {
        let sorted = records.sorted { $0.effectiveAt < $1.effectiveAt }
        self.records = sorted
        self.isChange = sorted.indices.map { index in
            guard index > 0 else { return false }
            return abs(sorted[index].rateUnitsPerHour - sorted[index - 1].rateUnitsPerHour) > Self.rateEpsilon
        }
    }

    /// The record in effect at `instant`, or nil when history does not reach it.
    ///
    /// nil is supposed to be unreachable: the clamp includes the earliest
    /// surviving record, so any gap the derivation does not suppress has a record
    /// at or before it (§7). The derivation still handles nil by emitting
    /// nothing, because omitting a segment is the safe direction and fabricating
    /// one at a guessed rate is the mistake this whole store exists to prevent.
    func record(at instant: Date) -> ScheduledBasalRecord? {
        return records.last { $0.effectiveAt <= instant }
    }

    func rate(at instant: Date) -> Double? {
        return record(at: instant)?.rateUnitsPerHour
    }

    /// Records **strictly after** `start` and before `end` whose rate differs
    /// from the record before them.
    ///
    /// Returns records rather than bare dates on purpose. The caller needs the
    /// rate that begins at each boundary, and taking it from the record it
    /// already holds is what keeps §3.1's boundary out of a float comparison.
    ///
    /// The strict `>` here and the `<=` in `record(at:)` partition the instant
    /// exactly, whatever the floating-point values are: a record at exactly
    /// `start` supplies the piece's own rate and is not also a boundary inside
    /// it.
    ///
    /// **Re-assertions are filtered.** §3.3 writes a record at every resume, so
    /// most records repeat the previous rate. A repeat is not a boundary and must
    /// not split a segment — otherwise every pod change fragments an inferred
    /// segment for no reason, costing a pulse and shifting the five-minute chunk
    /// grid. It is also what makes the verifier's parity claim true and what makes
    /// the migration backfill invisible to derivation.
    func changes(after start: Date, before end: Date) -> [ScheduledBasalRecord] {
        return records.indices.compactMap { index in
            guard isChange[index] else { return nil }
            let record = records[index]
            guard record.effectiveAt > start, record.effectiveAt < end else { return nil }
            return record
        }
    }

    /// How many records actually changed the rate, for the diagnostics snapshot.
    var changeCount: Int {
        return isChange.filter { $0 }.count
    }
}

// MARK: - The pending-program queue

/// A program we pushed to the pod and have not yet seen acknowledged (§4.1).
///
/// **Not history, and it never serves a lookup.** That is the whole point. An
/// earlier design inserted a rate record at the app's clock on acknowledgment
/// and, when it went unlinked, kept serving lookups from it — so a failed sync
/// silently governed the rate from an instant at which the pod was suspended and
/// never resumed at that rate. That is the §1.1 defect reintroduced downstream of
/// the fix for it.
///
/// Persisted rather than held in memory so it survives an app kill between
/// acknowledgment and the next pump sync.
struct ScheduledBasalProgram: Equatable {
    let id: Int64
    let rateUnitsPerHour: Double
    /// The app's clock at acknowledgment. Used only for matching and diagnostics
    /// — never as a rate boundary, so nothing rests on it being right.
    let requestedAt: Date
    let consumedBySyncIdentifier: String?
    /// Set when the program aged out unconsumed: we programmed and never saw the
    /// acknowledgment.
    let abandonedAt: Date?
}

// MARK: - Ingest and diagnostics

/// What one ingest's reconciliation did (§4.1).
struct ScheduledBasalIngestResult: Equatable {
    /// Records minted by this pass.
    let minted: [ScheduledBasalRecord]
    /// Programs marked abandoned by this pass — enqueued, never acknowledged.
    /// A diagnostic rather than a wrong rate, which is the disposition a failed
    /// program deserves.
    let abandonedPrograms: Int
    /// Resumes old enough to resolve that matched no pending program and had no
    /// preceding record, so no rate could be attributed to them at all. Expected
    /// only before the first record exists.
    let unresolvedResumeSyncIdentifiers: [String]

    static let none = ScheduledBasalIngestResult(
        minted: [],
        abandonedPrograms: 0,
        unresolvedResumeSyncIdentifiers: []
    )
}

/// Everything §8 asks the store to surface about the rate history, none of which
/// can be asked of the residual series alone.
struct ScheduledBasalDiagnostics: Equatable {
    let acknowledgedRecordCount: Int
    /// Split out from acknowledged records so a backfilled row is never counted
    /// as an observation.
    let backfilledRecordCount: Int
    /// Records that actually changed the rate. The verifier's new term is zero
    /// until this is non-zero.
    let changeCount: Int
    let pendingProgramCount: Int
    let abandonedProgramCount: Int
    /// Live resumes with no record, old enough that one should have resolved.
    let resumesWithNoRecordCount: Int

    static let empty = ScheduledBasalDiagnostics(
        acknowledgedRecordCount: 0,
        backfilledRecordCount: 0,
        changeCount: 0,
        pendingProgramCount: 0,
        abandonedProgramCount: 0,
        resumesWithNoRecordCount: 0
    )
}
