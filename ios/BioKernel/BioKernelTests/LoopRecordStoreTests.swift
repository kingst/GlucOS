//
//  LoopRecordStoreTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/16/26.
//
//  `GRDBLoopRecordStore`: the schema, the two dosing-path queries, the
//  transaction that pairs a loop result with its ledger entry, retention, and
//  the round trip.
//
//  Most of this runs against an in-memory `DatabaseQueue`. Three tests do not,
//  because what they assert — that the two inserts are one transaction, that the
//  foreign key is enforced, that deleting a loop result takes its safety state
//  with it — is only reachable with a second connection to the same file. That
//  is the same move `InsulinRecordStoreTests` makes to unwind a migration:
//  reach the database from the test's own connection rather than adding a seam
//  to the store for a test to pull.
//
//  The atomicity test in particular has no other way in. Every value that
//  reaches `record` is well-formed by construction — `SafetyState.Kind` is an
//  enum, the columns it fills are derived from it — so nothing a caller can pass
//  makes the second insert fail. Dropping the table out from under it does.
//

import Testing
import Foundation
import GRDB
@testable import BioKernel

struct LoopRecordStoreTests {

    let accuracy = 0.0000001
    let at = Date.f("2026-08-16 12:00:00 +0000")

    // MARK: - Fixtures

    private func makeStore(createdAt: Date = .distantPast) throws -> GRDBLoopRecordStore {
        return try GRDBLoopRecordStore(inMemoryCreatedAt: createdAt)
    }

    /// A file-backed store plus its directory, for the tests that need a second
    /// connection. The caller removes the directory.
    private func makeFileStore(createdAt: Date = .distantPast) throws -> (store: GRDBLoopRecordStore, url: URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("loop_records.sqlite", isDirectory: false)
        return (try GRDBLoopRecordStore(url: url, createdAt: createdAt), url)
    }

    private func ledger(at: Date, decision: DosingDecision) -> SafetyState {
        return SafetyState(
            at: at,
            decision: decision,
            candidates: LoopRecordFixtures.candidates(),
            duration: 30.minutesToSeconds()
        )
    }

    // MARK: - lastMicroBolus, the throttle's input

    @Test func lastMicroBolusReturnsTheNewestDosedMicroBolus() async throws {
        let store = try makeStore()

        try await store.record(LoopRecordFixtures.dosed(at: at - 60.minutesToSeconds(), decision: .microBolus(units: 0.2)), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.dosed(at: at - 20.minutesToSeconds(), decision: .microBolus(units: 0.35)), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.dosed(at: at - 40.minutesToSeconds(), decision: .microBolus(units: 0.3)), safetyState: nil, at: at)

        let newest = try await store.lastMicroBolus()
        #expect(newest == at - 20.minutesToSeconds(), "newest by `at`, not by insertion order")
    }

    /// The partial index this query runs on names both predicates. All three of
    /// these rows would match a looser one, and each would open the throttle for
    /// a bolus that never happened.
    @Test func lastMicroBolusIgnoresEverythingThatIsNotADosedMicroBolus() async throws {
        let store = try makeStore()

        try await store.record(LoopRecordFixtures.dosed(at: at - 30.minutesToSeconds(), decision: .microBolus(units: 0.3)), safetyState: nil, at: at)
        // A temp basal decision, which is the common case and must not count.
        try await store.record(LoopRecordFixtures.dosed(at: at - 10.minutesToSeconds(), decision: .tempBasal(unitsPerHour: 1.1)), safetyState: nil, at: at)
        // A micro bolus the pump refused: the decision was made, the insulin was
        // not delivered, so there is nothing to throttle against.
        try await store.record(LoopRecordFixtures.pumpError(at: at - 5.minutesToSeconds(), decision: .microBolus(units: 0.4)), safetyState: nil, at: at)
        // A tick that never reached the pipeline.
        try await store.record(LoopRecordFixtures.skipped(at: at - 1.minutesToSeconds()), safetyState: nil, at: at)

        #expect(try await store.lastMicroBolus() == at - 30.minutesToSeconds())
    }

    @Test func lastMicroBolusIsNilOnAnEmptyStore() async throws {
        let store = try makeStore()
        #expect(try await store.lastMicroBolus() == nil)
    }

    // MARK: - The safety window

    /// Half-open, matching the filter it replaced exactly:
    /// `$0.at >= (start - duration) && $0.at < at`. Both edges are load bearing —
    /// the right one because the tick being decided is not part of its own
    /// history, and double-counting it would spend budget twice.
    @Test func theSafetyWindowIsHalfOpen() async throws {
        let store = try makeStore()
        let from = at - 3.hoursToSeconds()

        for instant in [from - 1, from, at - 1, at] {
            try await store.record(
                LoopRecordFixtures.dosed(at: instant, decision: .tempBasal(unitsPerHour: 1.0)),
                safetyState: ledger(at: instant, decision: .tempBasal(unitsPerHour: 1.0)),
                at: at
            )
        }

        let states = try await store.safetyStates(from: from, to: at)
        #expect(states.map { $0.at } == [from, at - 1], "closed on the left, open on the right")
    }

    @Test func aWindowOlderThanTheStoreThrowsRatherThanReturningEmpty() async throws {
        let store = try makeStore(createdAt: at)

        await #expect(throws: LoopRecordStoreError.self) {
            _ = try await store.safetyStates(from: at - 1, to: at + 1.minutesToSeconds())
        }

        // The same query one instant later is answerable, and empty is then a
        // real answer rather than an unknown one.
        let states = try await store.safetyStates(from: at, to: at + 1.minutesToSeconds())
        #expect(states.isEmpty)
    }

    @Test func safetyStatesRoundTripEveryKind() async throws {
        let store = try makeStore()
        let decisions: [DosingDecision] = [
            .tempBasal(unitsPerHour: 1.35),
            .microBolus(units: 0.45),
            .suspendForBiologicalInvariant(mgDlPerHour: -52.5)
        ]

        for (index, decision) in decisions.enumerated() {
            let instant = at - Double(decisions.count - index).minutesToSeconds()
            try await store.record(
                LoopRecordFixtures.dosed(at: instant, decision: decision),
                safetyState: ledger(at: instant, decision: decision),
                at: at
            )
        }

        let states = try await store.safetyStates(from: at - 1.hoursToSeconds(), to: at)
        #expect(states.count == 3)

        guard case .tempBasal(let programmed, let physiological) = states[0].kind else {
            Issue.record("expected .tempBasal; got \(states[0].kind)")
            return
        }
        #expect(programmed == 1.35)
        #expect(physiological == LoopRecordFixtures.candidates().physiologicalTempBasal)

        guard case .microBolus(let bolusProgrammed, let bolusPhysiological) = states[1].kind else {
            Issue.record("expected .microBolus; got \(states[1].kind)")
            return
        }
        #expect(bolusProgrammed == 0.45)
        #expect(bolusPhysiological == LoopRecordFixtures.candidates().physiologicalMicroBolus)

        guard case .suspended = states[2].kind else {
            Issue.record("expected .suspended; got \(states[2].kind)")
            return
        }
        #expect(states[2].duration == 30.minutesToSeconds())
    }

    // MARK: - One transaction

    /// The defect this store exists to close: two writes describing one tick,
    /// with a window between them where a kill leaves the ledger holding a record
    /// the loop log does not.
    @Test func aFailedSafetyInsertRollsBackTheLoopResult() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // A successful pairing first, so the assertion below is about the rollback
        // rather than about an empty store.
        try await store.record(
            LoopRecordFixtures.dosed(at: at - 5.minutesToSeconds(), decision: .tempBasal(unitsPerHour: 1.0)),
            safetyState: ledger(at: at - 5.minutesToSeconds(), decision: .tempBasal(unitsPerHour: 1.0)),
            at: at
        )
        #expect(try await store.records(since: .distantPast).count == 1)

        // Take the ledger table away from under the second insert. Nothing a
        // caller can pass reaches this state; the point is only to make the
        // second statement in the transaction fail.
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in try db.execute(sql: "DROP TABLE safety_state") }

        await #expect(throws: LoopRecordStoreError.self) {
            try await store.record(
                LoopRecordFixtures.dosed(at: at, decision: .microBolus(units: 0.3)),
                safetyState: ledger(at: at, decision: .microBolus(units: 0.3)),
                at: at
            )
        }

        let records = try await store.records(since: .distantPast)
        #expect(records.count == 1, "the loop result must not survive its ledger entry failing")
        #expect(records[0].at == at - 5.minutesToSeconds())
    }

    @Test func aSafetyStateCannotExistWithoutItsLoopResult() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(LoopRecordFixtures.dosed(at: at, decision: .tempBasal(unitsPerHour: 1.0)), safetyState: nil, at: at)

        let raw = try DatabaseQueue(path: url.path)
        await #expect(throws: (any Error).self, "an orphan ledger entry must be rejected") {
            try await raw.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO safety_state (loop_result_id, at, duration, kind, programmed, physiological)
                        VALUES (?, ?, ?, 'tempBasal', 1.0, 0.5)
                        """,
                    arguments: [99_999, self.at.timeIntervalSince1970, 30.minutesToSeconds()]
                )
            }
        }
    }

    @Test func deletingALoopResultTakesItsSafetyStateWithIt() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(
            LoopRecordFixtures.dosed(at: at, decision: .tempBasal(unitsPerHour: 1.0)),
            safetyState: ledger(at: at, decision: .tempBasal(unitsPerHour: 1.0)),
            at: at
        )

        let raw = try DatabaseQueue(path: url.path)
        let before = try await raw.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM safety_state") ?? 0 }
        #expect(before == 1)

        try await raw.write { db in try db.execute(sql: "DELETE FROM loop_result") }

        let after = try await raw.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM safety_state") ?? 0 }
        #expect(after == 0, "ON DELETE CASCADE is what makes retention a single DELETE")
    }

    // MARK: - Retention

    @Test func retentionDeletesPastNinetyDaysAndCascades() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let old = at
        try await store.record(
            LoopRecordFixtures.dosed(at: old, decision: .tempBasal(unitsPerHour: 1.0)),
            safetyState: ledger(at: old, decision: .tempBasal(unitsPerHour: 1.0)),
            at: old
        )

        // Just inside the horizon: the sweep runs on every write and must not
        // take this one.
        let insideEdge = old + LoopRecordStorePolicy.retention
        try await store.record(LoopRecordFixtures.dosed(at: insideEdge, decision: .tempBasal(unitsPerHour: 1.0)), safetyState: nil, at: insideEdge)
        #expect(try await store.records(since: .distantPast).count == 2, "a row exactly on the horizon is kept")

        // One second past it.
        let past = insideEdge + 1
        try await store.record(LoopRecordFixtures.dosed(at: past, decision: .tempBasal(unitsPerHour: 1.0)), safetyState: nil, at: past)

        let records = try await store.records(since: .distantPast)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.at > old })

        let raw = try DatabaseQueue(path: url.path)
        let ledgerRows = try await raw.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM safety_state") ?? 0 }
        #expect(ledgerRows == 0, "the pruned loop result took its ledger entry with it")
    }

    // MARK: - The round trip

    @Test func everyFieldOfADosedRecordRoundTrips() async throws {
        let store = try makeStore()
        let written = LoopRecordFixtures.dosed(at: at, decision: .microBolus(units: 0.425))
        try await store.record(written, safetyState: nil, at: at)

        let read = try #require(try await store.records(since: .distantPast).first)
        #expect(read.at == at)

        guard case .dosed(let expected) = written.outcome, case .dosed(let actual) = read.outcome else {
            Issue.record("expected both to be .dosed")
            return
        }

        #expect(actual.glucoseInMgDl == expected.glucoseInMgDl)
        #expect(actual.insulinOnBoard == expected.insulinOnBoard)
        #expect(actual.insulinSensitivity == expected.insulinSensitivity)
        #expect(actual.basalRate == expected.basalRate)
        #expect(actual.predictedAddedGlucoseInMgDlPerHour == expected.predictedAddedGlucoseInMgDlPerHour)
        #expect(actual.machineLearningInsulinLastThreeHours == expected.machineLearningInsulinLastThreeHours)
        #expect(actual.decision == expected.decision)

        #expect(actual.candidates.physiologicalTempBasal == expected.candidates.physiologicalTempBasal)
        #expect(actual.candidates.mlTempBasal == expected.candidates.mlTempBasal)
        #expect(actual.candidates.physiologicalMicroBolus == expected.candidates.physiologicalMicroBolus)
        #expect(actual.candidates.mlMicroBolus == expected.candidates.mlMicroBolus)

        #expect(actual.pid.at == expected.pid.at)
        #expect(actual.pid.Kp == expected.pid.Kp)
        #expect(actual.pid.Ki == expected.pid.Ki)
        #expect(actual.pid.Kd == expected.pid.Kd)
        #expect(actual.pid.filteredGlucose == expected.pid.filteredGlucose)
        #expect(actual.pid.error == expected.pid.error)
        #expect(actual.pid.accumulatedError == expected.pid.accumulatedError)
        #expect(actual.pid.derivative == expected.pid.derivative)
        #expect(actual.pid.deltaGlucoseError == expected.pid.deltaGlucoseError)
        #expect(actual.pid.basalRateInsulinOnBoard == expected.pid.basalRateInsulinOnBoard)
    }

    /// The three PID fields that are optional in the domain type. `nil` is what
    /// the first loop after a restart produces — no previous glucose, so no
    /// derivative — so this is the common case rather than an edge one.
    @Test func theOptionalPidFieldsRoundTripAsNull() async throws {
        let store = try makeStore()
        try await store.record(
            LoopRecordFixtures.dosed(at: at, pid: LoopRecordFixtures.pidWithNilOptionals(at: at)),
            safetyState: nil,
            at: at
        )

        let read = try #require(try await store.records(since: .distantPast).first)
        let snapshot = try #require(read.outcome.snapshot)
        #expect(snapshot.pid.derivative == nil)
        #expect(snapshot.pid.deltaGlucoseError == nil)
        #expect(snapshot.pid.basalRateInsulinOnBoard == nil)
        // The non-optional neighbours still made it, so this is not just a row of
        // NULLs decoding into a row of nils.
        #expect(snapshot.pid.accumulatedError == 512.25)
    }

    @Test func skippedAndPumpErrorRoundTrip() async throws {
        let store = try makeStore()
        try await store.record(LoopRecordFixtures.skipped(at: at - 2.minutesToSeconds(), reason: .pumpReadingStale), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.pumpError(at: at - 1.minutesToSeconds(), decision: .microBolus(units: 0.5)), safetyState: nil, at: at)

        let records = try await store.records(since: .distantPast)
        #expect(records.count == 2)

        #expect(records[0].outcome.skipReason == .pumpReadingStale)
        #expect(records[0].outcome.snapshot == nil, "a skipped tick never reached the pipeline")

        guard case .pumpError(let attempted) = records[1].outcome else {
            Issue.record("expected .pumpError; got \(records[1].outcome)")
            return
        }
        #expect(attempted.decision == .microBolus(units: 0.5))
    }

    // MARK: - The chart reads

    @Test func filteredGlucoseIsWindowedAndOrdered() async throws {
        let store = try makeStore()
        let since = at - 1.hoursToSeconds()

        for offset in [-90.0, -30.0, -10.0] {
            let instant = at + offset.minutesToSeconds()
            try await store.record(
                LoopRecordFixtures.dosed(at: instant, pid: LoopRecordFixtures.pid(at: instant)),
                safetyState: nil,
                at: at
            )
        }
        // A skipped tick has no PID result and must not appear as a point.
        try await store.record(LoopRecordFixtures.skipped(at: at - 20.minutesToSeconds()), safetyState: nil, at: at)

        let points = try await store.filteredGlucose(since: since)
        #expect(points.map { $0.at } == [at - 30.minutesToSeconds(), at - 10.minutesToSeconds()])
        #expect(points.allSatisfy { abs($0.glucose - 141.5) <= accuracy })
    }

    @Test func latestRecordReturnsTheNewestOfAnyOutcome() async throws {
        let store = try makeStore()
        #expect(try await store.latestRecord() == nil)

        try await store.record(LoopRecordFixtures.dosed(at: at - 10.minutesToSeconds()), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.skipped(at: at - 5.minutesToSeconds(), reason: .openLoop), safetyState: nil, at: at)

        let latest = try #require(try await store.latestRecord())
        #expect(latest.at == at - 5.minutesToSeconds())
        #expect(latest.outcome.skipReason == .openLoop)
    }

    @Test func recordsAreWindowedFromTheLeft() async throws {
        let store = try makeStore()
        let since = at - 24.hoursToSeconds()

        try await store.record(LoopRecordFixtures.dosed(at: since - 1), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.dosed(at: since), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.dosed(at: at), safetyState: nil, at: at)

        let records = try await store.records(since: since)
        #expect(records.map { $0.at } == [since, at], "inclusive on the left")
    }
}
