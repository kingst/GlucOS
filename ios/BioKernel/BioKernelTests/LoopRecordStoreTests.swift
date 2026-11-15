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
        // An exercise tick, the one kind that fills in all four override
        // fields, so none of them round-trips as a NULL.
        let written = LoopRecordFixtures.dosed(
            at: at,
            decision: .microBolus(units: 0.425),
            overridePolicy: "exercise",
            overrideTargetGlucoseInMgDl: 142.5,
            overrideBasalRate: 0.51,
            overrideInsulinSensitivity: 77.5
        )
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
        #expect(actual.targetGlucoseInMgDl == expected.targetGlucoseInMgDl)
        #expect(actual.overridePolicy == expected.overridePolicy)
        #expect(actual.overrideTargetGlucoseInMgDl == expected.overrideTargetGlucoseInMgDl)
        #expect(actual.overrideBasalRate == expected.overrideBasalRate)
        #expect(actual.overrideInsulinSensitivity == expected.overrideInsulinSensitivity)
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

    // MARK: - Schema v2: the target columns (dev/backlog/meal-soon.md §6)

    /// Open a v1 database, migrate, read the old rows back: both target fields
    /// nil, nothing dropped. The v1 shape is reached by unwinding the v2
    /// migration from the test's own connection, the same move
    /// `InsulinRecordStoreTests` makes for the scheduled-basal migration.
    @Test func aV1DatabaseMigratesAndKeepsItsRows() async throws {
        let (first, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await first.record(LoopRecordFixtures.dosed(at: at - 5.minutesToSeconds(), decision: .microBolus(units: 0.3)), safetyState: nil, at: at)
        try await first.record(LoopRecordFixtures.skipped(at: at - 1.minutesToSeconds()), safetyState: nil, at: at)

        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try Self.unwindV4(db)
            try Self.unwindV3(db)
            try db.execute(sql: "ALTER TABLE loop_result DROP COLUMN target_mg_dl")
            try db.execute(sql: "ALTER TABLE loop_result DROP COLUMN target_source")
            try db.execute(sql: "DROP TABLE target_override")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-target-override'")
        }

        let second = try GRDBLoopRecordStore(url: url, createdAt: at)
        let records = try await second.records(since: .distantPast)
        #expect(records.count == 2, "nothing dropped")

        let snapshot = try #require(records[0].outcome.snapshot)
        #expect(snapshot.targetGlucoseInMgDl == nil)
        #expect(snapshot.overridePolicy == nil)
        #expect(snapshot.overrideTargetGlucoseInMgDl == nil)
        #expect(snapshot.overrideBasalRate == nil)
        #expect(snapshot.decision == .microBolus(units: 0.3), "the rest of the row survived")
        #expect(records[1].outcome.skipReason == .openLoop)
        #expect(try await second.openTargetOverride() == nil)

        let columns = try await raw.read { db in try db.columns(in: "loop_result").map { $0.name } }
        #expect(columns.contains("target_mg_dl"))
        #expect(columns.contains("target_source"))
    }

    @Test func theTargetColumnRoundTrips() async throws {
        let store = try makeStore()
        try await store.record(
            LoopRecordFixtures.dosed(at: at, targetGlucoseInMgDl: 77.5),
            safetyState: nil,
            at: at
        )

        let snapshot = try #require(try await store.records(since: .distantPast).first?.outcome.snapshot)
        #expect(snapshot.targetGlucoseInMgDl == 77.5)
    }

    // MARK: - Schema v3: the override columns (dev/backlog/more-settings-automation.md)

    private static let overrideColumns = [
        "override_target_mg_dl",
        "dosing_override_enabled",
        "override_basal_rate",
        "override_insulin_sensitivity"
    ]

    /// Takes a v3 database back to its v2 shape from the test's own
    /// connection.
    private static func unwindV3(_ db: Database) throws {
        for column in overrideColumns {
            try db.execute(sql: "ALTER TABLE loop_result DROP COLUMN \(column)")
        }
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3-dosing-override'")
    }

    /// Open a v2 database, migrate, read the old rows back: no override on any
    /// of them and nothing dropped. An override tick written before v3 keeps
    /// the override's target in the target column, where it now reads as the
    /// settings target. That is accepted. An override that was open is
    /// closed on the way through v4, which is tested below.
    @Test func aV2DatabaseMigratesAndKeepsItsRows() async throws {
        let (first, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // What a v2 build stored for an exercise tick: the override's target
        // in the target column, and its name in the target source. Unwinding
        // the later migrations below drops the columns that came after.
        try await first.record(
            LoopRecordFixtures.dosed(at: at - 5.minutesToSeconds(), decision: .microBolus(units: 0.3), targetGlucoseInMgDl: 140, overridePolicy: "exercise", overrideTargetGlucoseInMgDl: 140),
            safetyState: nil,
            at: at
        )
        try await first.record(LoopRecordFixtures.skipped(at: at - 1.minutesToSeconds()), safetyState: nil, at: at)
        _ = try await start(first, at: at - 10.minutesToSeconds(), kind: .exercise, duration: 4.hoursToSeconds())

        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try Self.unwindV4(db)
            try Self.unwindV3(db)
        }

        let second = try GRDBLoopRecordStore(url: url, createdAt: at)
        let records = try await second.records(since: .distantPast)
        #expect(records.count == 2, "nothing dropped")

        let snapshot = try #require(records[0].outcome.snapshot)
        #expect(snapshot.overridePolicy == nil)
        #expect(snapshot.overrideTargetGlucoseInMgDl == nil)
        #expect(snapshot.overrideBasalRate == nil)
        #expect(snapshot.overrideInsulinSensitivity == nil)
        #expect(snapshot.targetGlucoseInMgDl == 140, "the old row keeps the value it had")
        #expect(snapshot.decision == .microBolus(units: 0.3), "the rest of the row survived")
        #expect(records[1].outcome.skipReason == .openLoop)
        #expect(try await second.openTargetOverride() == nil, "closed by v4")

        let points = try await second.filteredGlucose(since: .distantPast)
        #expect(points.map { $0.overrideTargetMgDl } == [nil])
        #expect(points.map { $0.overridePolicy } == ["exercise"], "still named, from the target source the old row kept")

        let columns = try await raw.read { db in try db.columns(in: "loop_result").map { $0.name } }
        for column in Self.overrideColumns {
            #expect(columns.contains(column))
        }
    }

    @Test func theOverrideColumnsRoundTrip() async throws {
        let store = try makeStore()
        try await store.record(
            LoopRecordFixtures.dosed(
                at: at,
                targetGlucoseInMgDl: 92.5,
                overridePolicy: "exercise",
                overrideTargetGlucoseInMgDl: 142.5,
                overrideBasalRate: 0.51,
                overrideInsulinSensitivity: 77.5
            ),
            safetyState: nil,
            at: at
        )

        let snapshot = try #require(try await store.records(since: .distantPast).first?.outcome.snapshot)
        #expect(snapshot.targetGlucoseInMgDl == 92.5, "the settings target, beside the override's")
        #expect(snapshot.overridePolicy == "exercise")
        #expect(snapshot.overrideTargetGlucoseInMgDl == 142.5)
        #expect(snapshot.overrideBasalRate == 0.51)
        #expect(snapshot.overrideInsulinSensitivity == 77.5)
        #expect(snapshot.basalRate == 0.85, "the settings values, beside the scaled ones")
        #expect(snapshot.insulinSensitivity == 46.5)
    }

    /// An override that scales dosing and leaves the target alone, which is
    /// digestion and post exercise: the scaled pair is set and the override
    /// target stays NULL. And one that moves the target and leaves dosing
    /// alone, which is meal soon and exercise soon, is the other way round.
    /// Both name their policy.
    @Test func eachOverrideFillsOnlyItsOwnColumns() async throws {
        let store = try makeStore()
        try await store.record(
            LoopRecordFixtures.dosed(at: at - 5.minutesToSeconds(), overridePolicy: "digestion", overrideBasalRate: 1.105, overrideInsulinSensitivity: 35.75),
            safetyState: nil,
            at: at
        )
        try await store.record(
            LoopRecordFixtures.dosed(at: at, overridePolicy: "mealSoon", overrideTargetGlucoseInMgDl: 77.5),
            safetyState: nil,
            at: at
        )

        let records = try await store.records(since: .distantPast)
        let digestion = try #require(records[0].outcome.snapshot)
        #expect(digestion.overridePolicy == "digestion")
        #expect(digestion.overrideTargetGlucoseInMgDl == nil)
        #expect(digestion.overrideBasalRate == 1.105)
        #expect(digestion.overrideInsulinSensitivity == 35.75)

        let mealSoon = try #require(records[1].outcome.snapshot)
        #expect(mealSoon.overridePolicy == "mealSoon")
        #expect(mealSoon.overrideTargetGlucoseInMgDl == 77.5)
        #expect(mealSoon.overrideBasalRate == nil)
        #expect(mealSoon.overrideInsulinSensitivity == nil)
    }

    /// `target_source` and `dosing_override_enabled` are not fields any
    /// writer sets. Both are worked out from the override values when the
    /// row is written, so the three cannot disagree. `target_source` is the
    /// policy identifier while an override moves the target and `settings`
    /// otherwise, and `dosing_override_enabled` is on exactly when the scaled
    /// basal rate is there.
    @Test func theTargetSourceAndTheDosingFlagAreDerivedWhenTheRowIsWritten() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let written: [LoopRecord] = [
            LoopRecordFixtures.dosed(at: at),
            LoopRecordFixtures.dosed(at: at + 1, overridePolicy: "mealSoon", overrideTargetGlucoseInMgDl: 77.5),
            LoopRecordFixtures.dosed(at: at + 2, overridePolicy: "digestion", overrideBasalRate: 1.105, overrideInsulinSensitivity: 35.75),
            LoopRecordFixtures.dosed(at: at + 3, overridePolicy: "exercise", overrideTargetGlucoseInMgDl: 142.5, overrideBasalRate: 0.51, overrideInsulinSensitivity: 77.5),
            LoopRecordFixtures.dosed(at: at + 4, overridePolicy: "some-future-source", overrideTargetGlucoseInMgDl: 110),
            // What a row written before v2 reads back as.
            LoopRecordFixtures.dosed(at: at + 5, targetGlucoseInMgDl: nil)
        ]
        for record in written {
            try await store.record(record, safetyState: nil, at: at)
        }

        let raw = try DatabaseQueue(path: url.path)
        let rows = try await raw.read { db in
            try Row.fetchAll(db, sql: "SELECT target_source, dosing_override_enabled, override_policy FROM loop_result ORDER BY at").map { row in
                (
                    targetSource: row["target_source"] as String?,
                    dosingOverrideEnabled: row["dosing_override_enabled"] as Bool?,
                    overridePolicy: row["override_policy"] as String?
                )
            }
        }
        #expect(rows.map { $0.targetSource } == ["settings", "mealSoon", "settings", "exercise", "some-future-source", nil])
        #expect(rows.map { $0.dosingOverrideEnabled } == [false, false, true, true, false, false])
        #expect(rows.map { $0.overridePolicy } == [nil, "mealSoon", "digestion", "exercise", "some-future-source", nil])
    }

    /// On a tick with no override the three values and the policy are NULL in
    /// the table, not zero or empty, and the flag is stored as off. A skipped
    /// tick never reached the pipeline and has NULL in all five.
    @Test func theOverrideColumnsAreNullOnATickWithNoOverride() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try await store.record(LoopRecordFixtures.dosed(at: at - 1.minutesToSeconds()), safetyState: nil, at: at)
        try await store.record(LoopRecordFixtures.skipped(at: at), safetyState: nil, at: at)

        let snapshot = try #require(try await store.records(since: .distantPast).first?.outcome.snapshot)
        #expect(snapshot.overridePolicy == nil)
        #expect(snapshot.overrideTargetGlucoseInMgDl == nil)
        #expect(snapshot.overrideBasalRate == nil)
        #expect(snapshot.overrideInsulinSensitivity == nil)

        let raw = try DatabaseQueue(path: url.path)
        let rows = try await raw.read { db in
            try Row.fetchAll(db, sql: "SELECT \(Self.overrideColumns.joined(separator: ", ")), override_policy FROM loop_result ORDER BY at")
        }
        #expect(rows.count == 2)
        let dosed = rows[0]
        #expect(dosed["override_target_mg_dl"] as Double? == nil)
        #expect(dosed["dosing_override_enabled"] as Bool? == false)
        #expect(dosed["override_basal_rate"] as Double? == nil)
        #expect(dosed["override_insulin_sensitivity"] as Double? == nil)
        #expect(dosed["override_policy"] as String? == nil)
        let skipped = rows[1]
        for column in Self.overrideColumns {
            #expect(skipped[column] as Double? == nil, "\(column) on a skipped tick")
        }
        #expect(skipped["override_policy"] as String? == nil)
    }

    @Test func filteredGlucoseCarriesTheTarget() async throws {
        let store = try makeStore()
        let first = at - 10.minutesToSeconds()
        let second = at - 5.minutesToSeconds()

        try await store.record(
            LoopRecordFixtures.dosed(at: first, pid: LoopRecordFixtures.pid(at: first), targetGlucoseInMgDl: 92.5, overridePolicy: "mealSoon", overrideTargetGlucoseInMgDl: 77.5),
            safetyState: nil,
            at: at
        )
        // What a row written before v2 reads back as: NULL in both columns.
        try await store.record(
            LoopRecordFixtures.dosed(at: second, pid: LoopRecordFixtures.pid(at: second), targetGlucoseInMgDl: nil),
            safetyState: nil,
            at: at
        )

        let points = try await store.filteredGlucose(since: .distantPast)
        #expect(points.count == 2)
        #expect(points[0].targetMgDl == 92.5, "the settings target, for the base line")
        #expect(points[0].overridePolicy == "mealSoon")
        #expect(points[0].overrideTargetMgDl == 77.5, "the override's target, for the coloured segment")
        #expect(points[1].targetMgDl == nil)
        #expect(points[1].overridePolicy == nil)
        #expect(points[1].overrideTargetMgDl == nil)
        #expect(points.allSatisfy { abs($0.glucose - 141.5) <= accuracy }, "the filtered-glucose columns are unchanged")
    }

    @Test func filteredGlucoseMarksAPumpErrorAsNotDosed() async throws {
        let store = try makeStore()

        try await store.record(LoopRecordFixtures.dosed(at: at - 10.minutesToSeconds()), safetyState: nil, at: at)
        // The pipeline ran, so this tick has a PID result and a target and is
        // still a point. `dosed` is how the chart knows to break the
        // filtered-glucose line there while the target line carries on.
        try await store.record(LoopRecordFixtures.pumpError(at: at - 5.minutesToSeconds()), safetyState: nil, at: at)

        let points = try await store.filteredGlucose(since: .distantPast)
        #expect(points.map { $0.dosed } == [true, false])
        #expect(points.map { $0.targetMgDl } == [92.5, 92.5])
        #expect(points.map { $0.overrideTargetMgDl } == [nil, nil], "no target override on either")
        #expect(points.map { $0.overridePolicy } == [nil, nil])
    }

    /// The chart read carries the policy identifier as the text the store
    /// holds. A tick whose override only scales dosing has its identifier and
    /// no override target, and an identifier this build does not know comes
    /// through like any other.
    @Test func filteredGlucoseCarriesThePolicyIdentifierAsText() async throws {
        let store = try makeStore()
        let ticks: [(policy: String?, overrideTarget: Double?, overrideBasalRate: Double?)] = [
            (nil, nil, nil),
            ("digestion", nil, 1.105),
            ("exercise", 142.5, 0.51),
            ("some-future-source", 110, nil)
        ]
        for (index, tick) in ticks.enumerated() {
            let instant = at + Double(index) * 5.minutesToSeconds()
            try await store.record(
                LoopRecordFixtures.dosed(
                    at: instant,
                    pid: LoopRecordFixtures.pid(at: instant),
                    overridePolicy: tick.policy,
                    overrideTargetGlucoseInMgDl: tick.overrideTarget,
                    overrideBasalRate: tick.overrideBasalRate,
                    overrideInsulinSensitivity: tick.overrideBasalRate.map { _ in 77.5 }
                ),
                safetyState: nil,
                at: at
            )
        }

        let points = try await store.filteredGlucose(since: .distantPast)
        #expect(points.map { $0.overridePolicy } == [nil, "digestion", "exercise", "some-future-source"])
        #expect(points.map { $0.overrideTargetMgDl } == [nil, nil, 142.5, 110])
        #expect(points.allSatisfy { $0.targetMgDl == 92.5 })
    }

    // MARK: - Target overrides (dev/backlog/meal-soon.md §5)

    /// `kind` as the screen starts it: under its policy identifier, with the
    /// effect it has at `settingsTarget`.
    private func start(_ store: GRDBLoopRecordStore, at: Date, settingsTarget: Double = 90, kind: TargetOverrideKind = .mealSoon, duration: TimeInterval = 60.minutesToSeconds()) async throws -> TargetOverride {
        return try await store.startTargetOverride(
            policyIdentifier: kind.policyIdentifier,
            effect: kind.effect(settingsTargetMgDl: settingsTarget),
            at: at,
            expiresAt: at + duration,
            settingsTargetMgDl: settingsTarget
        )
    }

    /// Starting one kind closes the other, the same as starting the same
    /// kind again (dev/backlog/exercise.md §3).
    @Test func anExerciseSoonRowRoundTripsItsKindAndSupersedesMealSoon() async throws {
        let store = try makeStore()
        let mealSoon = try await start(store, at: at)
        let exerciseSoon = try await start(store, at: at + 10.minutesToSeconds(), kind: .exerciseSoon, duration: 2.hoursToSeconds())
        #expect(exerciseSoon.kind == .exerciseSoon)
        #expect(exerciseSoon.expiresAt == at + 10.minutesToSeconds() + 2.hoursToSeconds())
        #expect(exerciseSoon.duration == 2.hoursToSeconds())
        #expect(try await store.openTargetOverride() == exerciseSoon)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.kind } == [.mealSoon, .exerciseSoon])
        #expect(rows[0].id == mealSoon.id)
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == at + 10.minutesToSeconds())
    }

    /// Every kind round-trips through `target_override`, with its effect.
    /// Each start closes the one before it, so there is never more than one
    /// open row whatever the kinds.
    @Test func everyKindRoundTripsThroughTargetOverride() async throws {
        let store = try makeStore()
        var started: [TargetOverride] = []
        for (index, kind) in TargetOverrideKind.allCases.enumerated() {
            let override = try await start(store, at: at + Double(index).minutesToSeconds(), kind: kind, duration: kind.defaultDuration)
            #expect(override.kind == kind)
            #expect(override.policyIdentifier == kind.policyIdentifier)
            #expect(override.effect == kind.effect(settingsTargetMgDl: 90))
            #expect(override.duration == kind.defaultDuration)
            #expect(try await store.openTargetOverride() == override)
            started.append(override)
        }

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.policyIdentifier } == TargetOverrideKind.allCases.map { $0.policyIdentifier })
        #expect(rows.map { $0.effect } == TargetOverrideKind.allCases.map { $0.effect(settingsTargetMgDl: 90) })
        #expect(rows.map { $0.id } == started.map { $0.id })
        #expect(rows.dropLast().allSatisfy { $0.endReason == .cancelled })
        #expect(rows.filter { $0.endedAt == nil }.map { $0.kind } == [.postExercise], "never more than one open row")
    }

    /// The raw values are what is on disk, so they are part of the schema.
    @Test func theKindRawValuesAreWhatIsStored() {
        #expect(TargetOverrideKind.allCases.map { $0.rawValue } == ["mealSoon", "digestion", "exerciseSoon", "exercise", "postExercise"])
    }

    // MARK: - Schema v4: the effect on the row (dev/backlog/override-mechanism.md)

    /// Takes a v4 database back to its v3 shape from the test's own
    /// connection.
    private static func unwindV4(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE target_override DROP COLUMN target_offset_mg_dl")
        try db.execute(sql: "ALTER TABLE target_override DROP COLUMN dosing_multiplier")
        try db.execute(sql: "ALTER TABLE loop_result DROP COLUMN override_policy")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-override-effect'")
    }

    /// The row stores its effect: a target offset, a dosing multiplier, both,
    /// or neither side, with NULL for a side that is left alone. Nothing here
    /// checks the numbers. That is the override manager's job, and a row from
    /// anywhere else is clamped when it is read for a tick.
    @Test func theEffectColumnsRoundTrip() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let effects = [
            OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil),
            OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 1.3),
            OverrideEffect(targetOffsetMgDl: 50, dosingMultiplier: 0.6),
            OverrideEffect(targetOffsetMgDl: 0, dosingMultiplier: nil),
            OverrideEffect(targetOffsetMgDl: 500, dosingMultiplier: 3)
        ]
        for (index, effect) in effects.enumerated() {
            let startedAt = at + Double(index).minutesToSeconds()
            let override = try await store.startTargetOverride(policyIdentifier: "policy-\(index)", effect: effect, at: startedAt, expiresAt: startedAt + 30.minutesToSeconds(), settingsTargetMgDl: 90)
            #expect(override.effect == effect)
            #expect(try await store.openTargetOverride() == override)
        }

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.effect } == effects)
        #expect(rows.map { $0.policyIdentifier } == ["policy-0", "policy-1", "policy-2", "policy-3", "policy-4"])

        let raw = try DatabaseQueue(path: url.path)
        let stored = try await raw.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, target_offset_mg_dl, dosing_multiplier, end_bolus_sync_id FROM target_override ORDER BY id").map { row in
                (
                    kind: row["kind"] as String?,
                    targetOffsetMgDl: row["target_offset_mg_dl"] as Double?,
                    dosingMultiplier: row["dosing_multiplier"] as Double?,
                    endBolusSyncId: row["end_bolus_sync_id"] as String?
                )
            }
        }
        #expect(stored.map { $0.kind } == ["policy-0", "policy-1", "policy-2", "policy-3", "policy-4"], "the kind column holds the policy identifier")
        #expect(stored.map { $0.targetOffsetMgDl } == [-15, nil, 50, 0, 500])
        #expect(stored.map { $0.dosingMultiplier } == [nil, 1.3, 0.6, nil, 3])
        #expect(stored.allSatisfy { $0.endBolusSyncId == nil }, "still in the table, and no longer written")
    }

    /// A policy identifier this build does not know is not dropped on read.
    /// An open row that was dropped would stay open and hidden: still in the
    /// table, never evaluated and never closed.
    @Test func aRowWithAnUnknownPolicyIdentifierIsReadLikeAnyOther() async throws {
        let store = try makeStore()
        let effect = OverrideEffect(targetOffsetMgDl: 20, dosingMultiplier: 0.9)
        let override = try await store.startTargetOverride(policyIdentifier: "some-future-source", effect: effect, at: at, expiresAt: at + 45.minutesToSeconds(), settingsTargetMgDl: 90)

        #expect(override.kind == nil)
        #expect(try await store.openTargetOverride() == override)
        #expect(try await store.targetOverrides(since: .distantPast) == [override])

        try await store.endTargetOverride(id: override.id, at: at + 45.minutesToSeconds(), reason: .expired)
        #expect(try await store.openTargetOverride() == nil)
        let closed = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(closed.policyIdentifier == "some-future-source")
        #expect(closed.effect == effect)
        #expect(closed.endReason == .expired)
    }

    /// Open a v3 database with an override open and two closed. The open one
    /// has no stored effect, so v4 closes it as cancelled at the instant the
    /// store is opened, and the loop is on the settings until the next start.
    /// The closed rows are left exactly as they were, with NULL in the two
    /// effect columns, including one a v3 build closed on a manual bolus.
    @Test func aV3DatabaseMigratesClosingAnOpenOverrideAndLeavingClosedOnesAlone() async throws {
        let (first, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let mealSoon = try await start(first, at: at - 3.hoursToSeconds())
        try await first.endTargetOverride(id: mealSoon.id, at: at - 160.minutesToSeconds(), reason: .manualBolus)
        let digestion = try await start(first, at: at - 2.hoursToSeconds(), kind: .digestion, duration: 2.hoursToSeconds())
        // Starting exercise closes digestion as cancelled, and is left open.
        let exercise = try await start(first, at: at - 30.minutesToSeconds(), kind: .exercise, duration: 1.hoursToSeconds())
        try await first.record(LoopRecordFixtures.dosed(at: at - 5.minutesToSeconds(), overridePolicy: "exercise", overrideTargetGlucoseInMgDl: 142.5, overrideBasalRate: 0.51, overrideInsulinSensitivity: 77.5), safetyState: nil, at: at)

        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            // What the v3 build wrote beside the reason.
            try db.execute(sql: "UPDATE target_override SET end_bolus_sync_id = 'bolus-1' WHERE id = ?", arguments: [mealSoon.id])
            try Self.unwindV4(db)
        }

        let second = try GRDBLoopRecordStore(url: url, createdAt: at)
        #expect(try await second.openTargetOverride() == nil, "nothing is open after the migration")

        let rows = try await second.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.id } == [mealSoon.id, digestion.id, exercise.id], "nothing dropped")
        #expect(rows.map { $0.policyIdentifier } == ["mealSoon", "digestion", "exercise"])
        #expect(rows.map { $0.endReason } == [.manualBolus, .cancelled, .cancelled])
        #expect(rows.map { $0.endedAt } == [at - 160.minutesToSeconds(), at - 30.minutesToSeconds(), at], "the open one is closed at the instant the store was opened")
        #expect(rows.allSatisfy { $0.effect == OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: nil) }, "no effect is worked out for a row that is already over")

        // The tick written before v4 has no policy of its own, and the chart
        // read still names it from the target source.
        let snapshot = try #require(try await second.records(since: .distantPast).first?.outcome.snapshot)
        #expect(snapshot.overridePolicy == nil)
        #expect(snapshot.overrideTargetGlucoseInMgDl == 142.5)
        #expect(try await second.filteredGlucose(since: .distantPast).map { $0.overridePolicy } == ["exercise"])

        let stored = try await raw.read { db in
            try String.fetchOne(db, sql: "SELECT end_bolus_sync_id FROM target_override WHERE id = ?", arguments: [mealSoon.id])
        }
        #expect(stored == "bolus-1", "the column and what was in it are left alone")
        let columns = try await raw.read { db in try db.columns(in: "target_override").map { $0.name } }
        #expect(columns.contains("target_offset_mg_dl"))
        #expect(columns.contains("dosing_multiplier"))
        let loopResultColumns = try await raw.read { db in try db.columns(in: "loop_result").map { $0.name } }
        #expect(loopResultColumns.contains("override_policy"))

        // And the next start works.
        let next = try await start(second, at: at + 1.minutesToSeconds(), kind: .postExercise, duration: 30.minutesToSeconds())
        #expect(next.effect == OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 0.8))
        #expect(try await second.openTargetOverride() == next)
    }

    /// The migration runs once. Opening a v4 store again does not close what
    /// is open.
    @Test func reopeningAV4DatabaseLeavesAnOpenOverrideOpen() async throws {
        let (first, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let open = try await start(first, at: at, kind: .exerciseSoon, duration: 2.hoursToSeconds())

        let second = try GRDBLoopRecordStore(url: url, createdAt: at + 10.minutesToSeconds())
        #expect(try await second.openTargetOverride() == open)
    }

    @Test func startingAnOverrideClosesTheOpenOneAsCancelled() async throws {
        let store = try makeStore()
        let first = try await start(store, at: at)
        #expect(first.endedAt == nil)
        #expect(first.kind == .mealSoon)
        #expect(first.expiresAt == at + 60.minutesToSeconds())
        #expect(first.settingsTargetMgDl == 90)
        #expect(try await store.openTargetOverride() == first)

        let second = try await start(store, at: at + 10.minutesToSeconds(), settingsTarget: 95)
        #expect(try await store.openTargetOverride() == second)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 2)
        #expect(rows[0].id == first.id)
        #expect(rows[0].endedAt == at + 10.minutesToSeconds(), "closed at the same instant the second opened")
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[1] == second)
        #expect(rows.filter { $0.endedAt == nil }.count == 1, "never more than one open row")
    }

    @Test func openTargetOverrideReturnsTheNewestOpenRowAndIgnoresClosed() async throws {
        let store = try makeStore()
        #expect(try await store.openTargetOverride() == nil)

        let first = try await start(store, at: at)
        try await store.endTargetOverride(id: first.id, at: at + 5.minutesToSeconds(), reason: .expired)
        #expect(try await store.openTargetOverride() == nil, "a closed row is a log entry, not state")

        let second = try await start(store, at: at + 2.hoursToSeconds())
        #expect(try await store.openTargetOverride() == second)
    }

    @Test func endingAnOverrideIsFirstWriterWins() async throws {
        let store = try makeStore()
        let override = try await start(store, at: at)

        try await store.endTargetOverride(id: override.id, at: at + 20.minutesToSeconds(), reason: .expired)
        // The switch, racing the per-tick observer, loses.
        try await store.endTargetOverride(id: override.id, at: at + 25.minutesToSeconds(), reason: .cancelled)

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.endedAt == at + 20.minutesToSeconds())
        #expect(row.endReason == .expired)
    }

    @Test func targetOverridesAreWindowedByStartedAtOldestFirst() async throws {
        let store = try makeStore()
        _ = try await start(store, at: at - 3.hoursToSeconds())
        _ = try await start(store, at: at - 1.hoursToSeconds())
        _ = try await start(store, at: at)

        let rows = try await store.targetOverrides(since: at - 1.hoursToSeconds())
        #expect(rows.map { $0.startedAt } == [at - 1.hoursToSeconds(), at], "inclusive on the left")
    }

    @Test func retentionPrunesTargetOverridesByStartedAt() async throws {
        let store = try makeStore()
        let old = at
        _ = try await start(store, at: old)

        let insideEdge = old + LoopRecordStorePolicy.retention
        _ = try await start(store, at: insideEdge)

        // The sweep runs on every loop-result write.
        try await store.record(LoopRecordFixtures.dosed(at: insideEdge), safetyState: nil, at: insideEdge)
        #expect(try await store.targetOverrides(since: .distantPast).count == 2, "a row exactly on the horizon is kept")

        try await store.record(LoopRecordFixtures.dosed(at: insideEdge + 1), safetyState: nil, at: insideEdge + 1)
        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.startedAt } == [insideEdge])
    }

    @Test func theExportSnapshotContainsTargetOverride() async throws {
        let (store, url) = try makeFileStore()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try await start(store, at: at)

        let snapshot = try #require(await store.exportSnapshotURL())
        let copy = try DatabaseQueue(path: snapshot.path)
        let count = try await copy.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM target_override") ?? 0 }
        #expect(count == 1)
    }
}
