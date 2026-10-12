//
//  InsulinRecordTimeline.swift
//  BioKernel
//
//  Created by Sam King on 8/3/26.
//
//  The record store's inference sweep. See dev/backlog/insulin-storage-grdb.md
//  §6.1 and §6.1.1.
//
//  Pure, and nothing here is persisted. That is deliberate and it is the whole
//  argument of §2.1: we never hold evidence for an inferred segment — the
//  evidence is *absence* — and writing a conclusion drawn from absence into a
//  store that cannot revise it is how a 40-hour fabrication becomes permanent
//  instead of merely repeated. Kept in memory, inference is self-healing: a dose
//  that arrives late, inside a span previously inferred, simply changes the next
//  answer.
//
//  The only derivation insulin arithmetic uses. `InsulinTimeline.basalSegments`
//  still exists, but only for the AI interface exporter and the diagnostics view,
//  whose published record ids are anchored to the segment instants it produces.
//
//  Three things it does that `InsulinTimeline.basalSegments` does not:
//
//    - Suspend and resume are not elements of the array it walks. They arrive as
//      a parameter (I3). That is the root-cause fix: the fabricated segment
//      cannot be constructed, because the stale marker is no longer something
//      `zip(basalDoses, basalDoses.dropFirst())` can pair with.
//    - It refuses to fill a gap starting before `historyCompleteSince` (I4).
//    - Reported units win, and inferred units truncate to whole pulses — a pump
//      cannot deliver a partial pulse (decision 2).
//
//  One refinement of decision 3, which asks for out-of-window segments to be
//  "clipped rather than dropped": segments here are emitted **in full**, from the
//  over-fetched left anchor, and the windowing happens in the sums. That serves
//  decision 3's intent — an over-fetched segment's in-window delivery is counted
//  rather than lost — and it avoids the error clipping would introduce. A dose is
//  quantized into five-minute chunks anchored at its own `startDate`
//  (`DoseEntry.insulinDeliveryQuantized`), so moving a segment's left edge to the
//  window's edge re-aligns every chunk in it and re-truncates its total. Both
//  shift a windowed sum by up to one chunk, for no gain.
//

import Foundation
import LoopKit

/// One stretch of the basal picture, with its units stated rather than derived.
///
/// Deliberately not `BasalSegment`, whose `reportedUnits` is nil precisely to
/// mean "inferred, so integrate rate × duration". Quantized inference has to say
/// a number that is neither reported nor `rate × duration`, and overloading that
/// optional to carry it would make the same field mean two different things.
struct InferredBasalSegment: Equatable {
    let startDate: Date
    let endDate: Date
    let rateInUnitsPerHour: Double
    let insulinType: InsulinType
    let kind: BasalSegmentKind
    /// What we believe was delivered. For `.scheduled` this is `rate × duration`
    /// truncated to whole pulses; for `.suspended` it is zero by construction.
    let unitsDelivered: Double

    var duration: TimeInterval {
        return endDate.timeIntervalSince(startDate)
    }

    func asDoseEntry() -> DoseEntry {
        return DoseEntry(
            type: .basal,
            startDate: startDate,
            endDate: endDate,
            value: rateInUnitsPerHour,
            unit: .unitsPerHour,
            deliveredUnits: unitsDelivered,
            insulinType: insulinType,
            isMutable: false
        )
    }
}

enum InsulinRecordTimeline {

    /// Everything one derivation produced.
    struct Derivation {
        /// The reconciled doses: temp basals with overlaps trimmed, plus boluses.
        ///
        /// The temp basals are **not** re-emitted as segments — they are already
        /// here, and counting them twice is the one arithmetic mistake this split
        /// exists to make impossible.
        let doses: [DoseEntry]
        /// Scheduled-basal and suspension stretches. A suspension carries zero
        /// units, so including it costs nothing and keeps the picture gapless.
        let inferredSegments: [InferredBasalSegment]

        func insulinOnBoard(at: Date) -> Double {
            return Self.sum(doses, inferredSegments) { $0.insulinOnBoard(at: at) }
        }

        func insulinDelivered(startDate: Date, endDate: Date) -> Double {
            return Self.sum(doses, inferredSegments) {
                $0.insulinDeliveredBetween(startDate: startDate, endDate: endDate)
            }
        }

        /// Automatic temp basal only — what the loop itself programmed, as
        /// opposed to everything the pump delivered.
        ///
        /// The inferred segments are deliberately absent rather than forgotten.
        /// Scheduled basal is what the pump falls back to when no temp basal is
        /// running; it is not something the loop asked for, so counting it here
        /// would credit the loop with delivery it did not program. The old path
        /// draws the same line by filtering `deduplicatedDoses` and never
        /// consulting `inferBasalDoses`.
        func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) -> Double {
            return doses
                .filter { !$0.manuallyEntered && $0.type == .tempBasal }
                .map { $0.insulinDeliveredBetween(startDate: startDate, endDate: endDate) }
                .reduce(0, +)
        }

        private static func sum(
            _ doses: [DoseEntry],
            _ segments: [InferredBasalSegment],
            _ contribution: (DoseEntry) -> Double
        ) -> Double {
            let fromDoses = doses.map(contribution).reduce(0, +)
            let fromSegments = segments.map { contribution($0.asDoseEntry()) }.reduce(0, +)
            return fromDoses + fromSegments
        }
    }

    // MARK: - Derivation

    static func derive(timeline: PumpDoseTimeline) -> Derivation {
        let at = timeline.at
        let clamp = timeline.historyCompleteSince
        let pulse = timeline.smallestDeliveryUnit

        // Doses starting at or after `at` are not yet history. Same cutoff the
        // JSON path applies in `deduplicatedDoses`, so the two paths can't
        // disagree about the present.
        let candidates = timeline.doses.filter { $0.startDate < at }.sorted { $0.startDate < $1.startDate }

        // The fallback insulin type comes from the most recent temp basal or
        // bolus, matching `InsulinTimeline`. Suspend and resume are not here to
        // exclude — LoopKit emits suspend with no insulin type at all, which is
        // why that rule exists in the first place.
        let fallbackInsulinType = candidates
            .filter { $0.type == .tempBasal || $0.type == .bolus }
            .last?.insulinType ?? .humalog

        let unreconciledBasal = candidates.filter { $0.type == .tempBasal || $0.type == .basal }
        let reconciledBasal = reconciled(unreconciledBasal)
        let boluses = candidates.filter { $0.type == .bolus }

        let transitions = timeline.suspensionTransitions
            .filter { $0.at > timeline.inferenceStart && $0.at <= at }
            .sorted { $0.at < $1.at }
        let isSuspendedAtInferenceStart = suspendedAtInferenceStart(timeline: timeline, basalDoses: reconciledBasal)
        let suspensions = suspendedIntervals(
            isSuspendedAtInferenceStart: isSuspendedAtInferenceStart,
            inferenceStart: timeline.inferenceStart,
            transitions: transitions,
            basalDoses: reconciledBasal,
            at: at
        )

        var inferred: [InferredBasalSegment] = []

        // A suspension is evidence of zero delivery, so emitting one can never
        // fabricate insulin and the clamp has no reason to withhold it.
        for suspension in suspensions {
            guard suspension.end.timeIntervalSince(suspension.start) > InsulinTimeline.minimumInferredSegmentDuration else {
                continue
            }
            inferred.append(InferredBasalSegment(
                startDate: suspension.start,
                endDate: suspension.end,
                rateInUnitsPerHour: 0,
                insulinType: fallbackInsulinType,
                kind: .suspended,
                unitsDelivered: 0
            ))
        }

        // What the pump ran between one boundary and the next, plus the trailing
        // stretch up to `at`. Never before the first boundary: without a left
        // edge there is nothing to infer *from*, which is why the store
        // over-fetches the last dose before the window (decision 3) rather than
        // guessing at one.
        //
        // The boundaries are the basal doses **and the suspension transitions**.
        // That second half is the other side of I3: a resume says the pump
        // started running its schedule at that instant, and that is a real left
        // edge. Dropping it would lose the scheduled basal between a resume and
        // the next temp basal, which is real delivery.
        //
        // Both kinds of boundary now reach back to `inferenceStart`, and they
        // have to reach equally far. They used to disagree — doses came from the
        // anchor's end, transitions only from `windowStart` — and a completed
        // suspend/resume pair landing between the two was simply dropped: the
        // first gap kept the anchor's end as its left edge and inference ran the
        // scheduled rate straight across a stretch the pump had been suspended
        // for. A settings change mints exactly that pair, so it was routine
        // rather than exotic.
        //
        // The error mostly hid, because a mis-anchored gap is only mis-anchored
        // in windows where the mis-anchored part falls outside the window. What
        // leaked was the five-minute chunk grid: `insulinDeliveryQuantized`
        // anchors chunks at a dose's own `startDate`, so moving a segment's left
        // edge re-aligns every chunk in it, and a windowed sum moves by up to one
        // chunk. That is how a 481 ms disagreement surfaced as a residual.
        let boundaries: [(start: Date, end: Date)] = (
            reconciledBasal.map { (start: $0.startDate, end: $0.endDate) }
            + transitions.map { (start: $0.at, end: $0.at) }
        ).sorted {
            $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start
        }

        var gaps: [(start: Date, end: Date)] = []
        for (current, next) in zip(boundaries, boundaries.dropFirst()) {
            gaps.append((current.end, next.start))
        }
        if let last = boundaries.last {
            gaps.append((last.end, at))
        }

        for gap in gaps {
            guard gap.end.timeIntervalSince(gap.start) > InsulinTimeline.minimumInferredSegmentDuration else {
                continue
            }

            // I4, and it is a suppression rather than a clip.
            //
            // The distinction matters: clipping says "the part outside the
            // window is somebody else's business", and suppression says "the
            // reason this gap exists is that the evidence was deleted, so its
            // content is unknown". Filling it at the scheduled rate would be
            // asserting that nothing happened over a span we cannot see, which
            // is the exact mistake that produced a 40.4-hour, 16.164 U phantom.
            //
            // The whole gap goes, not the part before the clamp: a gap's content
            // is unknown as a unit, and emitting its right-hand piece would
            // assert a left edge the deleted evidence was supposed to supply.
            guard gap.start >= clamp else { continue }

            for piece in subtracting(suspensions, from: gap) {
                guard piece.end.timeIntervalSince(piece.start) > InsulinTimeline.minimumInferredSegmentDuration else {
                    continue
                }

                // A rate change subdivides the piece. It is deliberately *not* a
                // boundary above: `boundaries` is evidence of delivery, and a rate
                // change is not evidence that the pump did anything. Putting one
                // there would let it act as an inference left-anchor where no dose
                // evidence exists — opening a gap from a non-delivery event, which
                // is the exact fabrication class this store was built to prevent.
                for stretch in subdivide(piece, history: timeline.scheduledBasal) {
                    let duration = stretch.end.timeIntervalSince(stretch.start)
                    guard duration > InsulinTimeline.minimumInferredSegmentDuration else { continue }
                    let rawUnits = stretch.rate / 1.hoursToSeconds() * duration
                    inferred.append(InferredBasalSegment(
                        startDate: stretch.start,
                        endDate: stretch.end,
                        rateInUnitsPerHour: stretch.rate,
                        insulinType: fallbackInsulinType,
                        kind: .scheduled,
                        unitsDelivered: truncateToWholePulses(rawUnits, pulse: pulse)
                    ))
                }
            }
        }

        return Derivation(
            doses: (reconciledBasal + boluses).sorted { $0.startDate < $1.startDate },
            inferredSegments: inferred.sorted { $0.startDate < $1.startDate }
        )
    }

    // MARK: - reconciled() (§6.1.1)

    /// Trims an overlapping temp basal to the next one's start, rescaling its
    /// delivered units by the duration ratio.
    ///
    /// LoopKit runs this before anything else looks at a dose timeline, and
    /// `InsulinTimeline.basalSegments` does not: it emits both doses at full
    /// duration and counts the overlap twice, on the grounds that the pump driver
    /// truncates a superseded temp basal's `endDate` when it goes immutable, so
    /// overlaps never survive deduplication. The parallel run measured that
    /// difference across 7.1 days and found it indistinguishable from zero, which
    /// is the evidence for the assumption; trimming here means nothing rests on it.
    ///
    /// Rescaling is a real reduction, not a redistribution: LoopKit's `trimmed`
    /// scales the units by `newDuration / originalDuration`, and truncating the
    /// duration while keeping the units would move insulin earlier in time rather
    /// than remove it.
    ///
    /// Deliberately *not* quantized here, unlike an inferred segment: a reported
    /// dose's units are what the pump said it delivered, and re-truncating a
    /// number the pump already rounded would lose a pulse that really happened.
    static func reconciled(_ doses: [DoseEntry]) -> [DoseEntry] {
        var result: [DoseEntry] = []
        for dose in doses.sorted(by: { $0.startDate < $1.startDate }) {
            if let last = result.last, last.type == .tempBasal, last.endDate > dose.startDate {
                if dose.startDate > last.startDate {
                    result[result.count - 1] = trimmed(last, to: dose.startDate)
                } else {
                    // Superseded before it began. It delivered nothing, and a
                    // zero-length dose is noise rather than history.
                    result.removeLast()
                }
            }
            result.append(dose)
        }
        return result
    }

    private static func trimmed(_ dose: DoseEntry, to end: Date) -> DoseEntry {
        let originalDuration = dose.endDate.timeIntervalSince(dose.startDate)
        let newDuration = end.timeIntervalSince(dose.startDate)
        guard originalDuration > 0, newDuration > 0, newDuration < originalDuration else { return dose }

        let reportedUnits = dose.deliveredUnits ?? dose.programmedUnits
        return DoseEntry(
            type: dose.type,
            startDate: dose.startDate,
            endDate: end,
            value: dose.unitsPerHour,
            unit: .unitsPerHour,
            deliveredUnits: reportedUnits * newDuration / originalDuration,
            syncIdentifier: dose.syncIdentifier,
            insulinType: dose.insulinType,
            automatic: dose.automatic,
            manuallyEntered: dose.manuallyEntered,
            isMutable: dose.isMutable
        )
    }

    // MARK: - Suspension

    /// Whether the pump was suspended when inference begins.
    ///
    /// Not simply "the last transition was a suspend". The same rule §6.1.1
    /// encodes inside the window applies at this edge: **a temp basal that ran
    /// while we believe the pump was suspended is itself evidence that the pump
    /// resumed.** A suspend with delivery after it and no resume between means the
    /// pump resumed without saying so — and the over-fetched anchor is exactly the
    /// dose that proves it, since it is the latest basal dose before the window.
    ///
    /// (An earlier comment here justified this by claiming OmnipodKit mints a
    /// `resume` only for an explicit command. That is wrong — every pod activation
    /// mints one, via `programInitialBasalSchedule` — and the rule does not need it:
    /// what makes delivery evidence of resumption is the delivery, not the scarcity
    /// of resumes. See dev/backlog/scheduled-basal-history.md §2.1.)
    ///
    /// Without this, a stale open suspend would mask the first stretch of
    /// scheduled basal in every window, which is the same class of mistake as the
    /// fabrication — a stale marker outvoting real evidence — pointing the other
    /// way.
    ///
    /// Asked at `inferenceStart` rather than `windowStart` so that it meets the
    /// transition list exactly: the state query is `date <= inferenceStart` and
    /// the transition query is `date > inferenceStart`, so every transition is
    /// accounted for by exactly one of them.
    static func suspendedAtInferenceStart(timeline: PumpDoseTimeline, basalDoses: [DoseEntry]) -> Bool {
        guard let state = timeline.suspensionAtInferenceStart, state.isSuspended else { return false }
        let resumedByDelivery = basalDoses.contains { dose in
            dose.startDate > state.at && dose.startDate <= timeline.inferenceStart
        }
        return !resumedByDelivery
    }

    /// The stretches the pump was suspended over, from a starting state that may
    /// predate `inferenceStart` plus every transition after it.
    ///
    /// The interesting case is a suspension with no resume. LoopKit synthesizes a
    /// suspend covering `[suspend, nextBasal)` for exactly this, and the rule it
    /// encodes is one GlucOS lacks: a temp basal arriving while we believe the
    /// pump is suspended is itself evidence that the pump resumed. GlucOS
    /// currently reaches the same IOB by skipping the gap after a suspend, which
    /// is the right number from a weaker argument — and under I3, where
    /// suspension is a parameter rather than a timeline element, the rule has to
    /// be written down explicitly, because it is what bounds the interval.
    static func suspendedIntervals(
        isSuspendedAtInferenceStart: Bool,
        inferenceStart: Date,
        transitions: [PumpSuspensionTransition],
        basalDoses: [DoseEntry],
        at: Date
    ) -> [(start: Date, end: Date)] {
        var intervals: [(start: Date, end: Date)] = []
        // A suspension already in effect when inference opens starts at that
        // edge, not at the transition: the transition itself may be arbitrarily
        // old, and a suspension is only interesting where there is a gap for it
        // to cover. Clamping to `inferenceStart` rather than `windowStart` is
        // what keeps it aligned with the gaps, which start at the anchor's end.
        var openSince: Date? = isSuspendedAtInferenceStart ? inferenceStart : nil

        for transition in transitions.sorted(by: { $0.at < $1.at }) {
            if transition.isSuspended {
                if openSince == nil { openSince = transition.at }
            } else if let start = openSince {
                if transition.at > start { intervals.append((start, transition.at)) }
                openSince = nil
            }
        }

        if let start = openSince {
            let resumedByTempBasal = basalDoses.first { $0.startDate > start }?.startDate
            let end = resumedByTempBasal ?? at
            if end > start { intervals.append((start, end)) }
        }

        return intervals
    }

    // MARK: - Rate subdivision (scheduled-basal-history §6)

    /// One gap piece split at the instants the programmed rate actually changed,
    /// each stretch carrying its own rate.
    ///
    /// **Each rate comes from the record that produced the split, never from a
    /// lookup at the boundary.** That is the point of `changes` returning records
    /// rather than dates: `effective_at <= gapStart` is only correct at a boundary
    /// if the two doubles are identical, and here there is no comparison at all —
    /// the stretch beginning at a change reads the rate off the change itself.
    ///
    /// Three consequences, predicted in §6 of the doc rather than discovered later:
    ///
    /// - **Quantization.** Each stretch truncates to whole pulses independently, so
    ///   a change costs up to one pulse (0.05 U) downward, never upward.
    /// - **Chunk grid.** Splitting re-anchors `insulinDeliveryQuantized`'s
    ///   five-minute chunks at the new left edge, so a windowed sum can move by up
    ///   to one chunk. Correct here, because the boundary is real.
    /// - **Only on actual changes.** `ScheduledBasalHistory.changes` filters
    ///   re-assertions, so a device whose rate never changes produces exactly one
    ///   stretch per piece, and the migration backfill is invisible to derivation.
    ///
    /// Falls back to the **earliest** record's rate when the history does not reach
    /// the piece, and returns nothing at all when the history is empty.
    ///
    /// The fallback is very nearly unreachable: `historyCompleteSince` includes the
    /// earliest surviving record, so a piece the derivation emits always has a
    /// record at or before it (§7). It is kept because the alternative — returning
    /// nothing when a record exists but does not reach far enough — silently drops
    /// real delivery, and the earliest known rate is the only defensible estimate.
    ///
    /// An empty history is different in kind and returns nothing: there is no
    /// estimate to make. That is also the state in which the clamp suppresses
    /// everything (§7.2), so a store with no rate history infers nothing at all.
    private static func subdivide(
        _ piece: (start: Date, end: Date),
        history: ScheduledBasalHistory
    ) -> [(start: Date, end: Date, rate: Double)] {
        guard let opening = history.record(at: piece.start) ?? history.records.first else { return [] }

        var stretches: [(start: Date, end: Date, rate: Double)] = []
        var start = piece.start
        var rate = opening.rateUnitsPerHour
        for change in history.changes(after: piece.start, before: piece.end) {
            stretches.append((start, change.effectiveAt, rate))
            start = change.effectiveAt
            rate = change.rateUnitsPerHour
        }
        stretches.append((start, piece.end, rate))
        return stretches
    }

    // MARK: - Interval arithmetic

    /// A gap minus the suspensions inside it. Order is preserved, and an interval
    /// swallowed entirely by a suspension disappears.
    private static func subtracting(
        _ suspensions: [(start: Date, end: Date)],
        from gap: (start: Date, end: Date)
    ) -> [(start: Date, end: Date)] {
        var pieces = [gap]
        for suspension in suspensions.sorted(by: { $0.start < $1.start }) {
            var next: [(start: Date, end: Date)] = []
            for piece in pieces {
                guard suspension.start < piece.end, suspension.end > piece.start else {
                    next.append(piece)
                    continue
                }
                if suspension.start > piece.start { next.append((piece.start, suspension.start)) }
                if suspension.end < piece.end { next.append((suspension.end, piece.end)) }
            }
            pieces = next
        }
        return pieces
    }

    // MARK: - Quantization (decision 2)

    /// Truncates to a whole number of pulses.
    ///
    /// Truncation rather than rounding to nearest, because a pump cannot deliver
    /// a partial pulse — that is the physical model, not a rounding preference —
    /// and because it keeps the error single-signed: inference can only ever
    /// under-count, never invent a pulse.
    ///
    /// The tolerance is load-bearing. `0.3 / 0.05` is 5.999999999999999 in
    /// binary, so a bare `floor` would quantize an exact six-pulse segment down
    /// to five and lose a pulse per segment, every segment.
    static func truncateToWholePulses(_ units: Double, pulse: Double) -> Double {
        guard pulse > 0, units > 0 else { return max(units, 0) }
        let pulses = units / pulse
        let nearest = pulses.rounded()
        let wholePulses = abs(pulses - nearest) < 1e-9 ? nearest : pulses.rounded(.down)
        return wholePulses * pulse
    }
}
