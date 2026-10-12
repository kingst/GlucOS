//
//  GlucoseRecordStoreTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/5/26.
//
//  `GRDBGlucoseRecordStore`: schema, dedup, retention, and the reads the loop
//  makes.
//
//  The tests worth having here are the ones the JSON log could not express:
//  history that outlives a relaunch, a retention boundary that is a date rather
//  than an array length, and a backfill that re-reports readings we already hold
//  without re-firing the side effects keyed to new ones. Everything runs against
//  an in-memory `DatabaseQueue` except where a test is specifically about
//  reopening a file.
//

import Testing
import Foundation
import GRDB
import HealthKit
import LoopKit
@testable import BioKernel

// MARK: - Fixtures

enum GlucoseFixtures {
    /// `syncIdentifier` is the store's dedup key, so every fixture derives it
    /// from `id` — passing a fresh UUID per call would make a "duplicate" test
    /// pass for the wrong reason.
    static func reading(
        id: String,
        at: Date,
        mgDl: Double,
        trend: GlucoseTrend? = .flat,
        trendRateMgDlPerMinute: Double? = 0.1,
        condition: GlucoseCondition? = nil,
        isDisplayOnly: Bool = false,
        wasUserEntered: Bool = false,
        device: HKDevice? = nil
    ) -> NewGlucoseSample {
        return NewGlucoseSample(
            date: at,
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: mgDl),
            condition: condition,
            trend: trend,
            trendRate: trendRateMgDlPerMinute.map {
                HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: isDisplayOnly,
            wasUserEntered: wasUserEntered,
            syncIdentifier: id,
            device: device
        )
    }

    /// A CGM's usual output: one reading every five minutes, oldest first.
    static func series(
        endingAt: Date,
        count: Int,
        startingAtMgDl: Double = 100,
        stepMgDl: Double = 1,
        idPrefix: String = "cgm"
    ) -> [NewGlucoseSample] {
        return (0..<count).map { index in
            let stepsBack = count - 1 - index
            return reading(
                id: "\(idPrefix)-\(index)",
                at: endingAt - Double(stepsBack) * 5.minutesToSeconds(),
                mgDl: startingAtMgDl + Double(index) * stepMgDl
            )
        }
    }
}

// MARK: - Tests

struct GlucoseRecordStoreTests {
    /// A fixed instant, because `Date()` in a test that asserts about time is a
    /// test that fails on a slow machine.
    static let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeStore(createdAt: Date = GlucoseRecordStoreTests.now) throws -> GRDBGlucoseRecordStore {
        return try GRDBGlucoseRecordStore(inMemoryCreatedAt: createdAt)
    }

    // MARK: - Schema

    @Test func aNewStoreIsEmpty() async throws {
        let store = try makeStore()
        #expect(try await store.lastReading() == nil)
        #expect(try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture).isEmpty)
    }

    @Test func anUnopenableDatabaseIsLoud() async throws {
        // Same rule as the insulin store: a store that cannot open must say so,
        // not present as an empty history. `AppComposition` is what decides how
        // the app degrades, and it cannot decide anything about a silent success.
        let url = URL(fileURLWithPath: "/dev/null/not-a-directory/glucose_readings.sqlite")
        #expect(throws: GlucoseRecordStoreError.self) {
            _ = try GRDBGlucoseRecordStore(url: url, createdAt: Self.now)
        }
    }

    @Test func readingsSurviveReopening() async throws {
        // The whole point of the store, and the one thing `glucose.json` could
        // not do past 24 hours.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("glucose_readings.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let readings = GlucoseFixtures.series(endingAt: Self.now, count: 12)
        let first = try GRDBGlucoseRecordStore(url: url, createdAt: Self.now - 30.0.daysToSeconds())
        _ = try await first.ingest(readings, at: Self.now)

        let second = try GRDBGlucoseRecordStore(url: url, createdAt: Self.now)
        let restored = try await second.readingsBetween(startDate: .distantPast, endDate: .distantFuture)
        #expect(restored.count == 12)
        #expect(restored.map { $0.syncIdentifier } == readings.map { $0.syncIdentifier })
    }

    @Test func aV1DatabaseUpgradesAndKeepsItsReadings() async throws {
        // The only migration path that exists in the wild: v1 shipped with a
        // `legacy_import_at` column for the one-time `glucose.json` seed, that seed
        // ran, and v2 drops the column. Every other test starts from an empty file
        // and runs v1 and v2 together, which is the one case this cannot check.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("glucose_readings.sqlite")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // v1 exactly as it shipped, with GRDB's bookkeeping saying so.
        let v1 = try DatabaseQueue(path: url.path)
        try await v1.write { db in
            try db.execute(sql: """
                CREATE TABLE glucose_reading (
                  sync_identifier             TEXT PRIMARY KEY,
                  date                        DOUBLE NOT NULL,
                  glucose_mg_dl               DOUBLE NOT NULL,
                  condition                   TEXT,
                  trend                       INTEGER,
                  trend_rate_mg_dl_per_minute DOUBLE,
                  is_display_only             INTEGER NOT NULL,
                  was_user_entered            INTEGER NOT NULL,
                  sync_version                INTEGER NOT NULL,
                  device                      BLOB,
                  recorded_at                 DOUBLE NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_glucose_date ON glucose_reading(date)")
            try db.execute(sql: """
                CREATE TABLE store_state (
                  id               INTEGER PRIMARY KEY,
                  created_at       DOUBLE NOT NULL,
                  legacy_import_at DOUBLE
                )
                """)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
            // A store whose seed had already run, which is the state on the only
            // device this migration will ever meet.
            try db.execute(
                sql: "INSERT INTO store_state (id, created_at, legacy_import_at) VALUES (0, ?, ?)",
                arguments: [Self.now.timeIntervalSince1970, Self.now.timeIntervalSince1970]
            )
            try db.execute(sql: """
                INSERT INTO glucose_reading
                  (sync_identifier, date, glucose_mg_dl, is_display_only, was_user_entered, sync_version, recorded_at)
                VALUES ('pre-existing', ?, 123, 0, 0, 1, ?)
                """,
                arguments: [Self.now.timeIntervalSince1970, Self.now.timeIntervalSince1970]
            )
        }
        try await v1.close()

        // Opening it runs v2. The reading has to survive, and the column has to go.
        let store = try GRDBGlucoseRecordStore(url: url, createdAt: Self.now + 60)
        #expect(try await store.lastReading()?.syncIdentifier == "pre-existing")
        #expect(try await store.lastReading()?.quantity.doubleValue(for: .milligramsPerDeciliter) == 123)

        let inspect = try DatabaseQueue(path: url.path)
        let columns = try await inspect.read { db in
            try db.columns(in: "store_state").map { $0.name }
        }
        #expect(columns.contains("legacy_import_at") == false)
        #expect(columns.contains("created_at"))
    }

    // MARK: - Ingest and dedup

    @Test func ingestReportsWhatWasNew() async throws {
        let store = try makeStore()
        let readings = GlucoseFixtures.series(endingAt: Self.now, count: 3)

        let result = try await store.ingest(readings, at: Self.now)
        #expect(result.inserted.count == 3)
        #expect(result.prunedByRetention == 0)
    }

    @Test func aBackfillReportsOnlyTheGenuinelyNewReadings() async throws {
        // The behaviour every side effect around this store depends on: a CGM
        // re-reports the last several hours on each connection, and an alert or a
        // HealthKit write per re-report would be wrong.
        let store = try makeStore()
        let firstConnection = GlucoseFixtures.series(endingAt: Self.now, count: 6)
        _ = try await store.ingest(firstConnection, at: Self.now)

        // Reconnecting 10 minutes later: the same six readings plus two new ones.
        let later = Self.now + 10.minutesToSeconds()
        let secondConnection = GlucoseFixtures.series(endingAt: later, count: 8)
        let result = try await store.ingest(secondConnection, at: later)

        #expect(result.inserted.count == 2)
        #expect(result.inserted.map { $0.syncIdentifier } == ["cgm-6", "cgm-7"])
        #expect(try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture).count == 8)
    }

    @Test func reIngestingTheSameBatchChangesNothing() async throws {
        let store = try makeStore()
        let readings = GlucoseFixtures.series(endingAt: Self.now, count: 4)

        _ = try await store.ingest(readings, at: Self.now)
        let before = try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture)
        let result = try await store.ingest(readings, at: Self.now + 60)
        let after = try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture)

        #expect(result.inserted.isEmpty)
        #expect(before.map { $0.syncIdentifier } == after.map { $0.syncIdentifier })
        #expect(before.map { $0.date } == after.map { $0.date })
    }

    @Test func theFirstVersionOfAnIdentifierWins() async throws {
        // A CGM does not revise a reading in place — a corrected value arrives
        // with a new identifier — so a second report of the same identifier is a
        // duplicate to ignore rather than an update to apply. This is the one
        // place the glucose store's policy is the opposite of the insulin
        // store's, where a pump's later report must win.
        let store = try makeStore()
        _ = try await store.ingest([GlucoseFixtures.reading(id: "cgm-1", at: Self.now, mgDl: 100)], at: Self.now)
        _ = try await store.ingest([GlucoseFixtures.reading(id: "cgm-1", at: Self.now, mgDl: 250)], at: Self.now + 60)

        let held = try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture)
        #expect(held.count == 1)
        let reading = try #require(held.first)
        #expect(reading.quantity.doubleValue(for: .milligramsPerDeciliter) == 100)
    }

    @Test func aDuplicateWithinOneBatchIsCollapsed() async throws {
        let store = try makeStore()
        let result = try await store.ingest(
            [
                GlucoseFixtures.reading(id: "cgm-1", at: Self.now, mgDl: 100),
                GlucoseFixtures.reading(id: "cgm-1", at: Self.now, mgDl: 100)
            ],
            at: Self.now
        )
        #expect(result.inserted.count == 1)
        #expect(try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture).count == 1)
    }

    @Test func anEmptyBatchIsHarmless() async throws {
        let store = try makeStore()
        let result = try await store.ingest([], at: Self.now)
        #expect(result.inserted.isEmpty)
        #expect(result.prunedByRetention == 0)
    }

    // MARK: - Round trip

    @Test func everyFieldRoundTrips() async throws {
        let store = try makeStore()
        let device = HKDevice(
            name: "Dexcom G7",
            manufacturer: "Dexcom",
            model: "G7",
            hardwareVersion: "1.0",
            firmwareVersion: "2.0",
            softwareVersion: "3.0",
            localIdentifier: "local-1",
            udiDeviceIdentifier: "udi-1"
        )
        let sample = GlucoseFixtures.reading(
            id: "cgm-1",
            at: Self.now,
            mgDl: 137.5,
            trend: .upUp,
            trendRateMgDlPerMinute: 2.5,
            condition: .aboveRange,
            isDisplayOnly: true,
            wasUserEntered: true,
            device: device
        )

        _ = try await store.ingest([sample], at: Self.now)
        let restored = try #require(try await store.lastReading())

        #expect(restored.syncIdentifier == sample.syncIdentifier)
        #expect(restored.date == sample.date)
        #expect(restored.quantity.doubleValue(for: .milligramsPerDeciliter) == 137.5)
        #expect(restored.trend == .upUp)
        #expect(restored.trendRate?.doubleValue(for: .milligramsPerDeciliterPerMinute) == 2.5)
        #expect(restored.condition == .aboveRange)
        #expect(restored.isDisplayOnly == true)
        #expect(restored.wasUserEntered == true)
        #expect(restored.syncVersion == sample.syncVersion)
        // The device is a JSON blob nothing queries, so this is the only thing
        // that would catch it silently becoming NULL.
        #expect(restored.device?.model == "G7")
        #expect(restored.device?.udiDeviceIdentifier == "udi-1")
    }

    @Test func aReadingWithNoOptionalFieldsRoundTrips() async throws {
        let store = try makeStore()
        let sample = GlucoseFixtures.reading(
            id: "cgm-1", at: Self.now, mgDl: 90,
            trend: nil, trendRateMgDlPerMinute: nil, condition: nil, device: nil
        )

        _ = try await store.ingest([sample], at: Self.now)
        let restored = try #require(try await store.lastReading())
        #expect(restored.trend == nil)
        #expect(restored.trendRate == nil)
        #expect(restored.condition == nil)
        #expect(restored.device == nil)
    }

    // MARK: - Reads

    @Test func readingsBetweenIsInclusiveAtBothEnds() async throws {
        // `AddedGlucoseDataFrame.createDataFrame` passes `at` as `endDate` and
        // then checks that the newest reading it got back is within one time step
        // of it, so a half-open right edge would drop the reading the data frame
        // is anchored on.
        let store = try makeStore()
        let readings = GlucoseFixtures.series(endingAt: Self.now, count: 5) // now-20m ... now
        _ = try await store.ingest(readings, at: Self.now)

        let window = try await store.readingsBetween(
            startDate: Self.now - 20.minutesToSeconds(),
            endDate: Self.now
        )
        #expect(window.count == 5)

        let inner = try await store.readingsBetween(
            startDate: Self.now - 15.minutesToSeconds(),
            endDate: Self.now - 5.minutesToSeconds()
        )
        #expect(inner.map { $0.syncIdentifier } == ["cgm-1", "cgm-2", "cgm-3"])
    }

    @Test func readingsComeBackOldestFirst() async throws {
        let store = try makeStore()
        // Ingested newest-first, so a store that just returned insertion order
        // would fail this.
        let readings = GlucoseFixtures.series(endingAt: Self.now, count: 6).reversed()
        _ = try await store.ingest(Array(readings), at: Self.now)

        let held = try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture)
        #expect(held.map { $0.date } == held.map { $0.date }.sorted())
        #expect(held.first?.syncIdentifier == "cgm-0")
        #expect(held.last?.syncIdentifier == "cgm-5")
    }

    @Test func lastReadingIsTheNewestByDateNotByIngestOrder() async throws {
        // A backfill arrives after the reading it precedes. `lastReading()` feeds
        // the loop's staleness check, so answering with the most recently
        // *ingested* row would make old glucose look fresh.
        let store = try makeStore()
        _ = try await store.ingest(
            [GlucoseFixtures.reading(id: "recent", at: Self.now, mgDl: 120)],
            at: Self.now
        )
        _ = try await store.ingest(
            [GlucoseFixtures.reading(id: "backfilled", at: Self.now - 2.hoursToSeconds(), mgDl: 80)],
            at: Self.now + 60
        )

        let last = try #require(try await store.lastReading())
        #expect(last.syncIdentifier == "recent")
        #expect(last.date == Self.now)
    }

    @Test func anEmptyWindowIsEmptyRatherThanEverything() async throws {
        let store = try makeStore()
        _ = try await store.ingest(GlucoseFixtures.series(endingAt: Self.now, count: 6), at: Self.now)

        let future = try await store.readingsBetween(
            startDate: Self.now + 1.hoursToSeconds(),
            endDate: Self.now + 2.hoursToSeconds()
        )
        #expect(future.isEmpty)
    }

    // MARK: - Retention

    @Test func retentionKeeps90DaysAndDropsWhatIsOlder() async throws {
        let store = try makeStore(createdAt: Self.now - 200.0.daysToSeconds())
        let cutoff = Self.now - GlucoseRecordStorePolicy.retention

        let readings = [
            GlucoseFixtures.reading(id: "ancient", at: cutoff - 1.hoursToSeconds(), mgDl: 100),
            GlucoseFixtures.reading(id: "just-inside", at: cutoff + 1.hoursToSeconds(), mgDl: 110),
            GlucoseFixtures.reading(id: "recent", at: Self.now - 5.minutesToSeconds(), mgDl: 120)
        ]
        let result = try await store.ingest(readings, at: Self.now)

        // Ingested and then immediately pruned in the same transaction, which is
        // why `inserted` counts three: it reports what the batch contributed, not
        // what survived retention.
        #expect(result.inserted.count == 3)
        #expect(result.prunedByRetention == 1)

        let held = try await store.readingsBetween(startDate: .distantPast, endDate: .distantFuture)
        #expect(held.map { $0.syncIdentifier } == ["just-inside", "recent"])
    }

    @Test func retentionMovesWithTheIngestInstantNotTheWallClock() async throws {
        let store = try makeStore(createdAt: Self.now - 200.0.daysToSeconds())
        let reading = GlucoseFixtures.reading(id: "cgm-1", at: Self.now, mgDl: 100)
        _ = try await store.ingest([reading], at: Self.now)
        #expect(try await store.lastReading() != nil)

        // 91 days later the same reading is past the horizon, and the next ingest
        // is what notices.
        let muchLater = Self.now + 91.0.daysToSeconds()
        let result = try await store.ingest(
            [GlucoseFixtures.reading(id: "cgm-2", at: muchLater, mgDl: 100)],
            at: muchLater
        )
        #expect(result.prunedByRetention == 1)
        #expect(try await store.lastReading()?.syncIdentifier == "cgm-2")
    }

    @Test func aRetentionSweepWithNothingToDoPrunesNothing() async throws {
        let store = try makeStore()
        _ = try await store.ingest(GlucoseFixtures.series(endingAt: Self.now, count: 6), at: Self.now)
        let result = try await store.ingest(
            [GlucoseFixtures.reading(id: "next", at: Self.now + 5.minutesToSeconds(), mgDl: 105)],
            at: Self.now + 5.minutesToSeconds()
        )
        #expect(result.prunedByRetention == 0)
    }

    // MARK: - Volume

    @Test func ninetyDaysOfReadingsBehave() async throws {
        // ~26,000 rows, which is what the store signs up for. Worth one test
        // because every read here is bounded by a window and this is the only
        // place that would notice if one of them were not.
        let store = try makeStore(createdAt: Self.now - 90.0.daysToSeconds())
        let count = 90 * 24 * 12
        let readings = GlucoseFixtures.series(endingAt: Self.now, count: count)
        let result = try await store.ingest(readings, at: Self.now)
        #expect(result.inserted.count == count)

        let lastDay = try await store.readingsBetween(
            startDate: Self.now - GlucoseRecordStorePolicy.chartWindow,
            endDate: Self.now
        )
        #expect(lastDay.count == 24 * 12 + 1) // inclusive at both ends
        #expect(try await store.lastReading()?.date == Self.now)
    }
}
