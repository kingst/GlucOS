//
//  InsulinRecordStoreTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/3/26.
//
//  Phase 0 of dev/backlog/insulin-storage-grdb.md. The store, unwired: schema,
//  migrations, ingest semantics, and the state queries.
//
//  The valuable tests here assert about *time*, which the JSON log cannot
//  express — see §10. Everything runs against an in-memory `DatabaseQueue`, so
//  no test touches a file system.
//

import Testing
import Foundation
import GRDB
import LoopKit
@testable import BioKernel

// MARK: - Fixtures

/// Builders for `NewPumpEvent`.
///
/// `NewPumpEvent.init` overwrites `dose.syncIdentifier` with
/// `raw.hexadecimalString`, so `raw` is what actually controls a dose's identity.
/// Every builder here derives it from `id` for exactly that reason — passing a
/// `syncIdentifier` and hoping would silently give every fixture a different one.
enum PumpEventFixtures {
    static func tempBasal(
        id: String,
        start: Date,
        duration: TimeInterval,
        rateUnitsPerHour: Double,
        deliveredUnits: Double? = nil,
        isMutable: Bool = false,
        automatic: Bool = true,
        insulinType: InsulinType = .lyumjev
    ) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .tempBasal,
            startDate: start,
            endDate: start + duration,
            value: rateUnitsPerHour,
            unit: .unitsPerHour,
            deliveredUnits: deliveredUnits,
            insulinType: insulinType,
            automatic: automatic,
            isMutable: isMutable
        )
        return NewPumpEvent(date: start, dose: dose, raw: Data(id.utf8), title: id, type: .tempBasal)
    }

    static func bolus(
        id: String,
        start: Date,
        duration: TimeInterval = 60,
        units: Double,
        deliveredUnits: Double? = nil,
        isMutable: Bool = false,
        insulinType: InsulinType = .lyumjev
    ) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .bolus,
            startDate: start,
            endDate: start + duration,
            value: units,
            unit: .units,
            deliveredUnits: deliveredUnits,
            insulinType: insulinType,
            automatic: false,
            isMutable: isMutable
        )
        return NewPumpEvent(date: start, dose: dose, raw: Data(id.utf8), title: id, type: .bolus)
    }

    static func suspend(id: String, at: Date) -> NewPumpEvent {
        let dose = DoseEntry(suspendDate: at)
        return NewPumpEvent(date: at, dose: dose, raw: Data(id.utf8), title: id, type: .suspend)
    }

    static func resume(id: String, at: Date, insulinType: InsulinType = .lyumjev) -> NewPumpEvent {
        let dose = DoseEntry(resumeDate: at, insulinType: insulinType)
        return NewPumpEvent(date: at, dose: dose, raw: Data(id.utf8), title: id, type: .resume)
    }

    static func alarm(id: String, at: Date, alarmType: PumpAlarmType = .occlusion) -> NewPumpEvent {
        return NewPumpEvent(date: at, dose: nil, raw: Data(id.utf8), title: id, type: .alarm, alarmType: alarmType)
    }

    static func alarmClear(id: String, at: Date) -> NewPumpEvent {
        return NewPumpEvent(date: at, dose: nil, raw: Data(id.utf8), title: id, type: .alarmClear)
    }

    /// The identity the store will key a fixture on, without having to reproduce
    /// the hex encoding at every assertion site.
    static func identifier(of event: NewPumpEvent) -> String {
        let kind: PumpEventKind = {
            if let type = event.type { return PumpEventKind(type) }
            if let doseType = event.dose?.type { return PumpEventKind(doseType) }
            return .unknown
        }()
        return PumpEventRecord.syncIdentifier(for: event, kind: kind)
    }

    static func batch(
        _ events: [NewPumpEvent],
        at: Date,
        replacePendingEvents: Bool = true,
        lastReconciliation: Date? = nil
    ) -> PumpEventBatch {
        return PumpEventBatch(
            events: events,
            lastReconciliation: lastReconciliation ?? at,
            replacePendingEvents: replacePendingEvents,
            pump: .lyumjevOnOmnipod,
            at: at
        )
    }
}

// MARK: - Tests

struct InsulinRecordStoreTests {
    /// A fixed instant, because `Date()` in a test that asserts about time is a
    /// test that fails on a slow machine.
    static let now = Date(timeIntervalSince1970: 1_770_000_000)
    let tolerance = 1e-9

    private func makeStore(createdAt: Date) throws -> GRDBInsulinRecordStore {
        return try GRDBInsulinRecordStore(inMemoryCreatedAt: createdAt)
    }

    // MARK: - Schema and migrations

    @Test func migratesAndSeedsTheSingleton() async throws {
        let createdAt = Self.now - 1.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)

        // I4's left edge starts at the store's creation instant: before that,
        // history is whatever the old 24-hour log happened to hold.
        #expect(try await store.historyCompleteSince() == createdAt)
        #expect(try await store.lastReconciliation() == nil)
        #expect(try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true).isEmpty)
    }

    @Test func reopeningKeepsTheOriginalCreationInstant() async throws {
        // The real store passes `Date()` on every launch. `INSERT OR IGNORE` is
        // what keeps that from marching I4's left edge forward once per launch,
        // which would silently re-clamp the whole history.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pump_events.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let createdAt = Self.now - 10.0.daysToSeconds()
        let first = try GRDBInsulinRecordStore(url: url, createdAt: createdAt, backfillRateUnitsPerHour: 0.4)
        #expect(try await first.historyCompleteSince() == createdAt)

        let second = try GRDBInsulinRecordStore(url: url, createdAt: Self.now, backfillRateUnitsPerHour: 0.4)
        #expect(try await second.historyCompleteSince() == createdAt)
    }

    @Test func anUnopenableDatabaseIsLoud() async throws {
        // §8: a database that cannot be opened is a dosing outage, not a silent
        // empty log. Stricter than the JSON path, where a failed read yields
        // `eventLog = []` and an IOB of 0.
        let url = URL(fileURLWithPath: "/dev/null/not-a-directory/pump_events.sqlite")
        #expect(throws: InsulinRecordStoreError.self) {
            _ = try GRDBInsulinRecordStore(url: url, createdAt: Self.now, backfillRateUnitsPerHour: 0.4)
        }
    }

    // MARK: - Recorded logs (§7.1)

    @Test func ingestsTheRecordedReplayLogs() async throws {
        let events = ReplayLogs.immutableReplayLogs()
        let lastDose = try #require(events.last?.dose)
        let at = lastDose.endDate

        let store = try makeStore(createdAt: at - 30.0.daysToSeconds())
        let result = try await store.ingest(PumpEventFixtures.batch(events, at: at))

        // The primary key is the dedup mechanism, so the row count is the number
        // of distinct identifiers rather than the number of events.
        let distinctIdentifiers = Set(events.map { PumpEventFixtures.identifier(of: $0) })
        #expect(result.upserted.count == distinctIdentifiers.count)
        #expect(result.syntheticDoseIdentifiers.isEmpty)

        let rows = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
        #expect(rows.count == distinctIdentifiers.count)
        #expect(rows.allSatisfy { $0.deletedAt == nil })
    }

    @Test func reIngestingTheSameBatchIsIdempotent() async throws {
        // §8's redelivery contract. A failed transaction gets re-delivered, and
        // upsert-by-identifier is what makes that harmless.
        let events = ReplayLogs.immutableReplayLogs()
        let at = try #require(events.last?.dose).endDate
        let store = try makeStore(createdAt: at - 30.0.daysToSeconds())

        _ = try await store.ingest(PumpEventFixtures.batch(events, at: at))
        let first = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
        _ = try await store.ingest(PumpEventFixtures.batch(events, at: at))
        let second = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)

        #expect(first == second)
    }

    // MARK: - I2: the dose lifecycle

    @Test func animmutableReportOverwritesTheMutableRow() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())
        let start = at - 20.0.minutesToSeconds()

        let mutable = PumpEventFixtures.tempBasal(
            id: "tb-1", start: start, duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 1.2, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([mutable], at: at))

        let finalized = PumpEventFixtures.tempBasal(
            id: "tb-1", start: start, duration: 20.0.minutesToSeconds(),
            rateUnitsPerHour: 1.2, deliveredUnits: 0.4, isMutable: false
        )
        _ = try await store.ingest(PumpEventFixtures.batch([finalized], at: at + 60))

        let rows = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.isMutable == false)
        #expect(row.deliveredUnits == 0.4)
        // `recordedAt` is when we *first* saw the dose. The gap between it and
        // `date` is how late a dose arrived, and re-reporting must not reset it.
        #expect(row.recordedAt == at)
    }

    @Test func aMutableReportCannotUnDoAnImmutableOne() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())
        let start = at - 20.0.minutesToSeconds()

        let finalized = PumpEventFixtures.tempBasal(
            id: "tb-1", start: start, duration: 20.0.minutesToSeconds(),
            rateUnitsPerHour: 1.2, deliveredUnits: 0.4, isMutable: false
        )
        _ = try await store.ingest(PumpEventFixtures.batch([finalized], at: at))

        let stale = PumpEventFixtures.tempBasal(
            id: "tb-1", start: start, duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 1.2, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([stale], at: at + 60))

        let row = try #require(try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true).first)
        #expect(row.isMutable == false)
        #expect(row.deliveredUnits == 0.4)
        #expect(row.doseEnd == start + 20.0.minutesToSeconds())
    }

    @Test func oneBatchCarryingBothRevisionsKeepsTheImmutableOne() async throws {
        // What `removeStaleMutableDoses` was reconstructing on every read. Here
        // it is a fold, and the primary key does the rest.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())
        let start = at - 20.0.minutesToSeconds()

        let mutable = PumpEventFixtures.tempBasal(
            id: "tb-1", start: start, duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 1.2, isMutable: true
        )
        let finalized = PumpEventFixtures.tempBasal(
            id: "tb-1", start: start, duration: 20.0.minutesToSeconds(),
            rateUnitsPerHour: 1.2, deliveredUnits: 0.4, isMutable: false
        )

        // Both orders have to give the same surviving row, because the driver's
        // batch order is not ours to rely on.
        for events in [[mutable, finalized], [finalized, mutable]] {
            let store = try makeStore(createdAt: at - 1.0.daysToSeconds())
            let result = try await store.ingest(PumpEventFixtures.batch(events, at: at))
            #expect(result.upserted.count == 1)
            let row = try #require(result.upserted.first)
            #expect(row.isMutable == false)
            #expect(row.deliveredUnits == 0.4)
        }
        _ = store
    }

    // MARK: - replacePendingEvents (§5.1)

    @Test func aFalseCallRevokesNothing() async throws {
        // The pod-change pseudo-event passes false and asserts nothing about
        // pending doses. A store that treats the purge as always-on deletes every
        // in-flight dose the moment a pod change fires.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let inFlight = PumpEventFixtures.tempBasal(
            id: "tb-live", start: at - 5.0.minutesToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.8, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([inFlight], at: at))

        let podChange = NewPumpEvent(
            date: at + 60, dose: nil, raw: Data("pod-change".utf8), title: "pod change",
            type: .replaceComponent(componentType: .pump)
        )
        let result = try await store.ingest(
            PumpEventFixtures.batch([podChange], at: at + 60, replacePendingEvents: false)
        )

        #expect(result.revoked.isEmpty)
        let live = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: false)
        #expect(live.contains { $0.syncIdentifier == PumpEventFixtures.identifier(of: inFlight) })
    }

    @Test func aTrueCallRevokesOnlyUnassertedMutableRows() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let orphan = PumpEventFixtures.tempBasal(
            id: "tb-orphan", start: at - 90.0.minutesToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.8, isMutable: true
        )
        let settled = PumpEventFixtures.tempBasal(
            id: "tb-settled", start: at - 40.0.minutesToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.9, deliveredUnits: 0.45, isMutable: false
        )
        _ = try await store.ingest(PumpEventFixtures.batch([orphan, settled], at: at))

        let current = PumpEventFixtures.tempBasal(
            id: "tb-current", start: at, duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 1.0, isMutable: true
        )
        let result = try await store.ingest(PumpEventFixtures.batch([current], at: at + 60))

        // Only the unasserted *mutable* row. The immutable one is untouchable —
        // I2 says once immutable it never changes, and that includes vanishing.
        #expect(result.revoked.map { $0.syncIdentifier } == [PumpEventFixtures.identifier(of: orphan)])

        let live = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: false)
        let liveIdentifiers = Set(live.map { $0.syncIdentifier })
        #expect(!liveIdentifiers.contains(PumpEventFixtures.identifier(of: orphan)))
        #expect(liveIdentifiers.contains(PumpEventFixtures.identifier(of: settled)))
        #expect(liveIdentifiers.contains(PumpEventFixtures.identifier(of: current)))
    }

    @Test func revocationIsASoftDelete() async throws {
        // §4.1. Not bookkeeping fastidiousness: a `DELETE` makes a row's
        // disappearance indistinguishable from its never having existed, and the
        // verifier's `R` term would have to be inferred from the residual it is
        // supposed to explain.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let orphan = PumpEventFixtures.tempBasal(
            id: "tb-orphan", start: at - 90.0.minutesToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.8, deliveredUnits: 0.4, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([orphan], at: at))

        let current = PumpEventFixtures.tempBasal(
            id: "tb-current", start: at, duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 1.0, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([current], at: at + 60))

        let all = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
        let revoked = try #require(all.first { $0.syncIdentifier == PumpEventFixtures.identifier(of: orphan) })
        #expect(revoked.deletedAt == at + 60)
        // Still summable, which is what makes `R` a query.
        #expect(revoked.deliveredUnits == 0.4)

        // And invisible to every ordinary read.
        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at + 60)
        #expect(!timeline.doses.contains { $0.syncIdentifier == PumpEventFixtures.identifier(of: orphan) })
    }

    @Test func aRevokedIdTheDriverReAssertsComesBackIntact() async throws {
        // Decision 9's stop-ship, from the store's side. The row has to survive
        // the round trip; whether the revocation was *right* is what the verifier
        // records as a reappearance.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let dose = PumpEventFixtures.tempBasal(
            id: "tb-1", start: at - 90.0.minutesToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.8, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([dose], at: at))
        let originalRecordedAt = try #require(
            try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true).first
        ).recordedAt

        // A batch that does not assert it revokes it.
        let other = PumpEventFixtures.tempBasal(
            id: "tb-other", start: at, duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 1.0, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([other], at: at + 60))

        // Then the driver asserts it again.
        let result = try await store.ingest(PumpEventFixtures.batch([dose, other], at: at + 120))
        #expect(result.reassertedAfterRevocation == [PumpEventFixtures.identifier(of: dose)])

        let revived = try #require(
            try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: false)
                .first { $0.syncIdentifier == PumpEventFixtures.identifier(of: dose) }
        )
        #expect(revived.deletedAt == nil)
        #expect(revived.recordedAt == originalRecordedAt)
    }

    // MARK: - I3: state queries see past the window, timeline queries do not

    @Test func aThreeWeekOldResumeInformsStateAndNothingElse() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        let resume = PumpEventFixtures.resume(id: "resume", at: at - 21.0.daysToSeconds())
        let recent = PumpEventFixtures.tempBasal(
            id: "tb-1", start: at - 30.0.minutesToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([resume, recent], at: at))

        // The state answer looks back three weeks, as it must: OmnipodKit mints
        // suspend/resume only for explicit commands, so a three-week-old resume
        // is the only thing that says the pump is running.
        #expect(try await store.isSuspended(at: at) == false)

        // The timeline does not. This is the fix: the resume is not an element of
        // the array gap-filling walks, so it cannot become a delivery boundary.
        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at)
        // The transition is available as state, with its instant, and it is not
        // an element of the dose array.
        #expect(timeline.suspensionAtInferenceStart?.isSuspended == false)
        #expect(timeline.suspensionAtInferenceStart?.at == resume.date)
        #expect(timeline.suspensionTransitions.isEmpty)
        #expect(!timeline.doses.contains { $0.type == .resume || $0.type == .suspend })
    }

    @Test func aThreeWeekOldSuspendMakesTheWindowStartSuspended() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 21.0.daysToSeconds())
        _ = try await store.ingest(PumpEventFixtures.batch([suspend], at: at))

        #expect(try await store.isSuspended(at: at) == true)
        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(timeline.suspensionAtInferenceStart?.isSuspended == true)
    }

    @Test func suspensionTransitionsInsideTheWindowAreEvidence() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 3.0.hoursToSeconds())
        let resume = PumpEventFixtures.resume(id: "resume", at: at - 2.0.hoursToSeconds())
        _ = try await store.ingest(PumpEventFixtures.batch([suspend, resume], at: at))

        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at)
        #expect(timeline.suspensionAtInferenceStart == nil)
        #expect(timeline.suspensionTransitions.map { $0.isSuspended } == [true, false])
        #expect(timeline.suspensionTransitions.map { $0.at } == [suspend.date, resume.date])
    }

    @Test func transitionsReachBackToTheAnchorsEnd() async throws {
        // Suspension evidence spans exactly what dose evidence spans. The
        // over-fetch puts the first gap's left edge at the anchor's end, so a
        // transition between there and `windowStart` is inside that gap and has
        // to travel with it; bounding transitions at `windowStart` dropped it.
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        let anchor = PumpEventFixtures.tempBasal(
            id: "tb-anchor", start: at - 3.0.hoursToSeconds() - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        let anchorEnd = try #require(anchor.dose?.endDate)
        // Below `windowStart`, above the anchor's end: the stretch that used to
        // have doses but no suspensions.
        let suspend = PumpEventFixtures.suspend(id: "suspend", at: at - 2.0.hoursToSeconds() - 30.0.minutesToSeconds())
        let resume = PumpEventFixtures.resume(id: "resume", at: at - 2.0.hoursToSeconds() - 20.0.minutesToSeconds())
        // Older than the anchor, so it stays state rather than becoming evidence.
        let stale = PumpEventFixtures.resume(id: "stale", at: at - 21.0.daysToSeconds())
        _ = try await store.ingest(PumpEventFixtures.batch([stale, anchor, suspend, resume], at: at))

        let timeline = try await store.timeline(windowStart: at - 2.0.hoursToSeconds(), at: at)

        #expect(timeline.inferenceStart == anchorEnd)
        #expect(timeline.inferenceStart < timeline.windowStart)
        #expect(timeline.suspensionTransitions.map { $0.at } == [suspend.date, resume.date])
        // The one before the anchor is answered by the state query instead, so
        // every transition is covered exactly once: `<=` there, `>` here.
        #expect(timeline.suspensionAtInferenceStart?.at == stale.date)
        #expect(timeline.suspensionAtInferenceStart?.isSuspended == false)
    }

    @Test func inferenceStartFallsBackToTheWindowWithNoAnchor() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        // Overlaps the window, so it is fetched as a dose but never as the anchor.
        let inside = PumpEventFixtures.tempBasal(
            id: "tb-inside", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.3
        )
        _ = try await store.ingest(PumpEventFixtures.batch([inside], at: at))

        let windowStart = at - 2.0.hoursToSeconds()
        let timeline = try await store.timeline(windowStart: windowStart, at: at)
        #expect(timeline.inferenceStart == windowStart)
    }

    // MARK: - The other state queries (§6.3)

    @Test func alarmStateIsItsOwnQuery() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        let alarm = PumpEventFixtures.alarm(id: "alarm", at: at - 10.0.daysToSeconds(), alarmType: .occlusion)
        _ = try await store.ingest(PumpEventFixtures.batch([alarm], at: at))
        #expect(try await store.pumpAlarm(at: at) == .occlusion)

        let cleared = PumpEventFixtures.alarmClear(id: "clear", at: at - 9.0.daysToSeconds())
        _ = try await store.ingest(PumpEventFixtures.batch([cleared], at: at))
        #expect(try await store.pumpAlarm(at: at) == nil)

        // And it is answerable as of an earlier instant, because it is a query
        // over history rather than a running variable.
        #expect(try await store.pumpAlarm(at: at - 9.5.daysToSeconds()) == .occlusion)
    }

    @Test func alarmsGetSyntheticIdentifiers() async throws {
        // Alarms carry no `syncIdentifier`, so the primary key has to come from
        // somewhere. Stable across re-ingest is the whole requirement.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())
        let alarm = PumpEventFixtures.alarm(id: "alarm", at: at - 1.0.hoursToSeconds())

        _ = try await store.ingest(PumpEventFixtures.batch([alarm], at: at))
        _ = try await store.ingest(PumpEventFixtures.batch([alarm], at: at + 60))

        let rows = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
        #expect(rows.count == 1)
        #expect(PumpEventRecord.isSynthetic(syncIdentifier: try #require(rows.first).syncIdentifier))
    }

    @Test func insulinTypeIsTheNewestOneWeHold() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 60.0.daysToSeconds())

        let older = PumpEventFixtures.tempBasal(
            id: "tb-old", start: at - 20.0.daysToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.5, deliveredUnits: 0.25, insulinType: .humalog
        )
        let newer = PumpEventFixtures.tempBasal(
            id: "tb-new", start: at - 1.0.hoursToSeconds(), duration: 30.0.minutesToSeconds(),
            rateUnitsPerHour: 0.5, deliveredUnits: 0.25, insulinType: .lyumjev
        )
        _ = try await store.ingest(PumpEventFixtures.batch([older, newer], at: at))

        #expect(try await store.currentInsulinType(at: at) == .lyumjev)
        // Per row, not global: people change insulins across a history, and the
        // answer as of a past instant is the insulin that was in the pod then.
        #expect(try await store.currentInsulinType(at: at - 10.0.daysToSeconds()) == .humalog)
    }

    @Test func activeBolusOverlapsTheInstant() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let running = PumpEventFixtures.bolus(
            id: "bolus-running", start: at - 30, duration: 120, units: 2.0, isMutable: true
        )
        let finished = PumpEventFixtures.bolus(
            id: "bolus-done", start: at - 600, duration: 120, units: 1.0, deliveredUnits: 1.0
        )
        _ = try await store.ingest(PumpEventFixtures.batch([running, finished], at: at))

        let active = try #require(try await store.activeBolus(at: at))
        #expect(active.syncIdentifier == PumpEventFixtures.identifier(of: running))
        #expect(try await store.activeBolus(at: at + 600) == nil)
    }

    @Test func lastReconciliationRoundTrips() async throws {
        // I5's right edge, which `LocalInsulinStorage` currently stores and
        // explicitly ignores. Recorded and honored as preparation, not as a fix
        // (decision 12) — no consumer needs settled history today.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())
        let reconciliation = at - 5.0.minutesToSeconds()

        let inFlight = PumpEventFixtures.bolus(
            id: "bolus", start: at - 30, duration: 120, units: 2.0, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch(
            [inFlight], at: at, lastReconciliation: reconciliation
        ))

        #expect(try await store.lastReconciliation() == reconciliation)

        // A dose after it is still held, still read, and still counted — an
        // in-flight bolus must not be invisible.
        let timeline = try await store.timeline(windowStart: at - 12.0.hoursToSeconds(), at: at + 600)
        #expect(timeline.lastReconciliation == reconciliation)
        #expect(timeline.doses.contains { $0.type == .bolus })
    }

    // MARK: - Range reads

    @Test func doseRangeReadsTestOverlapNotStart() async throws {
        // A temp basal can begin before a window and deliver inside it. Filtering
        // on `dose_start` alone drops it, which under-reports insulin — the worst
        // direction to fail in.
        let at = Self.now
        let store = try makeStore(createdAt: at - 10.0.daysToSeconds())
        let windowStart = at - 1.0.hoursToSeconds()

        let straddling = PumpEventFixtures.tempBasal(
            id: "tb-straddle", start: windowStart - 10.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 1.0, deliveredUnits: 0.5
        )
        _ = try await store.ingest(PumpEventFixtures.batch([straddling], at: at))

        let timeline = try await store.timeline(windowStart: windowStart, at: at)
        #expect(timeline.doses.contains { $0.syncIdentifier == PumpEventFixtures.identifier(of: straddling) })
    }

    @Test func theOverFetchedAnchorIsBoundedByTheDataNotByAFixedDuration() async throws {
        // Decision 3. LoopKit caps its equivalent look-back at a flat 24 hours,
        // which silently truncates the case the over-fetch exists to handle: a pod
        // that ran unattended for far longer.
        let at = Self.now
        let store = try makeStore(createdAt: at - 90.0.daysToSeconds())
        let windowStart = at - 12.0.hoursToSeconds()

        let ancient = PumpEventFixtures.tempBasal(
            id: "tb-ancient", start: at - 40.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 1.0, deliveredUnits: 0.5
        )
        _ = try await store.ingest(PumpEventFixtures.batch([ancient], at: at))

        let timeline = try await store.timeline(windowStart: windowStart, at: at)
        #expect(timeline.doses.map { $0.syncIdentifier } == [PumpEventFixtures.identifier(of: ancient)])
    }

    @Test func recordsCanIncludeOrExcludeRevokedRows() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let orphan = PumpEventFixtures.tempBasal(
            id: "tb-orphan", start: at - 90.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.8, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([orphan], at: at))
        let other = PumpEventFixtures.tempBasal(
            id: "tb-other", start: at, duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 1.0, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([other], at: at + 60))

        let live = try await store.records(from: at - 1.0.daysToSeconds(), to: at + 60, includeRevoked: false)
        let all = try await store.records(from: at - 1.0.daysToSeconds(), to: at + 60, includeRevoked: true)
        #expect(live.count == 1)
        #expect(all.count == 2)
    }

    // MARK: - Retention and the clamp

    @Test func retentionPrunesAndAdvancesTheClamp() async throws {
        let createdAt = Self.now - 200.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)

        // A rate record at `createdAt`, so the clamp's scheduled-basal term is not
        // the thing being measured here. Without one the store has no rate history
        // at all and the clamp correctly reads "everything is incomplete"
        // (scheduled-basal-history §7.2) — which is a real behavior, tested
        // separately in `anEmptyRateHistoryClampsEverything`, and not what this
        // test is about. The seed resume survives retention as the newest
        // suspend/resume marker, so the term settles on `createdAt` and the
        // retention cutoff is what moves the clamp.
        //
        // The seed sits 60 days before the cutoff, far outside
        // `retentionAnchorMaxLookback`, so this is deliberately the **unanchored
        // fallback** of §4.3 — retention cutting at the nominal cutoff, which is
        // what the store did everywhere before anchoring existed. The anchored
        // path is `retentionAnchorsTheBoundaryOnAResume`.
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.4, at: createdAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "rate-seed", at: createdAt)],
            at: createdAt
        ))

        let old = PumpEventFixtures.tempBasal(
            id: "tb-old", start: createdAt + 1.0.daysToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch([old], at: createdAt + 2.0.daysToSeconds()))
        #expect(try await store.historyCompleteSince() == createdAt)

        // Now ingest well past the retention horizon.
        let at = createdAt + 150.0.daysToSeconds()
        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        #expect(result.retention.pruned == 1)
        #expect(!result.retention.isAnchored)
        // Pruning re-creates exactly the boundary that caused the bug, so the
        // clamp has to move with it (§4.2).
        #expect(try await store.historyCompleteSince() == at - InsulinRecordStorePolicy.retention)
    }

    @Test func retentionAnchorsTheBoundaryOnAResume() async throws {
        // §4.3, and the reason the store keeps more than 90 days: cutting at the
        // wall clock leaves the oldest rate record later than the oldest event,
        // and the clamp has to sit at the record — stranding every row in between
        // as retained-yet-uninferable. Cutting at the resume collapses the
        // deletion boundary, the first rate record, and the clamp onto one
        // instant.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)
        let at = createdAt + 200.0.daysToSeconds()
        let cutoff = at - InsulinRecordStorePolicy.retention

        // A pod change three days before the cutoff — the anchor. Well inside
        // `retentionAnchorMaxLookback`, and the sort of interval a real device
        // produces, since a pod cannot run past `Pod.serviceDuration`.
        let anchorAt = cutoff - 3.0.daysToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.4, at: anchorAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "anchor", at: anchorAt)], at: anchorAt
        ))

        // One dose before the anchor, which must go, and one between the anchor
        // and the cutoff, which must stay — that one is the whole point.
        let beforeAnchor = PumpEventFixtures.tempBasal(
            id: "tb-before", start: anchorAt - 2.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let insideTail = PumpEventFixtures.tempBasal(
            id: "tb-tail", start: anchorAt + 6.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch(
            [beforeAnchor, insideTail], at: anchorAt + 7.0.hoursToSeconds()
        ))

        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        #expect(result.retention.anchorSyncIdentifier
                == PumpEventFixtures.identifier(of: PumpEventFixtures.resume(id: "anchor", at: anchorAt)))
        #expect(result.retention.boundary == anchorAt)
        #expect(result.retention.pruned == 1)

        let survivors = Set(
            try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
                .map { $0.syncIdentifier }
        )
        #expect(!survivors.contains(PumpEventFixtures.identifier(of: beforeAnchor)))
        #expect(survivors.contains(PumpEventFixtures.identifier(of: insideTail)))

        // The clamp lands on the anchor, not on the nominal cutoff. Landing on
        // the cutoff is the silent regression: every row is still present, and
        // three days of them are simply never inferable again.
        #expect(try await store.historyCompleteSince() == anchorAt)
        #expect(try await store.historyCompleteSince() < cutoff)
    }

    @Test func retentionKeepsMoreThanNinetyDaysSoNinetyAreAnswerable() async throws {
        // The trade the anchor makes, stated as a test: the store deliberately
        // holds *more* than the retention window. Paying up to a pod cycle of
        // extra rows is what buys a left edge with no uninferable band behind it.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)
        let at = createdAt + 200.0.daysToSeconds()
        let cutoff = at - InsulinRecordStorePolicy.retention

        let anchorAt = cutoff - 3.0.daysToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.4, at: anchorAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "anchor", at: anchorAt)], at: anchorAt
        ))

        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        let retained = at.timeIntervalSince(result.retention.boundary)
        #expect(retained > InsulinRecordStorePolicy.retention)
        #expect(retained <= InsulinRecordStorePolicy.retention + InsulinRecordStorePolicy.retentionAnchorMaxLookback)
    }

    @Test func nothingSurvivesRetentionBelowTheClamp() async throws {
        // I6 as a property rather than as an example: after an anchored prune no
        // *dose* row is older than the clamp, so there is no retained history the
        // store refuses to infer across. State markers are exempt by design — I3
        // keeps them out of the array gap-filling walks — so they are excluded
        // here for the same reason they are safe there.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)
        let at = createdAt + 200.0.daysToSeconds()
        let cutoff = at - InsulinRecordStorePolicy.retention

        // Two pod changes straddling the cutoff, so the newer of the two that is
        // still at or before the cutoff is the one that must win.
        for (index, offset) in [-9.0, -2.0].enumerated() {
            let resumeAt = cutoff + offset.daysToSeconds()
            try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.4, at: resumeAt)
            _ = try await store.ingest(PumpEventFixtures.batch(
                [PumpEventFixtures.resume(id: "resume-\(index)", at: resumeAt)], at: resumeAt
            ))
            let dose = PumpEventFixtures.tempBasal(
                id: "tb-\(index)", start: resumeAt + 1.0.hoursToSeconds(),
                duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
            )
            _ = try await store.ingest(PumpEventFixtures.batch([dose], at: resumeAt + 2.0.hoursToSeconds()))
        }

        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))
        #expect(result.retention.boundary == cutoff - 2.0.daysToSeconds())

        let clamp = try await store.historyCompleteSince()
        let doses = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
            .filter { $0.doseStart != nil }
        #expect(!doses.isEmpty)
        #expect(doses.allSatisfy { $0.date >= clamp })
    }

    @Test func aResumeWithNoRateRecordCannotAnchorRetention() async throws {
        // The anchor has to carry a rate, not merely a state. A resume with no
        // record answers "the pod was running" and not "at what rate", which is
        // the same uninferable band by another route — so it must not be treated
        // as a valid left edge.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)
        let at = createdAt + 200.0.daysToSeconds()
        let cutoff = at - InsulinRecordStorePolicy.retention

        // A resume three days before the cutoff, with no program enqueued for it.
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "rateless", at: cutoff - 3.0.daysToSeconds())],
            at: cutoff - 3.0.daysToSeconds()
        ))

        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        #expect(!result.retention.isAnchored)
        #expect(result.retention.boundary == cutoff)
    }

    @Test func anAnchorBeyondTheLookbackIsRefusedRatherThanGrowingTheStore() async throws {
        // The backstop. Anchoring makes retention a function of driver behavior
        // rather than of time alone, and scheduled-basal-history §2.1 is a
        // correction admitting that behavior was got wrong once already. If
        // resumes stop arriving, the file must stop growing — losing a pod cycle
        // of inferable history is a far better failure than storage exhaustion on
        // a device that doses insulin.
        let createdAt = Self.now - 400.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)
        let at = createdAt + 300.0.daysToSeconds()
        let cutoff = at - InsulinRecordStorePolicy.retention

        // A resume one day past the lookback floor, so it is a valid rate record
        // and still not reachable as an anchor.
        let tooOld = cutoff - InsulinRecordStorePolicy.retentionAnchorMaxLookback - 1.0.daysToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.4, at: tooOld)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "too-old", at: tooOld)], at: tooOld
        ))

        let stranded = PumpEventFixtures.tempBasal(
            id: "tb-stranded", start: tooOld + 1.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch([stranded], at: tooOld + 2.0.hoursToSeconds()))

        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        let result = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        #expect(!result.retention.isAnchored)
        #expect(result.retention.boundary == cutoff)
        #expect(result.retention.pruned > 0)

        // And the dose below the cutoff really is gone, rather than retained
        // forever waiting for an anchor that is never coming.
        let survivors = Set(
            try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
                .map { $0.syncIdentifier }
        )
        #expect(!survivors.contains(PumpEventFixtures.identifier(of: stranded)))
    }

    @Test func retentionKeepsTheNewestSuspensionAndAlarmMarkers() async throws {
        // The one legitimate residue of `getMostRecentStatefulOldEvents`. A state
        // answer has to stay available past the deletion boundary, and that is
        // safe now for the reason it was not before: I3 keeps these rows out of
        // the array gap-filling walks, so a retained marker informs the starting
        // state without becoming a delivery boundary.
        let createdAt = Self.now - 300.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)

        let suspend = PumpEventFixtures.suspend(id: "suspend", at: createdAt + 1.0.daysToSeconds())
        let alarm = PumpEventFixtures.alarm(id: "alarm", at: createdAt + 1.0.daysToSeconds())
        let ordinary = PumpEventFixtures.tempBasal(
            id: "tb-old", start: createdAt + 1.0.daysToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch(
            [suspend, alarm, ordinary], at: createdAt + 2.0.daysToSeconds()
        ))

        let at = createdAt + 200.0.daysToSeconds()
        let recent = PumpEventFixtures.tempBasal(
            id: "tb-recent", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch([recent], at: at))

        let survivors = Set(
            try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true)
                .map { $0.syncIdentifier }
        )
        #expect(survivors.contains(PumpEventFixtures.identifier(of: suspend)))
        #expect(survivors.contains(PumpEventFixtures.identifier(of: alarm)))
        #expect(!survivors.contains(PumpEventFixtures.identifier(of: ordinary)))

        // And the state answer they exist for still works.
        #expect(try await store.isSuspended(at: at) == true)
        #expect(try await store.pumpAlarm(at: at) == .occlusion)
    }

    @Test func theClampNeverMovesBackwards() async throws {
        // Monotonicity is load-bearing: if this could move backwards a clamp would
        // re-open a span it has already refused to fill, and the first derivation
        // after it moved would fabricate exactly once and then never again.
        let createdAt = Self.now - 200.0.daysToSeconds()
        let store = try makeStore(createdAt: createdAt)

        let at = createdAt + 150.0.daysToSeconds()
        let event = PumpEventFixtures.tempBasal(
            id: "tb-1", start: at - 30.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch([event], at: at))
        let advanced = try await store.historyCompleteSince()

        // A batch stamped with an earlier instant — a clock adjustment, or a
        // queued batch arriving late.
        let earlier = PumpEventFixtures.tempBasal(
            id: "tb-2", start: at - 2.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.5, deliveredUnits: 0.25
        )
        _ = try await store.ingest(PumpEventFixtures.batch([earlier], at: at - 1.0.hoursToSeconds()))

        #expect(try await store.historyCompleteSince() == advanced)
    }

    // MARK: - Staleness (§5.3)

    @Test func aLongLivedMutableDoseIsReportedAsStale() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let stale = PumpEventFixtures.tempBasal(
            id: "tb-stale", start: at - 6.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.8, deliveredUnits: 0.4, isMutable: true
        )
        let fresh = PumpEventFixtures.tempBasal(
            id: "tb-fresh", start: at - 5.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.8, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch(
            [stale, fresh], at: at, replacePendingEvents: false
        ))

        let reported = try await store.staleMutableDoses(at: at)
        #expect(reported.map { $0.syncIdentifier } == [PumpEventFixtures.identifier(of: stale)])
        let dose = try #require(reported.first)
        #expect(abs(dose.age - 6.0.hoursToSeconds()) < tolerance)
        // The log says how much is at stake, not merely that something is stale.
        #expect(abs(dose.units - 0.4) < tolerance)
    }

    @Test func aRevokedDoseIsNoLongerStale() async throws {
        // Revocation is what `replacePendingEvents` exists to do about an orphan,
        // so the diagnostic has to stop firing once it has been done.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let orphan = PumpEventFixtures.tempBasal(
            id: "tb-orphan", start: at - 6.0.hoursToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.8, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([orphan], at: at, replacePendingEvents: false))
        #expect(try await store.staleMutableDoses(at: at).count == 1)

        let other = PumpEventFixtures.tempBasal(
            id: "tb-other", start: at, duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 1.0, isMutable: true
        )
        _ = try await store.ingest(PumpEventFixtures.batch([other], at: at + 60))
        #expect(try await store.staleMutableDoses(at: at + 60).isEmpty)
    }

    // MARK: - Unfinished suspend (§6.2)

    @Test func anOpenEndedSuspendIsExtendedAtReadTimeNotStored() async throws {
        // Storing an open-ended suspension would make a row's meaning depend on
        // when it is read, which is the mistake this whole design is about.
        let at = Self.now
        let store = try makeStore(createdAt: at - 10.0.daysToSeconds())
        let suspendAt = at - 2.0.hoursToSeconds()

        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.suspend(id: "suspend", at: suspendAt)], at: at
        ))

        let row = try #require(
            try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: true).first
        )
        #expect(row.doseStart == suspendAt)
        #expect(row.doseEnd == suspendAt)

        let extended = try #require(row.doseEntry(suspensionEndingAt: at))
        #expect(extended.startDate == suspendAt)
        #expect(extended.endDate == at)
        #expect(extended.programmedUnits == 0)
    }

    // MARK: - Scheduled basal (dev/backlog/scheduled-basal-history.md §9)

    private func history(_ store: GRDBInsulinRecordStore, at: Date) async throws -> ScheduledBasalHistory {
        return try await store.timeline(windowStart: .distantPast, at: at).scheduledBasal
    }

    @Test func aProgramIsClaimedByTheResumeThatAcknowledgesIt() async throws {
        // The happy path, and the one that makes `effective_at` exact by
        // construction: the record's instant *is* the resume's date, because it is
        // read by joining to that row rather than copied into a column.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let resumeAt = at - 1.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.55, at: resumeAt)
        let resume = PumpEventFixtures.resume(id: "resume", at: resumeAt)
        let result = try await store.ingest(PumpEventFixtures.batch([resume], at: at))

        #expect(result.scheduledBasal.minted.count == 1)
        let minted = try #require(result.scheduledBasal.minted.first)
        #expect(minted.resumeSyncIdentifier == PumpEventFixtures.identifier(of: resume))
        #expect(minted.effectiveAt == resumeAt)
        #expect(minted.rateUnitsPerHour == 0.55)
        #expect(minted.source == .acknowledged)
        #expect(result.scheduledBasal.unresolvedResumeSyncIdentifiers.isEmpty)

        let record = try #require(await history(store, at: at).record(at: at))
        #expect(record.effectiveAt == resumeAt)
        #expect(record.rateUnitsPerHour == 0.55)
    }

    @Test func aFailedProgramWritesNoRecordAndIsAbandoned() async throws {
        // §1.1's case, which is the whole reason the queue exists. An earlier design
        // inserted a rate record at the app's clock on acknowledgment and kept
        // serving lookups from it when it went unlinked — so a program the pod never
        // took would silently govern the rate from an instant at which the pod was
        // suspended. It must reach no lookup at all.
        //
        // Also §9's "success with no active pod": `syncBasalRateSchedule` reports
        // success without programming anything when no pod is active, so an enqueued
        // program with no resume behind it is a real state, not a hypothetical.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let requestedAt = at - 2.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.9, at: requestedAt)

        // No resume ever arrives. An unrelated dose drives the next reconciliation.
        let result = try await store.ingest(PumpEventFixtures.batch([
            PumpEventFixtures.tempBasal(
                id: "tb", start: at - 10.0.minutesToSeconds(),
                duration: 5.0.minutesToSeconds(), rateUnitsPerHour: 0.6, deliveredUnits: 0.05
            )
        ], at: at))

        #expect(result.scheduledBasal.minted.isEmpty)
        #expect(result.scheduledBasal.abandonedPrograms == 1)
        #expect(try await history(store, at: at).records.isEmpty)

        let diagnostics = try await store.scheduledBasalDiagnostics(at: at)
        #expect(diagnostics.abandonedProgramCount == 1)
        #expect(diagnostics.pendingProgramCount == 0)
        #expect(diagnostics.acknowledgedRecordCount == 0)
    }

    @Test func anAbandonedProgramIsNotClaimedByAnUnrelatedLaterResume() async throws {
        // What the tolerance window is *for*, now that it no longer reconciles a
        // timestamp: without it, a program that failed on the pod would sit in the
        // queue until the user's next manual suspend/resume, and that unrelated
        // resume would record a rate the pod never ran.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        // A failed program, well outside the window.
        let failedAt = at - 6.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.9, at: failedAt)

        // Establish a known rate, then a much later unrelated resume.
        let establishedAt = at - 5.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.3, at: establishedAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "established", at: establishedAt)],
            at: establishedAt + 1.0
        ))

        let unrelatedAt = at - 1.0.hoursToSeconds()
        let result = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "unrelated", at: unrelatedAt)],
            at: at
        ))

        // The unrelated resume re-asserts 0.3, not the 0.9 that never took.
        let minted = try #require(result.scheduledBasal.minted.first)
        #expect(minted.rateUnitsPerHour == 0.3)
        #expect(try await store.scheduledBasalDiagnostics(at: at).abandonedProgramCount == 1)
    }

    @Test func aBareResumeReAssertsThePreviousRate() async throws {
        // §3.3, derived rather than stored. `resumeBasal` re-programs the schedule
        // already on the pod, so a resume with no program behind it is an
        // observation of the same rate — which is what makes every record an
        // observation instead of an extrapolation.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let firstAt = at - 5.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.45, at: firstAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "first", at: firstAt)], at: firstAt + 1.0
        ))

        let bareAt = at - 2.0.hoursToSeconds()
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.suspend(id: "suspend", at: at - 3.0.hoursToSeconds()),
             PumpEventFixtures.resume(id: "bare", at: bareAt)],
            at: at
        ))

        let records = try await history(store, at: at).records
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.rateUnitsPerHour == 0.45 })
        // Two records, zero changes — which is what keeps the gap unsplit (§5).
        #expect(try await store.scheduledBasalDiagnostics(at: at).changeCount == 0)
    }

    @Test func aResumeYoungerThanTheWindowWaitsForItsProgram() async throws {
        // The ordering race, and why re-assertion is deferred rather than immediate.
        // `OmniPumpManager` reports the resume on its own cadence, so a program can
        // be seconds behind the resume in wall time and a whole loop period behind it
        // in arrival time. Falling back to the previous rate straight away would mint
        // a record we could no longer correct, because the primary key is taken.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let firstAt = at - 5.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.45, at: firstAt)
        _ = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "first", at: firstAt)], at: firstAt + 1.0
        ))

        // The resume arrives first, before its program.
        let changeAt = at - 30.0
        let result = try await store.ingest(PumpEventFixtures.batch(
            [PumpEventFixtures.resume(id: "change", at: changeAt)], at: at
        ))
        #expect(result.scheduledBasal.minted.isEmpty)
        #expect(try await history(store, at: at).records.count == 1)

        // Then the program lands, and enqueueing reconciles.
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.75, at: at)
        let records = try await history(store, at: at).records
        #expect(records.count == 2)
        #expect(try #require(records.last).rateUnitsPerHour == 0.75)
        #expect(try #require(records.last).effectiveAt == changeAt)
    }

    @Test func aRevokedResumeTakesItsRecordWithIt() async throws {
        // §3.1: a revoked resume means the program did not stick, so the record
        // should stop being history. Keyed on `sync_identifier`, which is stable
        // across the mutable-to-immutable transition, this is a withdrawal path a
        // timestamp-keyed table could not express at all.
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let resumeAt = at - 1.0.hoursToSeconds()
        try await store.enqueueScheduledBasalProgram(rateUnitsPerHour: 0.65, at: resumeAt)
        // A *mutable* resume, so `replacePendingEvents` can revoke it.
        let dose = DoseEntry(resumeDate: resumeAt, insulinType: .lyumjev, isMutable: true)
        let resume = NewPumpEvent(date: resumeAt, dose: dose, raw: Data("resume".utf8), title: "resume", type: .resume)
        _ = try await store.ingest(PumpEventFixtures.batch([resume], at: resumeAt + 1.0))
        #expect(try await history(store, at: at).records.count == 1)

        // A later batch that does not assert it revokes it.
        _ = try await store.ingest(PumpEventFixtures.batch([], at: at))
        #expect(try await history(store, at: at).records.isEmpty)
    }

    @Test func theBackfillIsANoOpWithoutExistingResumes() async throws {
        // §4.2. The migration selects existing resume rows, so a fresh install
        // inserts nothing regardless of which rate was captured — which is what makes
        // it safe as a permanent migration needing no flag and no version guard.
        let at = Self.now
        let store = try GRDBInsulinRecordStore(inMemoryCreatedAt: at - 1.0.daysToSeconds(), backfillRateUnitsPerHour: 0.37)
        let diagnostics = try await store.scheduledBasalDiagnostics(at: at)
        #expect(diagnostics.backfilledRecordCount == 0)
        #expect(diagnostics.acknowledgedRecordCount == 0)
    }

    @Test func theBackfillStampsEveryExistingResume() async throws {
        // The development device's case: four days of events already in the store,
        // eight resumes, and no `scheduled_basal` table. Without the backfill those
        // days go non-inferable until the next pod change (§7).
        //
        // Exercised through a file-backed store reopened after the rows exist, which
        // is the only way to reach the migration with a populated `pump_event`.
        let at = Self.now
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("pump_events.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let createdAt = at - 4.0.daysToSeconds()
        let first = try GRDBInsulinRecordStore(url: url, createdAt: createdAt, backfillRateUnitsPerHour: 0.4)
        _ = try await first.ingest(PumpEventFixtures.batch([
            PumpEventFixtures.resume(id: "pod-1", at: at - 3.0.daysToSeconds()),
            PumpEventFixtures.resume(id: "pod-2", at: at - 1.0.daysToSeconds())
        ], at: at))

        // Both resumes are unresolved on the first store: no programs, no prior
        // record to re-assert from.
        #expect(try await first.scheduledBasalDiagnostics(at: at).acknowledgedRecordCount == 0)

        // Reach the migration with a populated `pump_event`, which is the situation
        // the development device is actually in. Reopening alone will not re-run a
        // migration already recorded as applied, so unwind it here — from the test's
        // own connection, rather than by adding a table-dropping seam to the store.
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "DROP TABLE scheduled_basal")
            try db.execute(sql: "DROP TABLE scheduled_basal_program")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-scheduled-basal'")
        }

        let second = try GRDBInsulinRecordStore(url: url, createdAt: at, backfillRateUnitsPerHour: 0.42)
        let diagnostics = try await second.scheduledBasalDiagnostics(at: at)
        #expect(diagnostics.backfilledRecordCount == 2)
        #expect(diagnostics.acknowledgedRecordCount == 0)
        // Every backfilled row carries the same rate, so the re-assertion filter
        // makes the backfill invisible to derivation — which is what keeps the
        // phase 1 residual clean across the backfilled span (§8).
        #expect(diagnostics.changeCount == 0)

        let records = try await second.timeline(windowStart: .distantPast, at: at).scheduledBasal.records
        #expect(records.allSatisfy { $0.rateUnitsPerHour == 0.42 && $0.source == .backfilled })
    }

    // MARK: - The orphan condition (the one driver path that reaches it)

    /// Run 3 read all nine callers of `OmniPumpManager.store(doses:)` and found
    /// eight re-assert every unfinalized dose by construction, with pod changes
    /// finalizing before they report. The ninth — the pod prime at
    /// `OmniPumpManager.swift:1205` — passes `state.unstoredDoses`, a retry buffer
    /// that is empty in the normal case. So it sends `[]` with
    /// `replacePendingEvents: true`, and the store reads that as "I have no pending
    /// doses".
    ///
    /// Six runs produced zero revocations, which run 3 established is the expected
    /// result rather than a miss — so this has never been observed on a device and
    /// now never will be. Its failure mode is under-counted IOB, and therefore
    /// over-delivery, which is the direction that matters. Note there is no
    /// empty-batch guard: emptiness is not what makes it safe, the flag is.
    @Test func anEmptyAssertionRevokesEveryLiveMutableRow() async throws {
        let at = Self.now
        let store = try makeStore(createdAt: at - 1.0.daysToSeconds())

        let mutableBasal = PumpEventFixtures.tempBasal(
            id: "tb-in-flight", start: at - 20.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.8, isMutable: true
        )
        let mutableBolus = PumpEventFixtures.bolus(
            id: "bolus-in-flight", start: at - 30, units: 2.0, isMutable: true
        )
        let settled = PumpEventFixtures.tempBasal(
            id: "tb-settled", start: at - 90.0.minutesToSeconds(),
            duration: 30.0.minutesToSeconds(), rateUnitsPerHour: 0.9, deliveredUnits: 0.45
        )
        _ = try await store.ingest(
            PumpEventFixtures.batch([settled, mutableBasal, mutableBolus], at: at)
        )

        // The pod prime, with nothing in the retry buffer.
        let result = try await store.ingest(PumpEventFixtures.batch([], at: at + 60))

        #expect(Set(result.revoked.map { $0.syncIdentifier }) == Set([
            PumpEventFixtures.identifier(of: mutableBasal),
            PumpEventFixtures.identifier(of: mutableBolus)
        ]))

        // The immutable row is untouchable (I2), and that includes vanishing.
        let live = try await store.records(from: .distantPast, to: .distantFuture, includeRevoked: false)
        #expect(live.map { $0.syncIdentifier } == [PumpEventFixtures.identifier(of: settled)])

        // The same call with the flag false revokes nothing, which is what makes
        // the flag rather than the emptiness the thing doing the work.
        let other = try makeStore(createdAt: at - 1.0.daysToSeconds())
        _ = try await other.ingest(PumpEventFixtures.batch([settled, mutableBasal], at: at))
        let benign = try await other.ingest(
            PumpEventFixtures.batch([], at: at + 60, replacePendingEvents: false)
        )
        #expect(benign.revoked.isEmpty)
    }
}
