//
//  InsulinRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/3/26.
//
//  The protocol seam over the complete, indexed store of pump-reported events
//  that replaces the 24-hour JSON log. See dev/backlog/insulin-storage-grdb.md.
//
//  Everything this protocol speaks is a domain value. GRDB lives behind it, in
//  `GRDBInsulinRecordStore`, which is the mitigation §9 asks for: a third-party
//  dependency in the most safety-critical store in the app is tolerable exactly
//  to the extent that it is swappable and the tests never touch it.
//
//  The invariants this store exists to hold (§3):
//
//    I1. It holds what the pump reported, and nothing derived.
//    I2. A row is mutable until the pump's finalized report replaces it; once
//        immutable it never changes.
//    I3. State queries may look back past the window. Timeline queries may not.
//    I4. Inference never fills a gap starting before `historyCompleteSince`.
//    I5. History is trustworthy on [historyCompleteSince, lastReconciliation].
//
//  I3 is the root-cause fix, and it is structural here rather than a rule to
//  remember: `PumpDoseTimeline.doses` cannot contain a suspend or a resume, so
//  the array gap-filling walks has no way to mistake a three-week-old `resume`
//  for a delivery boundary.
//

import Foundation
import LoopKit

/// One `addPumpEvents` call, as the store sees it.
struct PumpEventBatch {
    let events: [NewPumpEvent]
    /// The driver's own statement of how far its reported history is complete —
    /// I5's right edge. Currently thrown away by `LocalInsulinStorage` (§5.2).
    let lastReconciliation: Date?
    /// *This batch is the driver's complete current set of pending (mutable)
    /// doses.* A full replacement of the mutable frontier, not a merge.
    ///
    /// Per call, and both values occur in one driver:
    /// `OmniPumpManager.store(doses:)` passes true because a dose report is a
    /// full re-assertion, and the pod-change pseudo-event passes false because
    /// it asserts nothing about pending doses. A store that treats the purge as
    /// always-on deletes every in-flight dose the moment a pod change fires
    /// (§5.1).
    let replacePendingEvents: Bool
    /// What the pump and insulin were when these events arrived. Captured per
    /// call because people change pumps and insulins across a history.
    let pump: PumpMetadata
    /// The ingest instant, which becomes each row's `recordedAt`.
    let at: Date
}

/// What one ingest did, in enough detail for the phase 1 verifier to account for
/// every difference it creates between the two paths.
struct PumpEventIngestResult {
    let upserted: [PumpEventRecord]
    /// Live mutable rows the batch did not assert, soft-deleted by this call.
    /// Only ever non-empty when `replacePendingEvents` was true — a revocation
    /// on a false call is a regression (§5.1).
    let revoked: [PumpEventRecord]
    /// Previously-revoked identifiers this batch re-asserted.
    ///
    /// Each of these is a decision-9 **reappearance**, and each is a stop-ship
    /// for cutover. A correct revocation means the driver has abandoned the dose
    /// for good, so a revoked dose coming back at all says the revocation was
    /// wrong — the highest-risk unknown in the plan, and the reason the whole
    /// global-revocation argument in §5.1.1 is instrumented rather than reasoned
    /// about.
    ///
    /// The row itself comes back intact regardless: same row, `recorded_at`
    /// preserved, `deleted_at` cleared. Losing data is a separate failure from
    /// having revoked wrongly, and only one of them is measured by this list.
    let reassertedAfterRevocation: [String]
    /// Doses that arrived carrying no driver `syncIdentifier` and so got a
    /// synthetic one. Expected to be empty on every device GlucOS runs on; a
    /// non-empty list explains a verifier residual that would otherwise look
    /// unaccounted, because the old JSON path drops such doses outright.
    let syntheticDoseIdentifiers: [String]
    /// What retention did on this call, and where it left the store's left edge.
    let retention: RetentionOutcome
    /// Where the clamp sits after this call.
    let historyCompleteSince: Date
    /// What the scheduled-basal reconciliation did, per
    /// dev/backlog/scheduled-basal-history.md §4.1.
    let scheduledBasal: ScheduledBasalIngestResult
}

/// Where retention left the store's oldest edge (§4.3).
///
/// Retention hard-deletes rather than soft-deleting, unlike revocation: a soft
/// delete kept forever is not retention. What keeps the boundary honest is
/// `historyCompleteSince` moving with it (I4) — and what keeps the clamp from
/// landing *later* than the boundary, stranding retained rows in a span nothing
/// may infer across, is anchoring the boundary on a resume.
struct RetentionOutcome: Equatable {
    /// Rows hard-deleted on this call.
    let pruned: Int
    /// The instant before which the store now holds nothing. Every surviving row
    /// is at or after it, so this — not the nominal 90-day cutoff — is what the
    /// clamp must move with.
    let boundary: Date
    /// The resume the boundary was anchored on, when one was found.
    ///
    /// Non-nil is the healthy case and makes I6 hold. Nil means no resume
    /// carrying a rate record was found within
    /// `retentionAnchorMaxLookback` of the cutoff, so the boundary fell back to
    /// the nominal cutoff and the store degrades to clamp-only behavior: correct,
    /// but with up to one inter-resume interval of retained-yet-uninferable
    /// history at the left edge. It also means the mechanism scheduled-basal
    /// history §2 rests on has stopped firing, which is worth surfacing.
    let anchorSyncIdentifier: String?

    var isAnchored: Bool { anchorSyncIdentifier != nil }
}

/// A live mutable row old enough to be an anomaly rather than a dose (§5.3).
///
/// It means either the driver stopped re-asserting it — the orphan case
/// `replacePendingEvents` exists to clear — or our own finalization is broken.
/// This is the cheapest available detector for both failure modes in §5.1.1,
/// and the verifier's `R` term is meaningless without it.
struct StaleMutableDose: Equatable {
    let syncIdentifier: String
    let doseStart: Date
    let age: TimeInterval
    /// What it would contribute if counted, so the log says how much is at stake
    /// and not merely that something is stale.
    let units: Double
}

/// A suspend or a resume, as evidence rather than as state.
struct PumpSuspensionTransition: Equatable {
    let at: Date
    let isSuspended: Bool
}

/// Everything the pure inference sweep needs, fetched in one transaction so the
/// row set and the state answers cannot disagree with each other.
struct PumpDoseTimeline {
    /// Live doses overlapping `[windowStart, at)`, plus the last basal-ish dose
    /// that ended before `windowStart` as the left anchor (decision 3).
    ///
    /// Never contains a suspend or a resume. That absence is I3: it is what
    /// makes the fabricated segment unconstructible rather than merely
    /// unlikely.
    let doses: [DoseEntry]
    /// The latest suspend or resume at or before `inferenceStart`, answered by a
    /// state query that may look arbitrarily far back (I3). nil when the store
    /// has never seen one.
    ///
    /// Its *instant* travels with it rather than just the boolean, because the
    /// derivation needs to ask whether any delivery happened after it — a temp
    /// basal that ran while we believed the pump was suspended is evidence the
    /// pump resumed, and that question cannot be asked of a bare `Bool`.
    let suspensionAtInferenceStart: PumpSuspensionTransition?
    /// Transitions inside `(inferenceStart, at]` — every one inference can see,
    /// with `suspensionAtInferenceStart` covering everything before them.
    ///
    /// Bounded by `inferenceStart` rather than `windowStart` so that suspension
    /// evidence spans exactly what dose evidence spans. A pair that falls between
    /// the anchor's end and the window's start is inside the first gap, and the
    /// resume in it is that gap's true left edge; bounding here at `windowStart`
    /// discarded it and left the gap starting at the anchor's end instead.
    let suspensionTransitions: [PumpSuspensionTransition]
    /// I4's left edge, and I5's.
    let historyCompleteSince: Date
    /// I5's right edge. Doses after it are held, read, and counted toward IOB —
    /// an in-flight bolus must not be invisible — but they are understood as
    /// unreconciled, and they are the rows `replacePendingEvents` may revoke.
    let lastReconciliation: Date?
    let windowStart: Date
    /// The left edge of everything inference may conclude: the anchor dose's
    /// `endDate`, or `windowStart` when there is no anchor. Never later than
    /// `windowStart`.
    ///
    /// Segments are emitted in full and windowed in the sums, so a segment
    /// starting here rather than at `windowStart` is not a leak — it is what
    /// decision 3's over-fetch is for. What matters is that every kind of
    /// evidence share this edge: doses, suspension state, and transitions all
    /// begin here, so no stretch of the derivation has one and not another.
    let inferenceStart: Date
    let at: Date
    /// The pulse size inference truncates to (decision 2). Taken from the newest
    /// row that carries one, falling back to the Omnipod value, because a pump
    /// that reports nothing usable must not make a reader divide by zero.
    let smallestDeliveryUnit: Double
    /// What the pod was programmed with, over the span this derivation reaches.
    /// See dev/backlog/scheduled-basal-history.md §5.
    ///
    /// Fetched in the same transaction as everything else, so the row set and the
    /// rates cannot disagree with each other. It replaces the
    /// `scheduledRateInUnitsPerHour` parameter `derive` used to take — the last
    /// place a present-tense value reached a past-tense conclusion.
    let scheduledBasal: ScheduledBasalHistory
}

enum InsulinRecordStoreError: Error {
    /// A database that cannot be opened is a dosing outage and must be loud
    /// (§8). Stricter than the JSON path, where a failed read silently yields
    /// an empty log and an IOB of 0.
    case couldNotOpen(String)
    case writeFailed(String)
    case readFailed(String)
}

protocol InsulinRecordStore: Sendable {
    /// One transaction per batch. Partial application followed by an error would
    /// double-apply on redelivery; upsert makes that harmless, but §8 says not
    /// to rely on it.
    ///
    /// Throwing is the safety mechanism, not a nuisance: `addPumpEvents` returns
    /// the error, `DeviceDataManager+Pump` passes it to the completion handler,
    /// and `OmniPumpManager` re-delivers rather than clearing
    /// `state.unstoredDoses`. In phase 1 the caller deliberately swallows this,
    /// because a store nothing believes must not be able to fail the loop.
    func ingest(_ batch: PumpEventBatch) async throws -> PumpEventIngestResult

    /// The snapshot inference runs over. `windowStart` bounds the timeline;
    /// state answers inside the snapshot may look further back (I3).
    ///
    /// - Parameter includeRevoked: normally false, because a revoked dose is not a
    ///   dose. The phase 1 verifier passes true to derive the counterfactual it
    ///   needs for the `R` term: revoking a dose does not merely subtract its
    ///   units, it opens a gap that inference then fills, and only a second
    ///   derivation can measure the net of those two.
    func timeline(windowStart: Date, at: Date, includeRevoked: Bool) async throws -> PumpDoseTimeline

    // MARK: - Scheduled basal (dev/backlog/scheduled-basal-history.md)

    /// Records a basal schedule we just successfully pushed to the pod.
    ///
    /// This does **not** write a rate record. It enqueues a *pending program*,
    /// which is not history and never serves a lookup, and which a resume later
    /// consumes (§4.1). Call it on success only — never before, never on failure.
    /// That is §1.1's fix.
    ///
    /// Note that success does not imply the pod was touched:
    /// `OmniPumpManager.setBasalSchedule` opens with `guard state.hasActivePod
    /// else { save the schedule to state; completion(nil); return }`, so
    /// `syncBasalRateSchedule` reports success without programming anything when
    /// no pod is active. A design that wrote a record on success would write a
    /// false one there; here the program is simply never consumed and ages out
    /// into `abandonedPrograms`, which is the second reason the queue exists.
    ///
    /// Enqueuing also runs reconciliation, so a resume that has already arrived
    /// and is still waiting for its rate gets it immediately. That closes the
    /// ordering race at pod activation, where the pod's resume can be reported
    /// before onboarding completes.
    func enqueueScheduledBasalProgram(rateUnitsPerHour: Double, at: Date) async throws

    /// What §8 asks the store to surface about the rate history.
    func scheduledBasalDiagnostics(at: Date) async throws -> ScheduledBasalDiagnostics

    // MARK: - State queries (§6.3), each its own query, each free to look back

    func isSuspended(at: Date) async throws -> Bool
    func pumpAlarm(at: Date) async throws -> PumpAlarmType?
    func currentInsulinType(at: Date) async throws -> InsulinType?
    func activeBolus(at: Date) async throws -> DoseEntry?
    func lastReconciliation() async throws -> Date?
    func historyCompleteSince() async throws -> Date

    // MARK: - Diagnostics

    /// Rows by their own event date.
    ///
    /// `includeRevoked` is the only way to see a soft-deleted row; every other
    /// read filters `deleted_at IS NULL`, because a revoked dose is not a dose.
    /// The verifier needs the revoked ones to measure `R`, and the diagnostics
    /// view needs the live ones (decision 11).
    func records(from: Date, to: Date, includeRevoked: Bool) async throws -> [PumpEventRecord]

    /// Live mutable rows old enough to be anomalies (§5.3).
    func staleMutableDoses(at: Date) async throws -> [StaleMutableDose]

    /// A self-contained snapshot of the store to hand to `ShareLink`, so the
    /// parallel run's two databases come off the device together.
    ///
    /// The verifier's snapshot answers the gate; this one answers *why*. The
    /// clamp's two edges, how much history we hold, the basal coverage gaps that
    /// P and C only matter in proportion to, and every §11.1 coverage question —
    /// whether the run actually saw a pod change, a suspend, an outage — are all
    /// queries against the store, and none of them can be asked of the residual
    /// series alone.
    ///
    /// nil rather than throwing when there is nothing to snapshot: this is a
    /// diagnostic, and §8's rule that a store failure must be loud is about the
    /// reads the loop doses off. Nothing doses off a share sheet.
    func exportSnapshotURL() async -> URL?
}

// MARK: - Policy constants

enum InsulinRecordStorePolicy {
    /// Decision 1. On from phase 1, and outside the verifier's comparison
    /// window, so it costs the parallel run nothing. `historyCompleteSince`
    /// tracks the cutoff, because pruning re-creates exactly the boundary that
    /// caused the bug this store fixes.
    static let retention = 90.0.daysToSeconds()

    /// How far back of the nominal cutoff retention will reach to find a resume
    /// to anchor its boundary on (§4.3).
    ///
    /// The anchor is normally minutes to hours older than the cutoff, and is
    /// bounded in principle by `Pod.serviceDuration` — 80 hours — because a pod
    /// cannot run longer than that without being replaced, and every activation
    /// mints a resume. Fourteen days is far past that on purpose: this is not a
    /// tuning knob, it is a **backstop on a behavioral assumption about the
    /// driver**, and scheduled-basal-history §2.1 is a correction admitting that
    /// assumption was got wrong once already.
    ///
    /// If it is ever exceeded, the mechanism has stopped firing and retention
    /// falls back to the nominal cutoff rather than growing the file without
    /// bound. Storage exhaustion on a device that doses insulin is a worse
    /// failure than losing a pod cycle of inferable history, and it arrives
    /// silently.
    static let retentionAnchorMaxLookback = 14.0.daysToSeconds()

    /// §5.3. Roughly twice the longest temp basal a driver will program, so a
    /// live mutable row older than this is an orphan or a finalization bug.
    ///
    /// A comms outage longer than this legitimately trips it, and that is
    /// information rather than noise: an outage is one of the two conditions
    /// §5.3 exists to surface.
    static let staleMutableDoseThreshold = 1.0.hoursToSeconds()

    /// How far back an IOB derivation reaches.
    ///
    /// Comfortably past the longest insulin model GlucOS uses, which is what
    /// bounds an IOB answer. An inferred segment can legitimately be much
    /// longer than this — a pod that ran unattended for 40 hours — and that is
    /// handled by the over-fetch plus clipping (decision 3) rather than by
    /// widening the window.
    static let insulinOnBoardWindow = 12.0.hoursToSeconds()

    /// The pulse size to assume when no row carries one. Omnipod reports 0.05 U;
    /// falling back to zero instead would make truncation divide by zero.
    static let smallestDeliveryUnitDefault = PumpMetadata.smallestDeliveryUnitDefault

    /// How far apart a pending program's `requested_at` and a resume's `date` may
    /// be and still be the same event (scheduled-basal-history §4.1).
    ///
    /// **Bounded by how long the driver takes to report the resume, not by clock
    /// skew.** Both timestamps come from the app's clock — the resume's `date` is
    /// `currentDate` inside `PodCommsSession`, and `requested_at` is `Date()` when
    /// `syncBasalRateSchedule`'s completion handler unwinds — so they are seconds
    /// apart in wall time. What is *not* bounded by seconds is when the dose gets
    /// into an `addPumpEvents` batch: `OmniPumpManager` reports on its own
    /// cadence, which is the loop period. The design doc's ~120 s was written
    /// against clock skew and is too tight for that; a window shorter than the
    /// reporting cadence abandons programs that were about to be acknowledged and
    /// then attributes their resume to the previous rate.
    ///
    /// Comfortably past the five-minute loop period, and still short enough that
    /// an unrelated manual suspend/resume falling inside it is a rarity — which is
    /// the mis-attribution this window exists to guard against, now that it no
    /// longer has a timestamp to reconcile.
    static let scheduledBasalProgramMatchWindow = 15.0.minutesToSeconds()
}
