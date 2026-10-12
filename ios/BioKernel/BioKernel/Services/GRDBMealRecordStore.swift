//
//  GRDBMealRecordStore.swift
//  BioKernel
//
//  The GRDB implementation of `MealRecordStore`.
//
//  Structured to match `GRDBAlertRecordStore` and `GRDBGlucoseRecordStore` so
//  moving between them is mechanical: private row struct, raw-SQL schema,
//  epoch-second dates, its own directory carrying `NSFileProtectionNone`.
//
//  Epoch seconds rather than GRDB's default ISO-8601 text, for the same reason
//  as the other stores: retention and every window read are numeric range
//  comparisons, and text dates make those compare lexicographically in ways
//  that don't error.
//
//  `NSFileProtectionNone` here is about *ingestion*, not the UI. Ingestion runs
//  at the top of the loop, and the loop runs on CGM Bluetooth wakes that can
//  happen before first unlock — a protected database would fail to open on
//  exactly the ticks that are copying announcements out of a two-day window.
//

import Foundation
import GRDB

actor GRDBMealRecordStore: MealRecordStore {

    // MARK: - The row (private — never crosses the protocol boundary)

    private struct MealRow: Codable, FetchableRecord {
        static let databaseTableName = "meal"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var bundleIdentifier: String
        var mealId: String
        var updatedAt: Double
        var startTime: Double
        var mealDescription: String
        var dosingKey: String
        var isCancelled: Bool
        var doseUnits: Double?
        var dosedAt: Double?

        func toDomain() -> StoredMeal {
            return StoredMeal(
                bundleIdentifier: bundleIdentifier,
                mealId: mealId,
                updatedAt: Date(timeIntervalSince1970: updatedAt),
                startTime: Date(timeIntervalSince1970: startTime),
                mealDescription: mealDescription,
                dosingKey: dosingKey,
                isCancelled: isCancelled,
                doseUnits: doseUnits,
                dosedAt: dosedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    // MARK: - State

    private let dbQueue: DatabaseQueue
    private let log = DiagnosticLog(category: "MealRecordStore")

    // MARK: - Init

    init(url: URL) throws {
        // Per GRDB's guidance each database lives in its OWN directory, so the
        // main file, the journal sidecar, and SQLite's temp files stay together
        // and inherit the directory's protection class.
        do {
            try Self.makeUnprotectedDirectory(at: url.deletingLastPathComponent())
        } catch {
            throw MealRecordStoreError.couldNotOpen("could not create the store directory: \(error)")
        }

        do {
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: Configuration())
        } catch {
            throw MealRecordStoreError.couldNotOpen("could not open \(url.lastPathComponent): \(error)")
        }

        try Self.prepare(dbQueue)
    }

    /// In-memory store for tests, so nothing here touches a file system.
    init(inMemory: Void) throws {
        do {
            self.dbQueue = try DatabaseQueue()
        } catch {
            throw MealRecordStoreError.couldNotOpen("could not open an in-memory database: \(error)")
        }
        try Self.prepare(dbQueue)
    }

    private static func prepare(_ dbQueue: DatabaseQueue) throws {
        do {
            try migrator().migrate(dbQueue)
        } catch {
            throw MealRecordStoreError.couldNotOpen("could not migrate the store: \(error)")
        }
    }

    // MARK: - File protection

    /// `attributes` only applies when the directory is actually created, so a
    /// tree left over from a prior install keeps whatever protection it had.
    /// Re-assert every launch.
    private static func makeUnprotectedDirectory(at url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.none]
        )
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.none],
            ofItemAtPath: url.path
        )
    }

    /// `Documents/MealRecordStore/meals.sqlite`. Its own directory, per the
    /// rule above.
    static func defaultURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return documents
            .appendingPathComponent("MealRecordStore", isDirectory: true)
            .appendingPathComponent("meals.sqlite", isDirectory: false)
    }

    // MARK: - Migrations

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // There is nothing to import. GlucOS had no meal abstraction before
            // this feature, and the interface files it read instead retain two
            // days — so the store starts empty and fills from the next loop
            // tick onward, which is at most a couple of days of history nobody
            // had a way to see anyway.
            try db.execute(sql: """
                CREATE TABLE meal (
                  bundle_identifier TEXT NOT NULL,    -- the app that announced it
                  meal_id           TEXT NOT NULL,    -- unique only within that app
                  updated_at        DOUBLE NOT NULL,  -- epoch seconds; newest revision wins
                  start_time        DOUBLE NOT NULL,  -- epoch seconds
                  meal_description  TEXT NOT NULL,
                  dosing_key        TEXT NOT NULL,    -- normalized description
                  is_cancelled      BOOLEAN NOT NULL DEFAULT 0,
                  dose_units        DOUBLE,           -- NULL until the user doses
                  dosed_at          DOUBLE,
                  PRIMARY KEY (bundle_identifier, meal_id)
                )
                """)

            // The Meals view and every window read are ranges over start_time.
            try db.execute(sql: "CREATE INDEX idx_meal_start_time ON meal(start_time)")

            // The run-to-run lookup: same key, dosed, most recent before a
            // given instant. Leading on the key with start_time second means
            // that whole query is one index seek plus a backward scan of one
            // meal's own history.
            try db.execute(sql: "CREATE INDEX idx_meal_dosing_key ON meal(dosing_key, start_time)")
        }

        return migrator
    }

    // MARK: - Ingestion

    @discardableResult
    func ingest(_ announcements: [MealAnnouncement], at: Date) async throws -> Int {
        guard !announcements.isEmpty else {
            // Still worth a retention sweep on an empty ingest: the files go
            // quiet whenever the user stops announcing, and rows shouldn't
            // outlive the horizon just because nothing new arrived.
            try await prune(at: at)
            return 0
        }

        do {
            let (changed, pruned) = try await dbQueue.write { db -> (Int, Int) in
                var changed = 0
                for announcement in announcements {
                    // A cancellation carries no description worth storing, so
                    // the row keeps whatever it had and only flips the flag. A
                    // cancellation for a meal we never saw still inserts, with
                    // an empty description: it is the newest word on that meal,
                    // and recording it is what stops a later re-read of an
                    // older revision from resurrecting it.
                    let description = announcement.mealDescription ?? ""
                    let cancelled = announcement.isCancellation

                    try db.execute(
                        sql: """
                            INSERT INTO meal
                              (bundle_identifier, meal_id, updated_at, start_time,
                               meal_description, dosing_key, is_cancelled, dose_units, dosed_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                            ON CONFLICT (bundle_identifier, meal_id) DO UPDATE SET
                              updated_at       = excluded.updated_at,
                              start_time       = excluded.start_time,
                              -- A cancellation keeps the description it is
                              -- cancelling. Blanking it would lose what the
                              -- meal was, which is the one thing a row with a
                              -- real dose on it still needs to be able to say.
                              meal_description = CASE WHEN excluded.is_cancelled
                                                      THEN meal.meal_description
                                                      ELSE excluded.meal_description END,
                              dosing_key       = CASE WHEN excluded.is_cancelled
                                                      THEN meal.dosing_key
                                                      ELSE excluded.dosing_key END,
                              is_cancelled     = excluded.is_cancelled
                              -- dose_units and dosed_at are deliberately absent:
                              -- a revised description does not unmake an
                              -- injection.
                            WHERE excluded.updated_at > meal.updated_at
                            """,
                        arguments: [
                            announcement.bundleIdentifier,
                            announcement.mealId,
                            announcement.updatedAt.timeIntervalSince1970,
                            announcement.startTime.timeIntervalSince1970,
                            description,
                            cancelled ? "" : MealRecordStorePolicy.dosingKey(for: description),
                            cancelled
                        ]
                    )
                    changed += db.changesCount
                }
                return (changed, try Self.runRetention(db, at: at))
            }
            if pruned > 0 {
                log.default("retention pruned %d meal(s)", pruned)
            }
            return changed
        } catch {
            throw MealRecordStoreError.writeFailed("could not ingest meal announcements: \(error)")
        }
    }

    func recordDose(bundleIdentifier: String, mealId: String, units: Double, at: Date) async throws {
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        UPDATE meal SET dose_units = ?, dosed_at = ?
                        WHERE bundle_identifier = ? AND meal_id = ?
                        """,
                    arguments: [units, at.timeIntervalSince1970, bundleIdentifier, mealId]
                )
            }
        } catch {
            throw MealRecordStoreError.writeFailed("could not record a meal dose: \(error)")
        }
    }

    // MARK: - Retention

    private func prune(at: Date) async throws {
        do {
            let pruned = try await dbQueue.write { db in try Self.runRetention(db, at: at) }
            if pruned > 0 {
                log.default("retention pruned %d meal(s)", pruned)
            }
        } catch {
            throw MealRecordStoreError.writeFailed("could not prune meals: \(error)")
        }
    }

    /// Hard-deletes meals whose start is past the horizon.
    ///
    /// No exemptions. Unlike the alert store there is no such thing as an
    /// outstanding meal — a 90-day-old announcement is history whether it was
    /// dosed, cancelled, or neither.
    private static func runRetention(_ db: Database, at: Date) throws -> Int {
        let cutoff = at.timeIntervalSince1970 - MealRecordStorePolicy.retention
        try db.execute(sql: "DELETE FROM meal WHERE start_time < ?", arguments: [cutoff])
        return db.changesCount
    }

    // MARK: - Reads

    func meals(from: Date, to: Date) async throws -> [StoredMeal] {
        do {
            return try await dbQueue.read { db in
                try MealRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM meal
                        WHERE start_time >= ? AND start_time <= ? AND is_cancelled = 0
                        ORDER BY start_time
                        """,
                    arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]
                ).map { $0.toDomain() }
            }
        } catch {
            throw MealRecordStoreError.readFailed("meals(from:to:) failed: \(error)")
        }
    }

    func meal(bundleIdentifier: String, mealId: String) async throws -> StoredMeal? {
        do {
            return try await dbQueue.read { db in
                try MealRow.fetchOne(
                    db,
                    sql: "SELECT * FROM meal WHERE bundle_identifier = ? AND meal_id = ?",
                    arguments: [bundleIdentifier, mealId]
                )?.toDomain()
            }
        } catch {
            throw MealRecordStoreError.readFailed("meal(bundleIdentifier:mealId:) failed: \(error)")
        }
    }

    func lastDosedMeal(dosingKey: String, before: Date) async throws -> StoredMeal? {
        // An empty key is what a cancellation stores, and it is not an identity
        // — every cancelled meal shares it. Matching on it would hand back an
        // arbitrary cancelled row as a reference.
        guard !dosingKey.isEmpty else { return nil }
        do {
            return try await dbQueue.read { db in
                try MealRow.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM meal
                        WHERE dosing_key = ?
                          AND start_time < ?
                          AND dose_units IS NOT NULL
                          AND is_cancelled = 0
                        ORDER BY start_time DESC
                        LIMIT 1
                        """,
                    arguments: [dosingKey, before.timeIntervalSince1970]
                )?.toDomain()
            }
        } catch {
            throw MealRecordStoreError.readFailed("lastDosedMeal failed: \(error)")
        }
    }
}
