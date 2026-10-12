//
//  GRDBGlucoseRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/5/26.
//
//  The GRDB implementation of `GlucoseRecordStore`.
//
//  Structured to match `GRDBInsulinRecordStore` so moving between the two is
//  mechanical: private row struct, raw-SQL schema, epoch-second dates, its own
//  directory carrying `NSFileProtectionNone`. Where it is simpler than the
//  insulin store, it is simpler because a CGM reading is simpler — there is no
//  mutable frontier, no revocation, and no inference over gaps — not because
//  glucose matters less.
//
//  Epoch seconds rather than GRDB's default ISO-8601 text for dates, for the same
//  reason as the insulin store: every read here is a numeric range comparison,
//  and text dates make those compare lexicographically in ways that don't error.
//

import Foundation
import GRDB
import HealthKit
import LoopKit

actor GRDBGlucoseRecordStore: GlucoseRecordStore {

    // MARK: - The row (private — never crosses the protocol boundary)

    private struct GlucoseReadingRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "glucose_reading"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var syncIdentifier: String
        var date: Double
        var glucoseMgDl: Double
        var condition: String?
        var trend: Int?
        var trendRateMgDlPerMinute: Double?
        var isDisplayOnly: Bool
        var wasUserEntered: Bool
        var syncVersion: Int
        /// The reporting device as JSON. Nothing queries it — it is here so a
        /// reading round-trips losslessly, the same role `pump_event.raw` plays.
        var device: Data?
        var recordedAt: Double

        init(sample: NewGlucoseSample, at: Date) {
            self.syncIdentifier = sample.syncIdentifier
            self.date = sample.date.timeIntervalSince1970
            self.glucoseMgDl = sample.quantity.doubleValue(for: .milligramsPerDeciliter)
            self.condition = sample.condition?.rawValue
            self.trend = sample.trend?.rawValue
            self.trendRateMgDlPerMinute = sample.trendRate?.doubleValue(for: .milligramsPerDeciliterPerMinute)
            self.isDisplayOnly = sample.isDisplayOnly
            self.wasUserEntered = sample.wasUserEntered
            self.syncVersion = sample.syncVersion
            self.device = sample.device.flatMap { try? JSONEncoder().encode(DeviceRecord(device: $0)) }
            self.recordedAt = at.timeIntervalSince1970
        }

        func toDomain() -> NewGlucoseSample {
            return NewGlucoseSample(
                date: Date(timeIntervalSince1970: date),
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: glucoseMgDl),
                condition: condition.flatMap { GlucoseCondition(rawValue: $0) },
                trend: trend.flatMap { GlucoseTrend(rawValue: $0) },
                trendRate: trendRateMgDlPerMinute.map {
                    HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
                },
                isDisplayOnly: isDisplayOnly,
                wasUserEntered: wasUserEntered,
                syncIdentifier: syncIdentifier,
                syncVersion: syncVersion,
                device: device.flatMap { try? JSONDecoder().decode(DeviceRecord.self, from: $0) }?.device()
            )
        }
    }

    /// `HKDevice` is a class with no `Codable` conformance, so it travels as this.
    /// Same field set as the container the `glucose.json` path used, so a legacy
    /// import preserves what the old log held.
    private struct DeviceRecord: Codable {
        let name: String?
        let manufacturer: String?
        let model: String?
        let hardwareVersion: String?
        let firmwareVersion: String?
        let softwareVersion: String?
        let localIdentifier: String?
        let udiDeviceIdentifier: String?

        init(device: HKDevice) {
            self.name = device.name
            self.manufacturer = device.manufacturer
            self.model = device.model
            self.hardwareVersion = device.hardwareVersion
            self.firmwareVersion = device.firmwareVersion
            self.softwareVersion = device.softwareVersion
            self.localIdentifier = device.localIdentifier
            self.udiDeviceIdentifier = device.udiDeviceIdentifier
        }

        func device() -> HKDevice {
            return HKDevice(
                name: name,
                manufacturer: manufacturer,
                model: model,
                hardwareVersion: hardwareVersion,
                firmwareVersion: firmwareVersion,
                softwareVersion: softwareVersion,
                localIdentifier: localIdentifier,
                udiDeviceIdentifier: udiDeviceIdentifier
            )
        }
    }

    /// The one-row singleton table, in the same database so it shares the
    /// transaction and the file-protection class.
    private struct StoreStateRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "store_state"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var id: Int64
        /// When the store was created, which bounds how much history it could
        /// hold. Diagnostics only — unlike the insulin store's
        /// `history_complete_since`, nothing clamps off it, because nothing about
        /// glucose is inferred across a gap.
        var createdAt: Double
    }

    // MARK: - State

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    /// - Parameter createdAt: the store's creation instant. Injected rather than
    ///   read from the clock so tests never depend on the wall clock.
    init(url: URL, createdAt: Date) throws {
        // Per GRDB's guidance each database lives in its OWN directory, so the
        // main file, the journal sidecar, and SQLite's temp files stay together.
        // The directory carries NSFileProtectionNone and the files SQLite creates
        // inside it inherit it (see GRDBInsulinRecordStore §8 for the longer
        // version).
        //
        // This is the store where that matters most: the app is woken by CGM
        // Bluetooth before first unlock, and this is the store that wake path
        // writes to. A protected database fails to open exactly when a new
        // reading arrives.
        do {
            try Self.makeUnprotectedDirectory(at: url.deletingLastPathComponent())
        } catch {
            throw GlucoseRecordStoreError.couldNotOpen("could not create the store directory: \(error)")
        }

        do {
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: Configuration())
        } catch {
            throw GlucoseRecordStoreError.couldNotOpen("could not open \(url.lastPathComponent): \(error)")
        }

        try Self.prepare(dbQueue, createdAt: createdAt)
    }

    /// In-memory store for tests, so nothing here touches a file system.
    init(inMemoryCreatedAt createdAt: Date) throws {
        do {
            self.dbQueue = try DatabaseQueue()
        } catch {
            throw GlucoseRecordStoreError.couldNotOpen("could not open an in-memory database: \(error)")
        }
        try Self.prepare(dbQueue, createdAt: createdAt)
    }

    private static func prepare(_ dbQueue: DatabaseQueue, createdAt: Date) throws {
        do {
            try migrator().migrate(dbQueue)
            try dbQueue.write { db in
                // `INSERT OR IGNORE`, so relaunching keeps the original instant
                // rather than rewriting `created_at` on every launch.
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO store_state (id, created_at)
                        VALUES (0, ?)
                        """,
                    arguments: [createdAt.timeIntervalSince1970]
                )
            }
        } catch {
            throw GlucoseRecordStoreError.couldNotOpen("could not migrate the store: \(error)")
        }
    }

    // MARK: - File protection

    /// `attributes` only applies when the directory is actually created, so a tree
    /// left over from a prior install keeps whatever protection it had. Re-assert
    /// every launch.
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

    /// `Documents/GlucoseRecordStore/glucose_readings.sqlite`. Its own directory,
    /// per the rule above.
    static func defaultURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return documents
            .appendingPathComponent("GlucoseRecordStore", isDirectory: true)
            .appendingPathComponent("glucose_readings.sqlite", isDirectory: false)
    }

    // MARK: - Migrations

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE glucose_reading (
                  sync_identifier             TEXT PRIMARY KEY,  -- the CGM's own; the dedup key
                  date                        DOUBLE NOT NULL,   -- epoch seconds; when it was measured
                  glucose_mg_dl               DOUBLE NOT NULL,
                  condition                   TEXT,              -- below/above the sensor's range
                  trend                       INTEGER,           -- GlucoseTrend raw value
                  trend_rate_mg_dl_per_minute DOUBLE,
                  is_display_only             INTEGER NOT NULL,  -- shifted for display after a calibration
                  was_user_entered            INTEGER NOT NULL,
                  sync_version                INTEGER NOT NULL,
                  device                      BLOB,              -- reporting device as JSON, diagnostics only
                  recorded_at                 DOUBLE NOT NULL    -- when we ingested it
                )
                """)

            // The only index the reads need: every query is a range or an
            // ORDER BY over `date`. No partial-index dance, because there is no
            // soft delete to filter — a CGM reading is never revoked.
            try db.execute(sql: "CREATE INDEX idx_glucose_date ON glucose_reading(date)")

            try db.execute(sql: """
                CREATE TABLE store_state (
                  id               INTEGER PRIMARY KEY,  -- always 0
                  created_at       DOUBLE NOT NULL,
                  legacy_import_at DOUBLE                -- NULL until the glucose.json seed has run
                )
                """)
        }

        // The `glucose.json` import ran once, by hand, and then the import path was
        // deleted — so the column that recorded whether it had run has nothing left
        // to answer.
        //
        // Dropped in a v2 rather than edited out of v1 because v1 has already been
        // applied on a real device: editing it would leave that database carrying a
        // column the schema no longer declares, while a fresh install would not
        // have one. This way both converge.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE store_state DROP COLUMN legacy_import_at")
        }

        return migrator
    }

    // MARK: - Ingest

    func ingest(_ samples: [NewGlucoseSample], at: Date) async throws -> GlucoseIngestResult {
        // Mapping happens out here, before the transaction, so nothing inside it
        // touches a LoopKit or HealthKit reference type.
        let rows = Self.collapse(samples, at: at)

        do {
            return try await dbQueue.write { db in
                var inserted: [NewGlucoseSample] = []
                for row in rows {
                    // Asked explicitly rather than inferred from `changesCount`,
                    // because `inserted` is what drives the alert, the HealthKit
                    // write, and the watch update — and a CGM backfills the last
                    // several hours on every connection, so most of a batch is
                    // usually already held.
                    let exists = try Bool.fetchOne(
                        db,
                        sql: "SELECT 1 FROM glucose_reading WHERE sync_identifier = ?",
                        arguments: [row.syncIdentifier]
                    ) ?? false
                    guard !exists else { continue }

                    // `.ignore` as well as the check above: the check is for the
                    // caller's benefit, the conflict clause is what guarantees a
                    // duplicate can never fail the whole batch.
                    try row.insert(db, onConflict: .ignore)
                    inserted.append(row.toDomain())
                }

                let pruned = try Self.runRetention(db, at: at)
                return GlucoseIngestResult(inserted: inserted, prunedByRetention: pruned)
            }
        } catch {
            throw GlucoseRecordStoreError.writeFailed("ingest failed: \(error)")
        }
    }

    /// Collapses a batch to at most one row per `syncIdentifier`, keeping the
    /// first occurrence — the same first-one-wins rule the insert uses, applied
    /// within the batch so the two cannot disagree.
    private static func collapse(_ samples: [NewGlucoseSample], at: Date) -> [GlucoseReadingRow] {
        var seen = Set<String>()
        return samples.compactMap { sample in
            guard seen.insert(sample.syncIdentifier).inserted else { return nil }
            return GlucoseReadingRow(sample: sample, at: at)
        }
    }

    // MARK: - Retention

    /// Hard-deletes readings past the retention horizon.
    ///
    /// No exemptions, unlike the insulin store's retained suspend/resume markers:
    /// nothing about a glucose reading is state that outlives the reading, so
    /// there is nothing a pruned row could still have been answering.
    private static func runRetention(_ db: Database, at: Date) throws -> Int {
        let cutoff = at.timeIntervalSince1970 - GlucoseRecordStorePolicy.retention
        try db.execute(sql: "DELETE FROM glucose_reading WHERE date < ?", arguments: [cutoff])
        return db.changesCount
    }

    // MARK: - Reads

    func lastReading() async throws -> NewGlucoseSample? {
        do {
            return try await dbQueue.read { db in
                try GlucoseReadingRow.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM glucose_reading
                        ORDER BY date DESC, sync_identifier DESC
                        LIMIT 1
                        """
                )?.toDomain()
            }
        } catch {
            throw GlucoseRecordStoreError.readFailed("lastReading failed: \(error)")
        }
    }

    func readingsBetween(startDate: Date, endDate: Date) async throws -> [NewGlucoseSample] {
        do {
            return try await dbQueue.read { db in
                // Both ends inclusive, matching the JSON path. `sync_identifier`
                // breaks ties in the sort so the order is total: two readings can
                // share a timestamp after a sensor restart, and an interpolating
                // caller must not see them in a different order on each read.
                try GlucoseReadingRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM glucose_reading
                        WHERE date >= ? AND date <= ?
                        ORDER BY date, sync_identifier
                        """,
                    arguments: [startDate.timeIntervalSince1970, endDate.timeIntervalSince1970]
                ).map { $0.toDomain() }
            }
        } catch {
            throw GlucoseRecordStoreError.readFailed("readingsBetween failed: \(error)")
        }
    }

}
