//
//  InsulinRecordTimelineTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/3/26.
//
//  The tests that pin the defect. See dev/backlog/insulin-storage-grdb.md §10.
//
//  Two of these assert about *time* in a way the JSON log cannot express, and are
//  the reason this work exists: `theFabricationCannotBeConstructed` fails against
//  today's code, and `derivationIsIdempotent` is the property the bug violates.
//

import Testing
import Foundation
import LoopKit
@testable import BioKernel

struct InsulinRecordTimelineTests {
    static let now = Date(timeIntervalSince1970: 1_770_000_000)
    /// 0.4 U/hr, the rate the observed 40.4-hour phantom was inferred at.
    let scheduledRate = 0.4
    let tolerance = 1e-9

    /// A store whose rate history begins at its creation instant.
    ///
    /// Seeding is required rather than incidental: an empty `scheduled_basal`
    /// clamps everything (scheduled-basal-history §7.2), so a store with no rate
    /// record correctly refuses to infer anything at all. `emptyRateHistory` is how
    /// a test asks for that state deliberately.
    ///
    /// Seeded the way the app does it — a resume plus the program it acknowledges —
    /// rather than by writing the row directly, so every test exercises the real
    /// path and the whole suite doubles as §9's first gate: with no rate *changes*,
    /// output is identical to what passing the old scalar produced.
    ///
    /// Two properties make the seed inert, and both are load-bearing. Its resume
    /// sits a day *before* `createdAt`, so the clamp comes out
    /// `max(createdAt, retentionCutoff, createdAt - 1d)` — exactly what it was
    /// before a rate term joined it. And that also puts it before every window any
    /// test opens, which matters because a suspend/resume inside
    /// `(inferenceStart, at]` **is** a gap boundary: a seed landing in the window
    /// would split a gap and change the segment count. Outside it, the resume only
    /// informs `suspensionAtInferenceStart`, and a resume rather than a suspend
    /// keeps that answer "running", which is what nil used to mean.
    private func makeStore(
        createdAt: Date,
        rate: Double? = nil,
        emptyRateHistory: Bool = false
    ) async throws -> GRDBInsulinRecordStore {
        let store = try GRDBInsulinRecordStore(inMemoryCreatedAt: createdAt)
        guard !emptyRateHistory else { return store }
        let seedAt = createdAt - 1.0.daysToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: rate ?? scheduledRate, at: seedAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "rate-seed", at: seedAt)],
            at: seedAt
        ))
        return store
    }

    private func derive(
        _ store: GRDBInsulinRecordStore,
        windowStart: Date,
        at: Date
    ) async throws -> InsulinRecordTimeline.Derivation {
        let timeline = try await store.timeline(windowStart: windowStart, at: at)
        return InsulinRecordTimeline.derive(timeline: timeline)
    }

    // MARK: - The fabrication

    @Test func theFabricationCannotBeConstructed() async throws {
        // The observed failure, reproduced: a `resume` from 40 hours earlier
        // bounding a scheduled-basal segment on the left, and the first surviving
        // temp basal bounding it on the right. On the device that produced it the
        // segment carried 16.164 U — 95% of the day's published basal.
        //
        // The old path builds it because `zip(basalDoses, basalDoses.dropFirst())`
        // pairs the resume with the temp basal. Here the resume is not in the
        // array at all (I3), so there is nothing to pair.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        let resume = PumpEventFixtures.resume(id: "resume", at: at - 40.0.hoursToSeconds())
        // A stretch of ordinary loop activity in the last two hours.
        var events = [resume]
        var expectedReported = 0.0
        for index in 0..<24 {
            let start = at - 2.0.hoursToSeconds() + Double(index) * 5.0.minutesToSeconds()
            let delivered = 0.05
            expectedReported += delivered
            events.append(PumpEventFixtures.tempBasal(
                id: "tb-\(index)", start: start, duration: 5.0.minutesToSeconds(),
                rateUnitsPerHour: 0.6, deliveredUnits: delivered
            ))
        }
        _ = try await store.ingest(PumpEventFixtures.batch(events, at: at))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)

        // No segment may begin at the resume's end. That instant is the phantom's
        // left edge, and its absence is the fix.
        #expect(!derivation.inferredSegments.contains { $0.startDate == resume.date })

        // Nothing inferred at all here: the temp basals are back to back, so there
        // are no gaps between them, and the window opens after the resume.
        let inferredUnits = derivation.inferredSegments.map { $0.unitsDelivered }.reduce(0, +)
        #expect(abs(inferredUnits) < tolerance)

        let delivered = derivation.insulinDelivered(startDate: at - 12.0.hoursToSeconds(), endDate: at)
        #expect(abs(delivered - expectedReported) < 1e-6)
    }

    @Test func aRetainedSuspendStillYieldsZeroUnits() async throws {
        // Today's behavior for this case is already correct, and for the right
        // reason: a retained suspend with no later resume means the pump really was
        // suspended. Preserve it.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 21.0.daysToSeconds())
        let recent = PumpEventFixtures.tempBasal(
            id: "tb-1", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([suspend, recent], at: at))

        let windowStart = at - 12.0.hoursToSeconds()
        let derivation = try await derive(store, windowStart: windowStart, at: at)

        // The suspension is bounded on the right by the temp basal, because a temp
        // basal arriving while we believe the pump is suspended is itself evidence
        // that the pump resumed (§6.1.1).
        let suspended = derivation.inferredSegments.filter { $0.kind == .suspended }
        #expect(suspended.count == 1)
        let interval = try #require(suspended.first)
        #expect(interval.startDate == windowStart)
        #expect(interval.endDate == recent.date)
        #expect(interval.unitsDelivered == 0)

        // And no scheduled basal was invented over the suspension.
        #expect(!derivation.inferredSegments.contains { $0.kind == .scheduled && $0.startDate < recent.date })

        let delivered = derivation.insulinDelivered(startDate: windowStart, endDate: at)
        #expect(abs(delivered - 0.3) < 1e-6)
    }

    @Test func aSuspendWithNoResumeIsClosedByTheNextTempBasal() async throws {
        // Assert both halves: the zero units, and that scheduled basal resumes
        // *after* the temp basal rather than before it.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 10.0.daysToSeconds())
        let windowStart = at - 8.0.hoursToSeconds()

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 7.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 6.0.hoursToSeconds())
        let evidence = PumpEventFixtures.tempBasal(
            id: "tb-evidence", start: at - 2.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, suspend, evidence], at: at))

        let derivation = try await derive(store, windowStart: windowStart, at: at)

        let suspended = try #require(derivation.inferredSegments.first { $0.kind == .suspended })
        #expect(suspended.startDate == suspend.date)
        #expect(suspended.endDate == evidence.date)
        #expect(suspended.unitsDelivered == 0)

        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }
        // Two stretches at the scheduled rate: between the anchor's end and the
        // suspend, and after the evidence temp basal up to now. Nothing in between.
        #expect(scheduled.count == 2)
        #expect(scheduled[0].startDate == anchor.dose?.endDate)
        #expect(scheduled[0].endDate == suspend.date)
        #expect(scheduled[1].startDate == evidence.dose?.endDate)
        #expect(scheduled[1].endDate == at)
        #expect(!scheduled.contains { $0.startDate >= suspend.date && $0.startDate < evidence.date })
    }

    // MARK: - Idempotence

    @Test func derivationIsIdempotent() async throws {
        // The property the bug violates. Under the old path each re-derivation
        // reads a thinner history than the last and tells a bigger story about the
        // same interval; here the same window has to give the same answer forever.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())
        let windowStart = at - 6.0.hoursToSeconds()

        var events: [NewPumpEvent] = []
        for index in 0..<12 {
            let start = at - 6.0.hoursToSeconds() + Double(index) * 20.0.minutesToSeconds()
            events.append(PumpEventFixtures.tempBasal(
                id: "tb-\(index)", start: start, duration: 5.0.minutesToSeconds(),
                rateUnitsPerHour: 0.6, deliveredUnits: 0.05
            ))
        }
        _ = try await store.ingest(PumpEventFixtures.batch(events, at: at))
        let first = try await derive(store, windowStart: windowStart, at: at)

        // More events arrive, all of them after the window.
        var later: [NewPumpEvent] = []
        for index in 0..<6 {
            let start = at + Double(index) * 20.0.minutesToSeconds()
            later.append(PumpEventFixtures.tempBasal(
                id: "tb-later-\(index)", start: start, duration: 5.0.minutesToSeconds(),
                rateUnitsPerHour: 0.6, deliveredUnits: 0.05
            ))
        }
        _ = try await store.ingest(PumpEventFixtures.batch(later, at: at + 2.0.hoursToSeconds()))
        let second = try await derive(store, windowStart: windowStart, at: at)

        #expect(first.inferredSegments == second.inferredSegments)
        #expect(first.doses.map { $0.syncIdentifier } == second.doses.map { $0.syncIdentifier })
        #expect(
            abs(first.insulinDelivered(startDate: windowStart, endDate: at)
                - second.insulinDelivered(startDate: windowStart, endDate: at)) < tolerance
        )
    }

    // MARK: - The clamp (I4)

    @Test func theClampHoldsAtTheStoreCreationBoundary() async throws {
        // The migration instant. Before it, history is whatever the old 24-hour
        // log happened to hold, so a gap opening there has unknown content — not
        // zero, and certainly not "the pump ran at its scheduled rate".
        let at = Self.now
        let createdAt = at - 4.0.hoursToSeconds()
        let store = try await makeStore(createdAt: createdAt)

        let before = PumpEventFixtures.tempBasal(
            id: "tb-before", start: at - 10.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let after = PumpEventFixtures.tempBasal(
            id: "tb-after", start: at - 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([before, after], at: at))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)

        // The gap from the older dose's end to the newer one's start begins before
        // the clamp, so it is withheld: nothing is emitted for it at all, which is
        // the difference between "we cannot see this span" and "nothing happened".
        #expect(!derivation.inferredSegments.contains { $0.startDate == before.dose?.endDate })

        // The trailing stretch starts after the clamp, so it is emitted.
        let emitted = derivation.inferredSegments.filter { $0.kind == .scheduled }
        #expect(emitted.count == 1)
        #expect(try #require(emitted.first).startDate == after.dose?.endDate)
    }

    @Test func retentionLeavesNothingBelowTheClampToInferFrom() async throws {
        // The second boundary, and the one that would otherwise re-create the bug
        // at 90 days.
        //
        // In the ordinary case the clamp is belt to retention's braces: retention
        // deletes exactly the rows below the cutoff, and the clamp moves to the
        // same instant, so there is nothing left below it for a gap to open from.
        // Asserting that is asserting the two really do move together — the
        // failure mode being a clamp that lags a prune, which would let one
        // derivation fabricate across the boundary and then never again.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try await makeStore(createdAt: createdAt)

        let old = PumpEventFixtures.tempBasal(
            id: "tb-old", start: createdAt + 1.0.daysToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([old], at: createdAt + 2.0.daysToSeconds()))

        let at = createdAt + 200.0.daysToSeconds()
        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        // The rate seed is ~111 days before the cutoff, far outside
        // `retentionAnchorMaxLookback`, so this is §4.3's unanchored fallback:
        // retention cutting at the nominal cutoff. The anchored path is
        // `anAnchoredPruneLeavesTheLeftEdgeImmediatelyInferable`.
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))
        #expect(result.retention.pruned == 1)
        #expect(!result.retention.isAnchored)

        let clamp = try await store.historyCompleteSince()
        #expect(clamp == at - InsulinRecordStorePolicy.retention)

        let derivation = try await derive(store, windowStart: at - InsulinRecordStorePolicy.retention, at: at)
        // Every emitted segment starts at or after the clamp. Fabricating past it
        // is the regression.
        #expect(derivation.inferredSegments.allSatisfy { $0.startDate >= clamp })
    }

    @Test func anAnchoredPruneLeavesTheLeftEdgeImmediatelyInferable() async throws {
        // The payoff of §4.3, measured in insulin rather than in row counts.
        //
        // Under a wall-clock cut the oldest resume carrying a rate is deleted
        // whenever a newer suspend/resume exists to take the state-marker
        // exemption, so the clamp jumps forward to the first *surviving* rate
        // record. Every dose between the cutoff and that record is then retained
        // and permanently uninferable — real doses whose intervening gaps no
        // gap-fill may span, at a left edge that rolls forward every day.
        //
        // Anchoring keeps that older resume by construction and puts the clamp on
        // it, so the band does not exist. This test builds exactly that
        // configuration and asserts the band's insulin is there.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try await makeStore(createdAt: createdAt, emptyRateHistory: true)
        let at = createdAt + 200.0.daysToSeconds()
        let cutoff = at - InsulinRecordStorePolicy.retention
        let anchorAt = cutoff - 2.0.daysToSeconds()

        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: scheduledRate, at: anchorAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "anchor", at: anchorAt)], at: anchorAt
        ))

        // Two doses with a gap between them, sitting above the cutoff but below
        // the next pod change. This is the band.
        let before = PumpEventFixtures.tempBasal(
            id: "tb-before", start: cutoff + 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.9, deliveredUnits: 0.45
        )
        let after = PumpEventFixtures.tempBasal(
            id: "tb-after", start: cutoff + 5.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.9, deliveredUnits: 0.45
        )
        _ = try await store.ingest(PumpEventFixtures.batch(
            [before, after], at: cutoff + 6.0.hoursToSeconds()
        ))

        // A later pod change, which is what claims the state-marker exemption and
        // so leaves the anchor with nothing but §4.3 keeping it alive.
        let laterResumeAt = cutoff + 10.0.daysToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: scheduledRate, at: laterResumeAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "later", at: laterResumeAt)], at: laterResumeAt
        ))

        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        #expect(result.retention.boundary == anchorAt)
        let clamp = try await store.historyCompleteSince()
        #expect(clamp == anchorAt)
        #expect(clamp < cutoff)

        let derivation = try await derive(store, windowStart: clamp, at: at)

        // The gap inside the band is filled, at the rate the anchor recorded.
        // With the clamp at the first surviving record instead, this stretch is
        // below it and contributes nothing.
        //
        // Note what is *not* asserted: nothing is inferred between the anchor and
        // the first dose after it. A resume is not evidence of delivery and never
        // opens a gap (I3) — the anchor supplies the starting state and the rate,
        // which is precisely the division of labour the original bug collapsed.
        let banded = derivation.inferredSegments.filter {
            $0.kind == .scheduled
                && $0.startDate >= before.dose?.endDate ?? .distantPast
                && $0.endDate <= after.dose?.startDate ?? .distantFuture
        }
        #expect(!banded.isEmpty)
        #expect(banded.allSatisfy { abs($0.rateInUnitsPerHour - scheduledRate) < tolerance })
        #expect(banded.reduce(0) { $0 + $1.unitsDelivered } > 0)
    }

    @Test func theClampSuppressesARowThatOutlivedItsPrune() async throws {
        // What the clamp is actually for at the retention boundary: a row that is
        // below it and was never deleted.
        //
        // Reachable because the clamp is monotonic and retention is not — the
        // cutoff is computed from each batch's own instant, so a batch stamped
        // earlier than the last one prunes less while the clamp stays where it got
        // to. A clock adjustment does this, and so does a queued batch arriving
        // late. Without the clamp, the surviving row would anchor a gap across a
        // span the store has already declared incomplete.
        let at = Self.now
        let createdAt = at - 300.0.daysToSeconds()
        let store = try await makeStore(createdAt: createdAt)

        // First, advance the clamp to `at - 90 days` with an empty batch.
        _ = try await store.ingest(PumpEventFixtures.batch([], at: at))
        let clamp = try await store.historyCompleteSince()
        #expect(clamp == at - InsulinRecordStorePolicy.retention)

        // Then a batch stamped 30 days earlier, whose retention cutoff is lower, so
        // these rows survive even though they sit below the clamp.
        let earlier = at - 30.0.daysToSeconds()
        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 100.0.daysToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let later = PumpEventFixtures.tempBasal(
            id: "tb-later", start: at - 80.0.daysToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, later], at: earlier))
        #expect(try await store.historyCompleteSince() == clamp)

        let derivation = try await derive(store, windowStart: at - 120.0.daysToSeconds(), at: earlier)

        // The gap from the anchor's end to the later dose's start begins below the
        // clamp, so it is withheld rather than filled.
        #expect(!derivation.inferredSegments.contains { $0.startDate == anchor.dose?.endDate })
        #expect(derivation.inferredSegments.allSatisfy { $0.startDate >= clamp })
    }

    // MARK: - The over-fetch (decision 3)

    @Test func overFetchingDoesNotLeak() async throws {
        // The anchor dose has to inform the segment inside the window and never
        // appear as delivery of its own.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())
        let windowStart = at - 2.0.hoursToSeconds()

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 5.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 2.0, deliveredUnits: 1.0
        )
        let inWindow = PumpEventFixtures.tempBasal(
            id: "tb-in", start: at - 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, inWindow], at: at))

        let derivation = try await derive(store, windowStart: windowStart, at: at)

        // The anchor is in the dose list, because it is what bounds the first gap.
        #expect(derivation.doses.count == 2)
        // And it contributes nothing to the window's total: its delivery all
        // happened before the window opened.
        let anchorDose = try #require(derivation.doses.first)
        #expect(abs(anchorDose.insulinDeliveredBetween(startDate: windowStart, endDate: at)) < tolerance)

        // The gap it opens is filled, and its in-window portion is counted.
        let gap = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(gap.startDate == anchor.dose?.endDate)
        #expect(gap.endDate == inWindow.date)
        let gapInWindow = gap.asDoseEntry().insulinDeliveredBetween(startDate: windowStart, endDate: at)
        #expect(gapInWindow > 0)
        #expect(gapInWindow < gap.unitsDelivered)
    }

    @Test func nothingIsInferredWithoutALeftBoundary() async throws {
        // Without a bounding dose there is nothing to infer *from*, and guessing at
        // one is what the retained-marker scheme did.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())
        _ = try await store.ingest(PumpEventFixtures.batch([], at: at))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(derivation.inferredSegments.isEmpty)
        #expect(abs(derivation.insulinOnBoard(at: at)) < tolerance)
    }

    // MARK: - reconciled() (§6.1.1)

    @Test func reconciledTrimsAndRescales() async throws {
        // Assert the total, not just the boundary. Truncating the duration while
        // keeping the units would move insulin earlier in time rather than remove
        // it, which is a redistribution and not a reduction.
        let at = Self.now
        let start = at - 1.0.hoursToSeconds()

        let first = DoseEntry(
            type: .tempBasal, startDate: start, endDate: start + 30.0.minutesToSeconds(),
            value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.5,
            syncIdentifier: "first", insulinType: .lyumjev, isMutable: false
        )
        // Supersedes the first one a third of the way in.
        let second = DoseEntry(
            type: .tempBasal, startDate: start + 10.0.minutesToSeconds(),
            endDate: start + 40.0.minutesToSeconds(),
            value: 2.0, unit: .unitsPerHour, deliveredUnits: 1.0,
            syncIdentifier: "second", insulinType: .lyumjev, isMutable: false
        )

        let reconciled = InsulinRecordTimeline.reconciled([first, second])
        #expect(reconciled.count == 2)

        let trimmed = try #require(reconciled.first)
        #expect(trimmed.endDate == second.startDate)
        // 0.5 U scaled by 10/30.
        #expect(abs(try #require(trimmed.deliveredUnits) - 0.5 / 3.0) < 1e-9)
        // The rate is preserved, so the trimmed dose still describes what the pump
        // was doing while it ran.
        #expect(abs(trimmed.unitsPerHour - 1.0) < tolerance)

        // And the total actually went down by the overlap, which is the `T` term.
        let before = [first, second].map { $0.insulinDeliveredBetween(startDate: start, endDate: at) }.reduce(0, +)
        let after = reconciled.map { $0.insulinDeliveredBetween(startDate: start, endDate: at) }.reduce(0, +)
        #expect(after < before)
        #expect(abs((before - after) - (0.5 - 0.5 / 3.0)) < 1e-6)
    }

    @Test func aDoseSupersededBeforeItBeganIsDropped() async throws {
        let at = Self.now
        let start = at - 1.0.hoursToSeconds()
        let superseded = DoseEntry(
            type: .tempBasal, startDate: start, endDate: start + 30.0.minutesToSeconds(),
            value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.5,
            syncIdentifier: "superseded", insulinType: .lyumjev, isMutable: false
        )
        let replacement = DoseEntry(
            type: .tempBasal, startDate: start, endDate: start + 30.0.minutesToSeconds(),
            value: 2.0, unit: .unitsPerHour, deliveredUnits: 1.0,
            syncIdentifier: "replacement", insulinType: .lyumjev, isMutable: false
        )

        let reconciled = InsulinRecordTimeline.reconciled([superseded, replacement])
        #expect(reconciled.map { $0.syncIdentifier } == ["replacement"])
    }

    @Test func reconciledLeavesNonOverlappingDosesAlone() async throws {
        // The expected case on a real device, if `InsulinTimeline`'s assumption
        // holds: the driver truncates a superseded temp basal's `endDate` before we
        // ever see it, so `reconciled()` is a no-op and `T` is zero.
        let events = ReplayLogs.immutableReplayLogs()
        let at = try #require(events.last?.dose).endDate
        let doses = InsulinTimeline.deduplicatedDoses(events: events, at: at)
            .filter { $0.type == .tempBasal || $0.type == .basal }

        let reconciled = InsulinRecordTimeline.reconciled(doses)
        let before = doses.map { $0.insulinDeliveredBetween(startDate: .distantPast, endDate: at) }.reduce(0, +)
        let after = reconciled.map { $0.insulinDeliveredBetween(startDate: .distantPast, endDate: at) }.reduce(0, +)

        // Recorded from a live device. If this ever fails, GlucOS has been
        // double-counting overlapping basal all along — a second bug, found free.
        #expect(abs(before - after) < 1e-6)
    }

    // MARK: - Quantization (decision 2)

    @Test func inferredSegmentsTruncateToWholePulses() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        // A gap of 37 minutes at 0.4 U/hr is 0.24666… U, which is 4.93 pulses of
        // 0.05 U. A pump cannot deliver 0.93 of a pulse.
        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 1.0.hoursToSeconds() - 37.0.minutesToSeconds(),
            duration: 1.0.hoursToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.6
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor], at: at - 37.0.minutesToSeconds()))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let segment = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(abs(segment.duration - 37.0.minutesToSeconds()) < tolerance)
        #expect(abs(segment.unitsDelivered - 0.20) < 1e-9)

        // Truncation is downward and it really did drop something: `rate × duration`
        // is 0.2466… U, and the pulse the pump cannot deliver is not counted.
        let raw = segment.rateInUnitsPerHour / 60.0 * 37.0
        #expect(abs(raw - 0.4 / 60.0 * 37.0) < 1e-9)
        #expect(segment.unitsDelivered < raw)
    }

    @Test func truncationSurvivesBinaryRepresentation() async throws {
        // 0.3 / 0.05 is 5.999999999999999 in binary. A bare `floor` would quantize
        // an exact six-pulse segment down to five and lose a pulse per segment,
        // every segment.
        #expect(abs(InsulinRecordTimeline.truncateToWholePulses(0.30, pulse: 0.05) - 0.30) < 1e-12)
        #expect(abs(InsulinRecordTimeline.truncateToWholePulses(0.45, pulse: 0.05) - 0.45) < 1e-12)
        #expect(abs(InsulinRecordTimeline.truncateToWholePulses(0.24, pulse: 0.05) - 0.20) < 1e-12)
        #expect(abs(InsulinRecordTimeline.truncateToWholePulses(0.049, pulse: 0.05)) < 1e-12)
        // A pump that reports nothing usable must not make us divide by zero.
        #expect(InsulinRecordTimeline.truncateToWholePulses(0.37, pulse: 0) == 0.37)
    }

    @Test func reportedUnitsWinOverQuantization() async throws {
        // Decision 2 applies to inferred segments. What the pump reported is what
        // the pump reported, whatever a pulse model would predict.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        let odd = PumpEventFixtures.tempBasal(
            id: "tb-odd", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.27
        )
        _ = try await store.ingest(PumpEventFixtures.batch([odd], at: at))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let dose = try #require(derivation.doses.first)
        #expect(dose.deliveredUnits == 0.27)
        #expect(abs(derivation.insulinDelivered(startDate: at - 1.0.hoursToSeconds(), endDate: at) - 0.27) < 1e-9)
    }

    // MARK: - The outage case (§1.2)

    @Test func aCommsOutageStillInfersBecauseTheEventsAreThere() async throws {
        // The one case §1.2 identifies as currently dosing-relevant. The new path
        // fills the gap too — a live pod with a dead phone really does keep running
        // its schedule — but it does so bounded by the *real* events on both sides
        // rather than by a fossil, which is what makes the answer stable.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        let beforeOutage = PumpEventFixtures.tempBasal(
            id: "tb-before", start: at - 40.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([beforeOutage], at: at - 39.0.hoursToSeconds()))

        let afterOutage = PumpEventFixtures.tempBasal(
            id: "tb-after", start: at - 5.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([afterOutage], at: at))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let gap = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(gap.startDate == beforeOutage.dose?.endDate)
        #expect(gap.endDate == afterOutage.date)

        // Deriving again over the same window gives the same answer, which is the
        // property the old path loses the moment trimming runs.
        let again = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(derivation.inferredSegments == again.inferredSegments)
    }

    // MARK: - Suspension evidence below the window (the `inferenceStart` edge)
    //
    // Doses over-fetch to the anchor, so a gap can open before `windowStart`.
    // These pin that suspension evidence reaches equally far back: a completed
    // pair between the anchor's end and the window's start used to be dropped,
    // leaving the gap anchored on the dose end and inference running the
    // scheduled rate across a stretch the pump had been suspended for.

    /// The observed residual, reproduced. A settings change mints a suspend and a
    /// resume a few hundred milliseconds apart; when the comparison window later
    /// swept past them the resume stopped being a boundary, the gap's left edge
    /// fell back to the anchor's end, and the five-minute chunk grid moved with
    /// it — which surfaced as an unexplained 5.3e-5 U in the verifier.
    @Test func aCompletedSuspensionBelowTheWindowStillBoundsTheGap() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())
        let windowStart = at - 2.0.hoursToSeconds()

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 2.0.hoursToSeconds() - 10.0.minutesToSeconds(),
            duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.0, deliveredUnits: 0.0
        )
        let anchorEnd = try #require(anchor.dose?.endDate)
        // Both below `windowStart`, and 481 ms apart — the real spacing.
        let suspend = PumpEventFixtures.suspend(id: "suspend", at: anchorEnd)
        let resume = PumpEventFixtures.resume(id: "resume", at: anchorEnd + 0.481)
        let next = PumpEventFixtures.tempBasal(
            id: "tb-next", start: at - 1.0.hoursToSeconds() - 55.0.minutesToSeconds(),
            duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.0, deliveredUnits: 0.0
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, suspend, resume, next], at: at))

        let derivation = try await derive(store, windowStart: windowStart, at: at)
        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }
        let gap = try #require(scheduled.first)

        // The whole finding in one assertion: the resume, not the anchor's end.
        #expect(gap.startDate == resume.date)
        #expect(gap.startDate != anchorEnd)
        #expect(gap.endDate == next.date)

        // And nothing was invented across the 481 ms the pump was suspended.
        #expect(!scheduled.contains { $0.startDate < resume.date })
        #expect(!derivation.inferredSegments.contains {
            $0.endDate.timeIntervalSince($0.startDate) < InsulinTimeline.minimumInferredSegmentDuration
        })
    }

    @Test func aSuspendBelowTheWindowOpensAtItsOwnInstant() async throws {
        // The other half. A suspension already open when the window arrives used
        // to be clamped to `windowStart`, so `[anchorEnd, windowStart]` was filled
        // at the scheduled rate even though the suspend sat inside it.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())
        let windowStart = at - 2.0.hoursToSeconds()

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 3.0.hoursToSeconds() - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let anchorEnd = try #require(anchor.dose?.endDate)
        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 2.0.hoursToSeconds() - 30.0.minutesToSeconds())
        let next = PumpEventFixtures.tempBasal(
            id: "tb-next", start: at - 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, suspend, next], at: at))

        let derivation = try await derive(store, windowStart: windowStart, at: at)

        // The suspension starts where the pump actually stopped, not at the edge
        // of a window it knows nothing about, and the temp basal closes it.
        let suspended = try #require(derivation.inferredSegments.first { $0.kind == .suspended })
        #expect(suspended.startDate == suspend.date)
        #expect(suspended.startDate != windowStart)
        #expect(suspended.endDate == next.date)
        #expect(suspended.unitsDelivered == 0)

        // The stretch before the suspend is still real scheduled basal: 30 minutes
        // at 0.4 U/hr is 0.2 U, which is a whole number of 0.05 U pulses.
        let scheduled = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(scheduled.startDate == anchorEnd)
        #expect(scheduled.endDate == suspend.date)
        #expect(abs(scheduled.unitsDelivered - 0.2) < tolerance)

        // Nothing scheduled anywhere inside the suspension.
        #expect(!derivation.inferredSegments.contains {
            $0.kind == .scheduled && $0.startDate >= suspend.date && $0.startDate < next.date
        })
    }

    @Test func aTransitionBeforeTheAnchorIsStateAndNothingElse() async throws {
        // The guard on the other side. Reaching back to the anchor must not let an
        // *older* transition become a boundary: the anchor is a dose that ran
        // after it, which is the evidence that outranks it (§6.1.1).
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        let resume = PumpEventFixtures.resume(id: "resume", at: at - 5.0.hoursToSeconds())
        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 4.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let anchorEnd = try #require(anchor.dose?.endDate)
        let next = PumpEventFixtures.tempBasal(
            id: "tb-next", start: at - 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([resume, anchor, next], at: at))

        let derivation = try await derive(store, windowStart: at - 2.0.hoursToSeconds(), at: at)
        let gap = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(gap.startDate == anchorEnd)
        #expect(gap.startDate != resume.date)
        #expect(derivation.inferredSegments.allSatisfy { $0.kind != .suspended })
    }

    @Test func movingTheLeftEdgeOntoTheClampFillsRatherThanSuppresses() async throws {
        // I4 is evaluated on the gap's start, so moving that edge can flip a gap
        // from suppressed to filled. That is the correct direction: the gap really
        // begins at the resume, and the store does vouch for the span from the
        // clamp onward. Pinned because it is the one place this change touches I4.
        let at = Self.now
        let windowStart = at - 2.0.hoursToSeconds()
        let anchorStart = at - 2.0.hoursToSeconds() - 10.0.minutesToSeconds()
        let anchorEnd = anchorStart + 5.0.minutesToSeconds()

        // The clamp sits on the resume: below it for the old left edge, at it for
        // the new one, and `isSuppressed` is a strict `<`.
        let store = try await makeStore(createdAt: anchorEnd + 0.481)

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: anchorStart, duration: 5.0.minutesToSeconds(),
            rateUnitsPerHour: 0.0, deliveredUnits: 0.0
        )
        let suspend = PumpEventFixtures.suspend(id: "suspend", at: anchorEnd)
        let resume = PumpEventFixtures.resume(id: "resume", at: anchorEnd + 0.481)
        let next = PumpEventFixtures.tempBasal(
            id: "tb-next", start: at - 1.0.hoursToSeconds() - 55.0.minutesToSeconds(),
            duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.0, deliveredUnits: 0.0
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, suspend, resume, next], at: at))

        let derivation = try await derive(store, windowStart: windowStart, at: at)
        let gap = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(gap.startDate == resume.date)
    }

    // MARK: - The rate history (dev/backlog/scheduled-basal-history.md §9)

    /// A gap with a temp basal on each side, wide enough to hold a rate change and
    /// still leave both sub-stretches well past `minimumInferredSegmentDuration`.
    private func gapFixture(at: Date) -> (anchor: NewPumpEvent, closer: NewPumpEvent, gapStart: Date, gapEnd: Date) {
        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 8.0.hoursToSeconds(),
            duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.05
        )
        let closer = PumpEventFixtures.tempBasal(
            id: "tb-closer", start: at - 2.0.hoursToSeconds(),
            duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.05
        )
        return (
            anchor,
            closer,
            at - 8.0.hoursToSeconds() + 5.0.minutesToSeconds(),
            at - 2.0.hoursToSeconds()
        )
    }

    @Test func aRateChangeMidGapSplitsItAtTheResumeAndUsesBothRates() async throws {
        // The core of §6: a change subdivides the gap, each sub-stretch carries its
        // own rate, and the boundary is the resume's own date.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds())
        let fixture = gapFixture(at: at)

        // The rate changes to 0.8 U/hr four hours before `at`, inside the gap.
        let changeAt = at - 4.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.8, at: changeAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [fixture.anchor, fixture.closer, PumpEventFixtures.resume(id: "rate-change", at: changeAt)],
            at: at
        ))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }

        // Two stretches inside the gap, plus the trailing one after `closer`.
        let inGap = scheduled.filter { $0.startDate < fixture.gapEnd }
        #expect(inGap.count == 2)
        let first = try #require(inGap.first)
        let second = try #require(inGap.last)

        #expect(first.startDate == fixture.gapStart)
        // Exactly the resume's date, and reached without comparing timestamps: the
        // rate comes off the record that produced the split (§3.1).
        #expect(first.endDate == changeAt)
        #expect(second.startDate == changeAt)
        #expect(second.endDate == fixture.gapEnd)

        #expect(abs(first.rateInUnitsPerHour - scheduledRate) < tolerance)
        #expect(abs(second.rateInUnitsPerHour - 0.8) < tolerance)

        // The trailing stretch runs at the newest rate, which is what keeps the
        // only dosing-relevant segment correct.
        let trailing = try #require(scheduled.last)
        #expect(abs(trailing.rateInUnitsPerHour - 0.8) < tolerance)
    }

    @Test func aReAssertionOfTheSameRateMidGapDoesNotSplitIt() async throws {
        // §5's re-assertion filter, and the regression it guards: a record is
        // written at *every* resume, so most repeat the previous rate. Splitting on
        // a repeat costs a pulse to independent truncation and shifts the
        // five-minute chunk grid, for no boundary that exists.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds())
        let fixture = gapFixture(at: at)

        let reAssertAt = at - 4.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: scheduledRate, at: reAssertAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [fixture.anchor, fixture.closer, PumpEventFixtures.resume(id: "re-assert", at: reAssertAt)],
            at: at
        ))

        // The record exists — this is not a test that nothing was written.
        let diagnostics = try await store.scheduledBasalDiagnostics(at: at)
        #expect(diagnostics.acknowledgedRecordCount == 2)
        // The filter, asserted where it lives: a repeat is not a change.
        #expect(diagnostics.changeCount == 0)

        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(timeline.scheduledBasal.changes(after: fixture.gapStart, before: fixture.gapEnd).isEmpty)

        let derivation = InsulinRecordTimeline.derive(timeline: timeline)
        let inGap = derivation.inferredSegments
            .filter { $0.kind == .scheduled && $0.startDate < fixture.gapEnd }

        // The gap *is* split, and not by the rate record: a resume is delivery
        // evidence — it says the pump started running its schedule — so it is
        // already a boundary in its own right. Both halves therefore carry the same
        // rate, which is the observable content of the filter here.
        #expect(inGap.count == 2)
        #expect(inGap.allSatisfy { abs($0.rateInUnitsPerHour - scheduledRate) < tolerance })

        // And no third split appears inside either half. That is the regression the
        // filter guards: a re-assertion splitting a sub-stretch again would truncate
        // each piece independently and re-anchor the five-minute chunk grid, moving
        // a windowed sum for no reason.
        #expect(inGap.allSatisfy { half in
            timeline.scheduledBasal.changes(after: half.startDate, before: half.endDate).isEmpty
        })
    }

    @Test func aChangeInsideAGapSubdividesItWithoutBecomingABoundary() async throws {
        // §6, tested directly, because the store cannot reach it: a rate record is
        // keyed on a resume, and a resume inside `(inferenceStart, at]` is already a
        // gap boundary — so in practice a change instant never falls *strictly*
        // inside a gap. Subdivision is the belt to that braces, and it is worth
        // having: it is what keeps the rates right if the boundary set ever changes,
        // and it is what §6 forbids doing the other way round, by adding a rate
        // change to `boundaries` and letting a non-delivery event anchor a gap.
        //
        // Built by hand rather than through the store, so the change instant is not
        // also a transition.
        let at = Self.now
        let anchorEnd = at - 6.0.hoursToSeconds()
        let closerStart = at - 2.0.hoursToSeconds()
        let changeAt = at - 4.0.hoursToSeconds()

        let doses = [
            DoseEntry(
                type: .tempBasal, startDate: anchorEnd - 5.0.minutesToSeconds(), endDate: anchorEnd,
                value: 0.6, unit: .unitsPerHour, deliveredUnits: 0.05,
                insulinType: .lyumjev, isMutable: false
            ),
            DoseEntry(
                type: .tempBasal, startDate: closerStart, endDate: closerStart + 5.0.minutesToSeconds(),
                value: 0.6, unit: .unitsPerHour, deliveredUnits: 0.05,
                insulinType: .lyumjev, isMutable: false
            )
        ]

        let history = ScheduledBasalHistory(records: [
            ScheduledBasalRecord(
                resumeSyncIdentifier: "opening", effectiveAt: at - 12.0.hoursToSeconds(),
                rateUnitsPerHour: 0.4, source: .acknowledged, recordedAt: at
            ),
            ScheduledBasalRecord(
                resumeSyncIdentifier: "change", effectiveAt: changeAt,
                rateUnitsPerHour: 0.8, source: .acknowledged, recordedAt: at
            )
        ])

        let timeline = PumpDoseTimeline(
            doses: doses,
            suspensionAtInferenceStart: nil,
            suspensionTransitions: [],
            historyCompleteSince: at - 12.0.hoursToSeconds(),
            lastReconciliation: at,
            windowStart: at - 12.0.hoursToSeconds(),
            inferenceStart: anchorEnd,
            at: at,
            smallestDeliveryUnit: 0.05,
            scheduledBasal: history
        )

        let derivation = InsulinRecordTimeline.derive(timeline: timeline)
        let inGap = derivation.inferredSegments
            .filter { $0.kind == .scheduled && $0.startDate >= anchorEnd && $0.endDate <= closerStart }
        #expect(inGap.count == 2)
        let first = try #require(inGap.first)
        let second = try #require(inGap.last)
        #expect(first.startDate == anchorEnd)
        #expect(first.endDate == changeAt)
        #expect(abs(first.rateInUnitsPerHour - 0.4) < tolerance)
        #expect(second.startDate == changeAt)
        #expect(second.endDate == closerStart)
        #expect(abs(second.rateInUnitsPerHour - 0.8) < tolerance)

        // The change did not become a boundary, so it opened no gap of its own: the
        // two stretches tile the original gap exactly, with nothing before the
        // anchor's end.
        #expect(!derivation.inferredSegments.contains { $0.startDate < anchorEnd })
    }

    @Test func historyPartitionsTheBoundaryWithoutComparingForEquality() async throws {
        // The property the schema was shaped around, asserted on its own. A record at
        // exactly `start` supplies the piece's rate and is *not* also a change inside
        // it, so `record(at:)`'s `<=` and `changes(after:)`'s `>` tile the instant
        // with no gap and no overlap — whatever the floating-point values are.
        let at = Self.now
        let boundary = at - 3.0.hoursToSeconds()
        let history = ScheduledBasalHistory(records: [
            ScheduledBasalRecord(
                resumeSyncIdentifier: "a", effectiveAt: at - 6.0.hoursToSeconds(),
                rateUnitsPerHour: 0.4, source: .acknowledged, recordedAt: at
            ),
            ScheduledBasalRecord(
                resumeSyncIdentifier: "b", effectiveAt: boundary,
                rateUnitsPerHour: 0.8, source: .acknowledged, recordedAt: at
            ),
            // A re-assertion of 0.8, which must never count as a change.
            ScheduledBasalRecord(
                resumeSyncIdentifier: "c", effectiveAt: at - 1.0.hoursToSeconds(),
                rateUnitsPerHour: 0.8, source: .acknowledged, recordedAt: at
            )
        ])

        #expect(history.rate(at: boundary) == 0.8)
        #expect(history.rate(at: boundary - 1) == 0.4)
        // Not a change inside a piece that begins at it.
        #expect(history.changes(after: boundary, before: at).isEmpty)
        // But it is a change inside a piece that begins before it.
        #expect(history.changes(after: boundary - 1, before: at).map { $0.resumeSyncIdentifier } == ["b"])
        #expect(history.changeCount == 1)

        // Nothing before the first record, which is what the clamp exists to prevent
        // the derivation from ever needing.
        #expect(history.rate(at: at - 7.0.hoursToSeconds()) == nil)
    }

    @Test func aDeviceThatNeverChangesItsRatePricesEverythingAtThatRate() async throws {
        // §9's first gate. On a device whose rate never changes, a record lands at
        // every resume and none of them is a boundary — so the rate history is
        // invisible in the output, and every inferred segment carries the one rate.
        //
        // This was originally an equality against `derive` with the old scalar
        // parameter. That parameter existed only so the parallel run could measure
        // the difference, and with it gone the property has to be stated directly.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds())
        let fixture = gapFixture(at: at)

        // Several re-assertions, which is the realistic state: a record per resume.
        var events = [fixture.anchor, fixture.closer]
        for (index, offset) in [6.0, 5.0, 3.0].enumerated() {
            let when = at - offset.hoursToSeconds()
            try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: scheduledRate, at: when)
            events.append(PumpEventFixtures.resume(id: "re-assert-\(index)", at: when))
        }
        _ = try await store.ingest(PumpEventFixtures.batch(events, at: at))

        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at)

        // Four records — the backfill-free store's own, one per resume — and not one
        // of them is a change.
        #expect(try await store.scheduledBasalDiagnostics(at: at).changeCount == 0)
        #expect(timeline.scheduledBasal.changes(after: at - 12.0.hoursToSeconds(), before: at).isEmpty)

        let derivation = InsulinRecordTimeline.derive(timeline: timeline)
        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }
        #expect(!scheduled.isEmpty)
        #expect(scheduled.allSatisfy { abs($0.rateInUnitsPerHour - scheduledRate) < tolerance })
    }

    @Test func aRateChangeInsideASuspensionAddsUnitsToNeitherSide() async throws {
        // A suspension is evidence of zero delivery, and subdivision happens *after*
        // the suspension subtraction — so a change landing inside one has nothing to
        // price.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds())

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 8.0.hoursToSeconds(),
            duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.05
        )
        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 6.0.hoursToSeconds())
        // The resume that ends the suspension is also the one that changes the rate,
        // so the change instant is the suspension's right edge.
        let resumeAt = at - 3.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.9, at: resumeAt)
        let resume = PumpEventFixtures.resume(id: "resume", at: resumeAt)
        _ = try await store.ingest(PumpEventFixtures.batch([anchor, suspend, resume], at: at))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)

        let suspended = derivation.inferredSegments.filter { $0.kind == .suspended }
        #expect(suspended.count == 1)
        #expect(try #require(suspended.first).unitsDelivered == 0)

        // Nothing scheduled overlaps the suspension.
        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }
        #expect(!scheduled.contains { $0.startDate < resumeAt && $0.endDate > suspend.date })

        // §9's "change coinciding with a resume": the stretch beginning at the
        // resume runs at the new rate.
        let afterResume = try #require(scheduled.first { $0.startDate == resumeAt })
        #expect(abs(afterResume.rateInUnitsPerHour - 0.9) < tolerance)
    }

    @Test func anEmptyRateHistoryInfersNothingAtAll() async throws {
        // §7.2, and the edge case dropping the genesis record makes load-bearing.
        // The natural implementation gets this backwards — coalesce the missing
        // clamp term to nil, let `max` fall through to `createdAt`, and inference
        // runs across a span with no rate at all.
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds(), emptyRateHistory: true)
        let fixture = gapFixture(at: at)
        let result = try await store.ingest(
            PumpEventFixtures.batch([fixture.anchor, fixture.closer], at: at)
        )

        // The clamp reads "we cannot trust ourselves before now", which is a refusal
        // rather than a wrong number.
        #expect(result.historyCompleteSince == at)

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(derivation.inferredSegments.filter { $0.kind == .scheduled }.isEmpty)

        // The reported doses are untouched: refusing to infer is not refusing to
        // count what the pump told us.
        let delivered = derivation.insulinDelivered(startDate: at - 12.0.hoursToSeconds(), endDate: at)
        #expect(abs(delivered - 0.1) < 1e-6)
    }

    // MARK: - What the parallel run measured, and phase 3 stops measuring
    //
    // Six runs of dual-derivation verification are being deleted along with the
    // JSON path. Most of what they established is pinned elsewhere in this file
    // already — decision 2 by `inferredSegmentsTruncateToWholePulses`, the fossil
    // by `theFabricationCannotBeConstructed`, `T` by the `reconciled()` tests.
    // These are the cases that were *only* ever covered by a verifier term, or
    // that six runs never reached at all. Provenance for each is in
    // dev/interpreting_verification_results.md.

    /// `P`'s dosing-relevant case, which no run ever reached: "delivery gaps
    /// longer than 24.0h: 0" was the last `[warn]` still standing after 7.1 days,
    /// and once the verifier is gone nothing measures it on a device.
    ///
    /// **The clamp does not cover this, and that is the point of the test.** I4
    /// withholds a gap whose left edge falls below `historyCompleteSince`, which is
    /// what kills the 40-hour fossil — but a live outage's gap has a perfectly real
    /// left edge, the last dose the pump reported. So it is filled, at the
    /// scheduled rate, with no upper bound: `derive` appends `(lastBoundary.end,
    /// at)` unconditionally, and `minimumInferredSegmentDuration` is a floor rather
    /// than a cap.
    ///
    /// And unlike the finalized fossil — always ≥24 h old, therefore outside DIA,
    /// which is why stateful-issue.md judged its blast radius small — this segment
    /// **ends at `at`**, so the part inside the action duration counts toward IOB
    /// and is directly dosing-relevant. That was stateful-issue.md's open question,
    /// left as "worth confirming deliberately rather than by inspection". This is
    /// the confirmation: the phantom is real, it is bounded only by how long the
    /// pump stays quiet, and the defence against it lives entirely outside this
    /// file (the `updatedAt` staleness check).
    @Test func anOutageStillOpenAtNowInfersUnboundedScheduledBasal() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        // The last thing the pump ever said, 40 hours ago, and nothing since — no
        // suspend, no resume, no later temp basal to close the gap on the right.
        // A comms outage, which is the shape the interpretation doc keeps
        // distinguishing from a suspension.
        let lastReport = PumpEventFixtures.tempBasal(
            id: "tb-before-outage", start: at - 40.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(
            PumpEventFixtures.batch([lastReport], at: at - 39.5.hoursToSeconds())
        )

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }
        #expect(scheduled.count == 1)

        let trailing = try #require(scheduled.first)
        #expect(trailing.startDate == lastReport.dose?.endDate)
        #expect(trailing.endDate == at)
        #expect(abs(trailing.duration - 39.5.hoursToSeconds()) < tolerance)
        #expect(abs(trailing.rateInUnitsPerHour - scheduledRate) < tolerance)

        // 39.5 h at 0.4 U/hr is 15.8 U, which is exactly 316 pulses — no
        // truncation to hide behind. Nothing caps this: double the outage and the
        // number doubles.
        #expect(abs(trailing.unitsDelivered - 15.8) < 1e-9)

        // Inside DIA, which is what makes it dosing-relevant rather than merely
        // wrong. The exact figure is insulin-model dependent; the assertion is that
        // it is units rather than rounding.
        #expect(derivation.insulinOnBoard(at: at) > 0.5)
    }

    /// The contrast, and why the interpretation doc insists a suspension is not
    /// `P`'s case: a suspend is evidence, and evidence of zero.
    ///
    /// This is run 6's tail exactly — the export ends on a temp basal running to
    /// 20:45:46 and a suspend at 20:45:46, one second before the final ingest, with
    /// the pod being deactivated. Same outage as above, one extra event, and the
    /// phantom is gone. Note the suspend is *coincident* with the temp basal's end,
    /// so it arrives through `suspensionAtInferenceStart` rather than as a
    /// transition, which is the path a stale open suspend takes.
    @Test func anOutageBehindASuspendInfersNothingAtAll() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 60.0.daysToSeconds())

        let lastReport = PumpEventFixtures.tempBasal(
            id: "tb-before-outage", start: at - 40.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let suspend = PumpEventFixtures.suspend(
            id: "suspend-deactivation", at: at - 39.5.hoursToSeconds()
        )
        _ = try await store.ingest(
            PumpEventFixtures.batch([lastReport, suspend], at: at - 39.5.hoursToSeconds())
        )

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)

        // Nothing scheduled: the whole outage is covered by a suspension, and
        // `subtracting` removes it from the gap entirely.
        #expect(derivation.inferredSegments.filter { $0.kind == .scheduled }.isEmpty)

        let suspended = try #require(derivation.inferredSegments.first { $0.kind == .suspended })
        #expect(suspended.startDate == at - 39.5.hoursToSeconds())
        #expect(suspended.endDate == at)
        #expect(suspended.unitsDelivered == 0)

        // The reported dose still counts, and nothing is on board 39 hours later.
        let delivered = derivation.insulinDelivered(
            startDate: at - 41.0.hoursToSeconds(), endDate: at
        )
        #expect(abs(delivered - 0.3) < 1e-6)
        #expect(derivation.insulinOnBoard(at: at) < tolerance)
    }

    /// Run 6's `Q`, which came out at 100% of the inferred amount rather than the
    /// ~6% §4 of @dev/pump_db_verification.md predicts.
    ///
    /// A settings change mints a short gap, and a gap short enough delivers less
    /// than one pulse — so truncation takes all of it and the segment contributes
    /// exactly nothing. The device numbers, reproduced: 241.7 s at 0.45 U/hr is
    /// 0.0302 U against a 0.05 U pulse.
    ///
    /// Worth pinning because it is a *systematic* under-count — every settings
    /// change loses its gap — and because the term that made it visible is the one
    /// being deleted.
    @Test func anInferredSegmentBelowOnePulseDeliversNothing() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds(), rate: 0.45)

        let gapSeconds = 242.0
        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 1.0.hoursToSeconds() - gapSeconds,
            duration: 1.0.hoursToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.6
        )
        _ = try await store.ingest(PumpEventFixtures.batch([anchor], at: at - gapSeconds))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let segment = try #require(derivation.inferredSegments.first { $0.kind == .scheduled })
        #expect(abs(segment.duration - gapSeconds) < tolerance)

        // The whole segment truncates away.
        #expect(segment.unitsDelivered == 0)

        // But the segment is still emitted, carrying its rate, so what was lost is
        // recoverable from it: `rate × duration` is under one pulse.
        let raw = segment.rateInUnitsPerHour / 3600.0 * gapSeconds
        #expect(abs(raw - 0.45 / 3600.0 * gapSeconds) < 1e-12)
        #expect(raw < 0.05)

        // So nothing from the gap reaches the sums: only the reported dose.
        let delivered = derivation.insulinDelivered(
            startDate: at - 2.0.hoursToSeconds(), endDate: at
        )
        #expect(abs(delivered - 0.6) < 1e-9)
    }

    /// Run 6's other finding: a real rate change that left `S` at exactly zero.
    ///
    /// The geometry is the reason. `S` measured inferred basal priced at today's
    /// rate against its historical rate, and the only gap in the window opened *at
    /// the resume that acknowledged the change* — so historical and current were
    /// the same number and the correction was zero by construction.
    /// `record(at:)`'s `<=` supplies the new rate to a piece beginning at the
    /// record and `changes(after:)`'s `>` keeps it from also splitting that piece;
    /// `historyPartitionsTheBoundaryWithoutComparingForEquality` pins that on the
    /// history alone, and this pins the derivation actually getting it.
    ///
    /// The sub-second suspend/resume pair is the device shape too: run 1 found two
    /// of four completed pairs were sub-second and minted by settings changes.
    @Test func aGapOpeningAtTheAcknowledgingResumeRunsEntirelyAtTheNewRate() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds(), rate: 0.5)

        // 0.5 -> 0.45, acknowledged by a resume half a second after its suspend.
        let changeAt = at - 40.0.minutesToSeconds()
        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: changeAt - 60.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.45, at: changeAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [
                anchor,
                PumpEventFixtures.suspend(id: "settings-suspend", at: changeAt - 0.5),
                PumpEventFixtures.resume(id: "settings-resume", at: changeAt)
            ],
            at: at
        ))

        let derivation = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        let scheduled = derivation.inferredSegments.filter { $0.kind == .scheduled }

        // Two stretches: the pre-change gap at the old rate, and the post-change
        // one at the new. The half-second pair is below
        // `minimumInferredSegmentDuration`, so it emits neither a suspension nor a
        // gap of its own.
        #expect(scheduled.count == 2)
        #expect(derivation.inferredSegments.filter { $0.kind == .suspended }.isEmpty)

        let before = try #require(scheduled.first)
        #expect(before.startDate == anchor.dose?.endDate)
        #expect(before.endDate == changeAt - 0.5)
        #expect(abs(before.rateInUnitsPerHour - 0.5) < tolerance)

        // The one that matters: undivided, from the resume to now, entirely at the
        // rate that resume acknowledged.
        let after = try #require(scheduled.last)
        #expect(after.startDate == changeAt)
        #expect(after.endDate == at)
        #expect(abs(after.rateInUnitsPerHour - 0.45) < tolerance)

        // 40 min at 0.45 U/hr is 0.30 U — exactly six pulses, so no truncation
        // noise in the number.
        #expect(abs(after.unitsDelivered - 0.30) < 1e-9)
    }

    /// The `R` term's arithmetic, kept after the term is gone.
    ///
    /// §4 of @dev/pump_db_verification.md makes the point that `R` is a
    /// counterfactual rather than a sum of revoked units: revoking a dose does not
    /// merely subtract its units, it opens a gap that inference then fills at the
    /// scheduled rate. Six runs produced zero revocations — run 3 established that
    /// is structurally expected on this driver rather than a miss — so this is the
    /// only place the property is checked at all.
    @Test func revokingAMutableDoseOpensAGapInferenceThenRefills() async throws {
        let at = Self.now
        let store = try await makeStore(createdAt: at - 30.0.daysToSeconds())

        let settled = PumpEventFixtures.tempBasal(
            id: "tb-settled", start: at - 2.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        // 1.2 U/hr for 30 minutes is 0.6 U, and still mutable.
        let orphan = PumpEventFixtures.tempBasal(
            id: "tb-orphan", start: at - 90.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 1.2,
            deliveredUnits: 0.6, isMutable: true
        )
        _ = try await store.ingest(
            PumpEventFixtures.batch([settled, orphan], at: at - 60.0.minutesToSeconds())
        )

        // The driver stops mentioning it. See
        // `anEmptyAssertionRevokesEveryLiveMutableRow` for the one driver path that
        // reaches this.
        let result = try await store.ingest(
            PumpEventFixtures.batch([], at: at - 55.0.minutesToSeconds())
        )
        #expect(result.revoked.map { $0.syncIdentifier } == [PumpEventFixtures.identifier(of: orphan)])

        let spanStart = at - 90.0.minutesToSeconds()
        let live = try await derive(store, windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(!live.doses.contains { $0.syncIdentifier == PumpEventFixtures.identifier(of: orphan) })

        // 90 minutes of gap at 0.4 U/hr is 0.60 U — exactly 12 pulses.
        #expect(abs(live.insulinDelivered(startDate: spanStart, endDate: at) - 0.60) < 1e-9)

        // The counterfactual the term was: with the revoked row restored, the same
        // span carries the orphan's 0.6 U plus only the 60 minutes after it at the
        // scheduled rate.
        let restored = InsulinRecordTimeline.derive(
            timeline: try await store.timeline(
                windowStart: at - 12.0.hoursToSeconds(), at: at, includeRevoked: true
            )
        )
        #expect(abs(restored.insulinDelivered(startDate: spanStart, endDate: at) - 1.0) < 1e-9)

        // So `R` here is 0.40 U, not the 0.60 U that was revoked. Summing the
        // revoked units alone would leave 0.20 U unexplained, which is exactly the
        // mistake the term's definition warns about.
        let r = restored.insulinDelivered(startDate: spanStart, endDate: at)
            - live.insulinDelivered(startDate: spanStart, endDate: at)
        #expect(abs(r - 0.40) < 1e-9)
    }
}
