//
//  GRDBAlertRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/16/26.
//
//  The GRDB implementation of `AlertRecordStore`.
//
//  Structured to match `GRDBGlucoseRecordStore` so moving between them is
//  mechanical: private row struct, raw-SQL schema, epoch-second dates, its own
//  directory carrying `NSFileProtectionNone`.
//
//  Epoch seconds rather than GRDB's default ISO-8601 text, for the same reason
//  as the other two stores: retention is a numeric range comparison, and text
//  dates make those compare lexicographically in ways that don't error.
//
//  The alert itself is stored as a JSON blob rather than shredded into columns.
//  `Alert` is a LoopKit type with two enums carrying associated values
//  (`Trigger`, `Sound`) and an open-ended `Metadata` dictionary, and nothing
//  queries into any of it — the five things we filter on are lifted out as
//  columns and the rest round-trips. Same role `pump_event.raw` and
//  `glucose_reading.device` play.
//

import Foundation
import GRDB
import LoopKit

actor GRDBAlertRecordStore: AlertRecordStore {

    // MARK: - The row (private — never crosses the protocol boundary)

    private struct AlertRow: Codable, FetchableRecord {
        static let databaseTableName = "alert"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        /// Insertion order, and the sort key for "most recent". Assigned by
        /// SQLite; nothing outside this type ever sees it.
        var id: Int64
        var managerIdentifier: String
        var alertIdentifier: String
        var issuedAt: Double
        var retractedAt: Double?
        var acknowledgedAt: Double?
        /// The whole `Alert` as JSON.
        var alert: Data

        /// nil when the blob will not decode.
        ///
        /// A row we cannot read is dropped rather than allowed to fail the query
        /// around it: one alert written by a build whose `Alert` shape has since
        /// changed must not cost us the alerts either side of it. The caller
        /// logs the count.
        func toDomain() -> PersistedAlert? {
            guard let decoded = try? JSONDecoder().decode(Alert.self, from: alert) else { return nil }
            return PersistedAlert(
                alert: decoded,
                issuedDate: Date(timeIntervalSince1970: issuedAt),
                retractedDate: retractedAt.map { Date(timeIntervalSince1970: $0) },
                acknowledgedDate: acknowledgedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
    }

    // MARK: - State

    private let dbQueue: DatabaseQueue
    private let log = DiagnosticLog(category: "AlertRecordStore")

    // MARK: - Init

    init(url: URL) throws {
        // Per GRDB's guidance each database lives in its OWN directory, so the
        // main file, the journal sidecar, and SQLite's temp files stay together
        // and inherit the directory's protection class.
        //
        // `NSFileProtectionNone` matters here for the same reason it does in the
        // glucose store, if less often: the app can be woken by pump or CGM
        // Bluetooth before first unlock, and an alert issued on that wake path
        // has to be writable. A protected database fails to open exactly when
        // something is trying to tell the user their pump has a problem.
        do {
            try Self.makeUnprotectedDirectory(at: url.deletingLastPathComponent())
        } catch {
            throw AlertRecordStoreError.couldNotOpen("could not create the store directory: \(error)")
        }

        do {
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: Configuration())
        } catch {
            throw AlertRecordStoreError.couldNotOpen("could not open \(url.lastPathComponent): \(error)")
        }

        try Self.prepare(dbQueue)
    }

    /// In-memory store for tests, so nothing here touches a file system.
    init(inMemory: Void) throws {
        do {
            self.dbQueue = try DatabaseQueue()
        } catch {
            throw AlertRecordStoreError.couldNotOpen("could not open an in-memory database: \(error)")
        }
        try Self.prepare(dbQueue)
    }

    private static func prepare(_ dbQueue: DatabaseQueue) throws {
        do {
            try migrator().migrate(dbQueue)
        } catch {
            throw AlertRecordStoreError.couldNotOpen("could not migrate the store: \(error)")
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

    /// `Documents/AlertRecordStore/alerts.sqlite`. Its own directory, per the
    /// rule above.
    static func defaultURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return documents
            .appendingPathComponent("AlertRecordStore", isDirectory: true)
            .appendingPathComponent("alerts.sqlite", isDirectory: false)
    }

    // MARK: - Migrations

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // No import of `alerts.json`. Unlike the insulin and glucose logs,
            // nothing here is history anyone will ask about later: an alert is a
            // device notification, the only cross-restart consumers are
            // LoopKit's `PersistedAlertStore` lookups, and the vendored pump and
            // CGM kits never call them. The cost of starting empty is at worst
            // one duplicate alert after the upgrade; the cost of an import path
            // is a column and a code path that then has to be migrated away
            // again, which is what `glucose_reading`'s v2 exists to undo.
            try db.execute(sql: """
                CREATE TABLE alert (
                  id                 INTEGER PRIMARY KEY AUTOINCREMENT,  -- insertion order
                  manager_identifier TEXT NOT NULL,   -- Alert.Identifier, split so we can index it
                  alert_identifier   TEXT NOT NULL,
                  issued_at          DOUBLE NOT NULL, -- epoch seconds
                  retracted_at       DOUBLE,          -- NULL while the alert is live
                  acknowledged_at    DOUBLE,          -- never written today; see AlertRecordStore
                  alert              BLOB NOT NULL    -- the whole LoopKit Alert as JSON
                )
                """)

            // Covers `issuedAlertExists` on both columns and the two lookups on
            // the leading one. The live-alert predicates are left to a scan:
            // retention bounds this table to 90 days of a handful of alerts a
            // day, so there is nothing here for a second index to save.
            try db.execute(sql: "CREATE INDEX idx_alert_identifier ON alert(manager_identifier, alert_identifier)")
        }

        return migrator
    }

    // MARK: - Writes

    func issue(_ alert: Alert, at: Date) async throws {
        try await append(alert, issuedAt: at, retractedAt: nil, at: at)
    }

    func recordRetracted(_ alert: Alert, at: Date) async throws {
        // Same instant for both, which is what makes this "already over" rather
        // than "live since `at`".
        try await append(alert, issuedAt: at, retractedAt: at, at: at)
    }

    private func append(_ alert: Alert, issuedAt: Date, retractedAt: Date?, at: Date) async throws {
        // Encoding happens out here, before the transaction, so nothing inside
        // it touches a LoopKit reference type.
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(alert)
        } catch {
            throw AlertRecordStoreError.writeFailed("could not encode an alert: \(error)")
        }
        let identifier = alert.identifier

        do {
            let pruned = try await dbQueue.write { db -> Int in
                try db.execute(
                    sql: """
                        INSERT INTO alert
                          (manager_identifier, alert_identifier, issued_at, retracted_at, acknowledged_at, alert)
                        VALUES (?, ?, ?, ?, NULL, ?)
                        """,
                    arguments: [
                        identifier.managerIdentifier,
                        identifier.alertIdentifier,
                        issuedAt.timeIntervalSince1970,
                        retractedAt?.timeIntervalSince1970,
                        encoded
                    ]
                )
                return try Self.runRetention(db, at: at)
            }
            if pruned > 0 {
                log.default("retention pruned %d retracted alert(s)", pruned)
            }
        } catch {
            throw AlertRecordStoreError.writeFailed("could not store an alert: \(error)")
        }
    }

    func retract(identifier: Alert.Identifier, at: Date) async throws {
        do {
            try await dbQueue.write { db in
                // `AND retracted_at IS NULL` is a deliberate departure from the
                // JSON path, which re-stamped *every* row carrying this
                // identifier on each retraction — including rows retracted long
                // ago.
                //
                // Nothing could observe the rewritten value directly, since both
                // lookups filter to `retracted_at IS NULL`. What it did affect
                // was retention: `retracted_at` is what the sweep compares
                // against, so an alert that fires and is retracted repeatedly
                // kept pushing its oldest records' cutoff forward and they
                // outlived the 90-day horizon indefinitely. An alert is
                // retracted once, at the instant it stopped being true, and that
                // is what the row should say for as long as it is kept.
                try db.execute(
                    sql: """
                        UPDATE alert SET retracted_at = ?
                        WHERE manager_identifier = ? AND alert_identifier = ?
                          AND retracted_at IS NULL
                        """,
                    arguments: [
                        at.timeIntervalSince1970,
                        identifier.managerIdentifier,
                        identifier.alertIdentifier
                    ]
                )
            }
        } catch {
            throw AlertRecordStoreError.writeFailed("could not retract an alert: \(error)")
        }
    }

    // MARK: - Retention

    /// Hard-deletes retracted alerts past the horizon, and only those.
    ///
    /// The `retracted_at IS NOT NULL` guard is the whole policy: an unretracted
    /// alert is outstanding state, so age tells us nothing about whether it can
    /// go. See `AlertRecordStorePolicy.retention`.
    private static func runRetention(_ db: Database, at: Date) throws -> Int {
        let cutoff = at.timeIntervalSince1970 - AlertRecordStorePolicy.retention
        try db.execute(
            sql: "DELETE FROM alert WHERE retracted_at IS NOT NULL AND retracted_at < ?",
            arguments: [cutoff]
        )
        return db.changesCount
    }

    // MARK: - Reads

    func issuedAlertExists(identifier: Alert.Identifier) async throws -> Bool {
        do {
            return try await dbQueue.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT 1 FROM alert
                        WHERE manager_identifier = ? AND alert_identifier = ?
                        LIMIT 1
                        """,
                    arguments: [identifier.managerIdentifier, identifier.alertIdentifier]
                ) ?? false
            }
        } catch {
            throw AlertRecordStoreError.readFailed("issuedAlertExists failed: \(error)")
        }
    }

    // Two literal queries rather than one with an interpolated predicate: the
    // SQL in this file is only ever a constant, and keeping it that way means
    // there is no place a caller's string could reach a statement.
    //
    // `ORDER BY id` is issue order, matching the array order the JSON path
    // returned.

    func unretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        let rows: [AlertRow]
        do {
            rows = try await dbQueue.read { db in
                try AlertRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM alert
                        WHERE manager_identifier = ? AND retracted_at IS NULL
                        ORDER BY id
                        """,
                    arguments: [managerIdentifier]
                )
            }
        } catch {
            throw AlertRecordStoreError.readFailed("unretracted failed: \(error)")
        }
        return decode(rows)
    }

    func unacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert] {
        let rows: [AlertRow]
        do {
            rows = try await dbQueue.read { db in
                try AlertRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM alert
                        WHERE manager_identifier = ?
                          AND retracted_at IS NULL
                          AND acknowledged_at IS NULL
                        ORDER BY id
                        """,
                    arguments: [managerIdentifier]
                )
            }
        } catch {
            throw AlertRecordStoreError.readFailed("unacknowledgedUnretracted failed: \(error)")
        }
        return decode(rows)
    }

    private func decode(_ rows: [AlertRow]) -> [PersistedAlert] {
        let alerts = rows.compactMap { $0.toDomain() }
        if alerts.count != rows.count {
            log.error("dropped %d undecodable alert row(s)", rows.count - alerts.count)
        }
        return alerts
    }

    func mostRecentActive() async throws -> Alert? {
        do {
            return try await dbQueue.read { db in
                try AlertRow.fetchOne(
                    db,
                    sql: """
                        SELECT * FROM alert
                        WHERE retracted_at IS NULL AND acknowledged_at IS NULL
                        ORDER BY id DESC
                        LIMIT 1
                        """
                )?.toDomain()?.alert
            }
        } catch {
            throw AlertRecordStoreError.readFailed("mostRecentActive failed: \(error)")
        }
    }

}
