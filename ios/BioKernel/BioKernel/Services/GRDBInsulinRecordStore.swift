//
//  GRDBInsulinRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/3/26.
//
//  The GRDB implementation of `InsulinRecordStore`. See
//  dev/backlog/insulin-storage-grdb.md §4, §5, §6.3.
//
//  GRDB types never leave this file — the row struct is private and the protocol
//  above speaks domain values. Same shape as `SQLitePersistentStorage` in the
//  ClueClue port, deliberately, so porting between the two stays mechanical
//  (§9.7).
//
//  The schema is raw SQL rather than GRDB's table builder. §9.4 is the reason:
//  the safety-critical part of this store is which rows a range read returns,
//  and `dose_end >= ? AND dose_start < ?` can be checked by someone who does not
//  know this codebase.
//

import Foundation
import GRDB
import LoopKit

actor GRDBInsulinRecordStore: InsulinRecordStore {

    // MARK: - The row (private — never crosses the protocol boundary)

    /// Dates are stored as `DOUBLE` epoch seconds, not as GRDB's default
    /// ISO-8601 text. The schema in §4.1 is written with numeric comparisons and
    /// the cutover gate in §7.3.1 is three SQL queries a human runs by hand;
    /// text dates would make both of those lie in ways that don't error.
    private struct PumpEventRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "pump_event"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var syncIdentifier: String
        var date: Double
        var eventType: String
        var alarmType: String?
        var doseStart: Double?
        var doseEnd: Double?
        var rateUnitsPerHour: Double?
        var programmedUnits: Double?
        var deliveredUnits: Double?
        var insulinType: String?
        var automatic: Bool?
        var manuallyEntered: Bool?
        var isMutable: Bool
        var deletedAt: Double?
        var pumpPluginIdentifier: String
        var smallestDeliveryUnit: Double?
        var recordedAt: Double
        var raw: Data?
        var title: String?

        init(record: PumpEventRecord) {
            self.syncIdentifier = record.syncIdentifier
            self.date = record.date.timeIntervalSince1970
            self.eventType = record.eventType.rawValue
            self.alarmType = record.alarmType?.rawValue
            self.doseStart = record.doseStart?.timeIntervalSince1970
            self.doseEnd = record.doseEnd?.timeIntervalSince1970
            self.rateUnitsPerHour = record.rateUnitsPerHour
            self.programmedUnits = record.programmedUnits
            self.deliveredUnits = record.deliveredUnits
            self.insulinType = record.insulinType?.rawValue
            self.automatic = record.automatic
            self.manuallyEntered = record.manuallyEntered
            self.isMutable = record.isMutable
            self.deletedAt = record.deletedAt?.timeIntervalSince1970
            self.pumpPluginIdentifier = record.pumpPluginIdentifier
            self.smallestDeliveryUnit = record.smallestDeliveryUnit
            self.recordedAt = record.recordedAt.timeIntervalSince1970
            self.raw = record.raw
            self.title = record.title
        }

        func toDomain() -> PumpEventRecord {
            return PumpEventRecord(
                syncIdentifier: syncIdentifier,
                date: Date(timeIntervalSince1970: date),
                eventType: PumpEventKind(rawValue: eventType),
                alarmType: alarmType.map { PumpAlarmType(rawValue: $0) },
                doseStart: doseStart.map { Date(timeIntervalSince1970: $0) },
                doseEnd: doseEnd.map { Date(timeIntervalSince1970: $0) },
                rateUnitsPerHour: rateUnitsPerHour,
                programmedUnits: programmedUnits,
                deliveredUnits: deliveredUnits,
                insulinType: insulinType.flatMap { AiInsulinType(rawValue: $0) },
                automatic: automatic,
                manuallyEntered: manuallyEntered,
                isMutable: isMutable,
                deletedAt: deletedAt.map { Date(timeIntervalSince1970: $0) },
                pumpPluginIdentifier: pumpPluginIdentifier,
                smallestDeliveryUnit: smallestDeliveryUnit,
                recordedAt: Date(timeIntervalSince1970: recordedAt),
                raw: raw,
                title: title
            )
        }
    }

    /// The one-row singleton table (§4.2), in the same database so it shares the
    /// transaction and the file-protection class.
    private struct StoreStateRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "store_state"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var id: Int64
        /// When the store was created. Before this instant history is whatever
        /// the old 24-hour log happened to hold, i.e. lossy.
        var createdAt: Double
        /// I4's left edge. Monotonic: `max(previous, createdAt, retention
        /// cutoff)`. It must never move backwards, or the clamp could re-open a
        /// span it has already refused to fill.
        var historyCompleteSince: Double
        /// I5's right edge, from the driver.
        var lastReconciliation: Double?
    }

    // MARK: - State

    private let dbQueue: DatabaseQueue
    /// nil for the in-memory store, which has no file to snapshot.
    private let url: URL?
    private let log = DiagnosticLog(category: "InsulinRecordStore")

    // MARK: - Init

    /// - Parameter createdAt: the store's creation instant, which becomes the
    ///   initial `history_complete_since`. Injected rather than read from the
    ///   clock so the clamp is testable, which is most of what §10 asks for.
    /// - Parameter backfillRateUnitsPerHour: the rate to stamp on resumes that
    ///   predate the `scheduled_basal` table (scheduled-basal-history §4.2). Read
    ///   from settings once, at migration time, rather than written into the doc
    ///   as a literal — and *not* the defect in §1 of that doc, whose complaint is
    ///   that the setting is read on every derivation. Reading it once to stamp
    ///   fixed rows that are then never revised is the opposite shape, which is
    ///   why those rows are labeled `backfilled`.
    init(url: URL, createdAt: Date, backfillRateUnitsPerHour: Double) throws {
        // Per GRDB's guidance, each database lives in its OWN directory so the
        // main file, the WAL/SHM sidecars, and SQLite's temp files stay
        // together. The directory carries NSFileProtectionNone and the files
        // SQLite creates inside it inherit it, so we own the directory instead
        // of chasing per-file attributes (§8).
        //
        // This is not optional bookkeeping: the app is woken by CGM Bluetooth
        // before first unlock, and a protected database fails to open exactly
        // when the loop needs to read IOB.
        do {
            try Self.makeUnprotectedDirectory(at: url.deletingLastPathComponent())
        } catch {
            throw InsulinRecordStoreError.couldNotOpen("could not create the store directory: \(error)")
        }

        do {
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: Configuration())
        } catch {
            throw InsulinRecordStoreError.couldNotOpen("could not open \(url.lastPathComponent): \(error)")
        }
        self.url = url

        try Self.prepare(dbQueue, createdAt: createdAt, backfillRate: backfillRateUnitsPerHour)
    }

    /// In-memory store for tests, so nothing here touches a file system.
    init(inMemoryCreatedAt createdAt: Date, backfillRateUnitsPerHour: Double = 0) throws {
        do {
            self.dbQueue = try DatabaseQueue()
        } catch {
            throw InsulinRecordStoreError.couldNotOpen("could not open an in-memory database: \(error)")
        }
        self.url = nil
        try Self.prepare(dbQueue, createdAt: createdAt, backfillRate: backfillRateUnitsPerHour)
    }

    private static func prepare(_ dbQueue: DatabaseQueue, createdAt: Date, backfillRate: Double) throws {
        do {
            try migrator(backfillRate: backfillRate, recordedAt: createdAt).migrate(dbQueue)
            try dbQueue.write { db in
                // Seeded once. `INSERT OR IGNORE` rather than an upsert: on
                // every launch after the first, `created_at` is already the
                // right answer and rewriting it would move I4's left edge
                // forward on each launch, silently un-clamping nothing and
                // re-clamping everything.
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO store_state
                            (id, created_at, history_complete_since, last_reconciliation)
                        VALUES (0, ?, ?, NULL)
                        """,
                    arguments: [createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970]
                )
            }
        } catch {
            throw InsulinRecordStoreError.couldNotOpen("could not migrate the store: \(error)")
        }
    }

    // MARK: - File protection

    /// `attributes` only applies when the directory is actually created, so a
    /// tree left over from a prior install keeps whatever protection it had.
    /// Re-assert every launch — the same reason
    /// `AiInterfaceContainer.reassertFileProtection` exists.
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

    /// `Documents/InsulinRecordStore/pump_events.sqlite`. Its own directory, per
    /// the rule above.
    static func defaultURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return documents
            .appendingPathComponent("InsulinRecordStore", isDirectory: true)
            .appendingPathComponent("pump_events.sqlite", isDirectory: false)
    }

    // MARK: - Migrations
    //
    // Migrations are source (§9.5): these registrations read in a diff, which a
    // `.xcdatamodeld` bundle does not.

    private static func migrator(backfillRate: Double, recordedAt: Date) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // All pump events, not only doses, so alarm state and the
            // diagnostics view are served from one place. Mutable and immutable
            // rows share the table, distinguished by a column — LoopKit's dose
            // lifecycle, as adopted by Trio#1300.
            try db.execute(sql: """
                CREATE TABLE pump_event (
                  sync_identifier        TEXT PRIMARY KEY,  -- driver's; synthetic when absent
                  date                   DOUBLE NOT NULL,   -- epoch seconds; the event's own time
                  event_type             TEXT NOT NULL,
                  alarm_type             TEXT,
                  dose_start             DOUBLE,            -- NULL for a non-dose event
                  dose_end               DOUBLE,
                  rate_units_per_hour    DOUBLE,
                  programmed_units       DOUBLE,
                  delivered_units        DOUBLE,            -- NULL until the pump reports it
                  insulin_type           TEXT,
                  automatic              INTEGER,
                  manually_entered       INTEGER,
                  is_mutable             INTEGER NOT NULL,
                  deleted_at             DOUBLE,            -- soft delete; NULL means live
                  pump_plugin_identifier TEXT NOT NULL,
                  smallest_delivery_unit DOUBLE,
                  recorded_at            DOUBLE NOT NULL,   -- when we ingested it
                  raw                    BLOB,              -- driver's opaque payload, diagnostics only
                  title                  TEXT
                )
                """)

            // Partial indexes, so the `deleted_at IS NULL` filter every read
            // carries is free. Forgetting that filter resurrects orphans, which
            // is why it is cheap enough to never skip.
            try db.execute(sql: "CREATE INDEX idx_event_date      ON pump_event(date)                   WHERE deleted_at IS NULL")
            try db.execute(sql: "CREATE INDEX idx_event_dose_span ON pump_event(dose_end, dose_start)   WHERE deleted_at IS NULL")
            try db.execute(sql: "CREATE INDEX idx_event_type_date ON pump_event(event_type, date)       WHERE deleted_at IS NULL")
            try db.execute(sql: "CREATE INDEX idx_event_mutable   ON pump_event(is_mutable, dose_start) WHERE deleted_at IS NULL")

            try db.execute(sql: """
                CREATE TABLE store_state (
                  id                     INTEGER PRIMARY KEY,  -- always 0
                  created_at             DOUBLE NOT NULL,
                  history_complete_since DOUBLE NOT NULL,      -- I5's left edge
                  last_reconciliation    DOUBLE                -- I5's right edge, from the driver
                )
                """)
        }

        // dev/backlog/scheduled-basal-history.md §3.1 and §4.1.
        migrator.registerMigration("v2-scheduled-basal") { db in
            // Keyed on the resume, and carrying **no timestamp**: the effective
            // instant is `pump_event.date` for `resume_sync_id`, read by join.
            // With no copy there is nothing to keep bit-identical, the rate and
            // the boundary come from one row, and retention becomes the cascade
            // rather than a separate prune rule.
            try db.execute(sql: """
                CREATE TABLE scheduled_basal (
                  resume_sync_id      TEXT PRIMARY KEY
                                        REFERENCES pump_event(sync_identifier) ON DELETE CASCADE,
                  rate_units_per_hour DOUBLE NOT NULL,
                  source              TEXT NOT NULL,       -- acknowledged | backfilled
                  recorded_at         DOUBLE NOT NULL
                )
                """)

            // The queue, not history. A program that is never acknowledged never
            // reaches a lookup — which is the whole difference from the earlier
            // design, where an unlinked record kept serving lookups from an
            // instant at which the pod was suspended (§4.1).
            try db.execute(sql: """
                CREATE TABLE scheduled_basal_program (
                  id                  INTEGER PRIMARY KEY AUTOINCREMENT,
                  rate_units_per_hour DOUBLE NOT NULL,
                  requested_at        DOUBLE NOT NULL,  -- app clock; matching and diagnostics only
                  consumed_by_sync_id TEXT,             -- NULL until a resume claims it
                  abandoned_at        DOUBLE            -- aged out unconsumed
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_program_pending ON scheduled_basal_program(requested_at)
                WHERE consumed_by_sync_id IS NULL AND abandoned_at IS NULL
                """)

            // §4.2's backfill. Every existing resume, not just the earliest: they
            // all carry the same rate, so the re-assertion filter makes the
            // derivation output identical either way, and retention is what
            // decides it — with all of them present the day-90 prune advances the
            // clamp to the next resume rather than jumping forward to the first
            // genuinely acknowledged record.
            //
            // Selects existing resume rows, so **this is a no-op on any store with
            // none.** A fresh install inserts nothing regardless of which rate was
            // captured, which is what makes it safe as a permanent migration with
            // no flag and no version guard.
            //
            // These rows assert a rate that was not observed. What makes them true
            // is out of band — the rate did not change over the span they cover —
            // and `source = backfilled` is what keeps them from later being read as
            // evidence.
            try db.execute(
                sql: """
                    INSERT INTO scheduled_basal
                        (resume_sync_id, rate_units_per_hour, source, recorded_at)
                    SELECT sync_identifier, ?, ?, ?
                    FROM pump_event
                    WHERE event_type = ? AND deleted_at IS NULL
                    """,
                arguments: [
                    backfillRate,
                    ScheduledBasalRecord.Source.backfilled.rawValue,
                    recordedAt.timeIntervalSince1970,
                    PumpEventKind.resume.rawValue
                ]
            )
        }

        return migrator
    }

    // MARK: - Ingest (§5)

    func ingest(_ batch: PumpEventBatch) async throws -> PumpEventIngestResult {
        // Mapping happens out here, before the transaction, so nothing inside it
        // touches a LoopKit reference type and the write stays as short as the
        // work requires.
        let incoming = Self.collapse(batch: batch)
        let syntheticDoseIdentifiers = incoming
            .filter { $0.isDose && PumpEventRecord.isSynthetic(syncIdentifier: $0.syncIdentifier) }
            .map { $0.syncIdentifier }
        if !syntheticDoseIdentifiers.isEmpty {
            log.error("%d dose(s) arrived with no driver syncIdentifier", syntheticDoseIdentifiers.count)
        }

        let replacePendingEvents = batch.replacePendingEvents
        let at = batch.at
        let lastReconciliation = batch.lastReconciliation

        do {
            return try await dbQueue.write { db in
                // 1. Upsert every incoming event by sync_identifier.
                var upserted: [PumpEventRecord] = []
                var reasserted: [String] = []

                for record in incoming {
                    let existing = try PumpEventRow
                        .filter(Column("sync_identifier") == record.syncIdentifier)
                        .fetchOne(db)?
                        .toDomain()

                    // I2: an event arriving mutable when the immutable version
                    // is already held is ignored. The pump has already told us
                    // what it did; a later mutable report cannot un-tell us.
                    if let existing, !existing.isMutable, record.isMutable {
                        continue
                    }

                    // A revoked id the driver re-asserts comes back intact:
                    // same row, `recorded_at` preserved, `deleted_at` cleared.
                    // Deleting and recreating would churn identity for no
                    // reason (§5.1.1 point 2).
                    if existing?.deletedAt != nil {
                        reasserted.append(record.syncIdentifier)
                    }

                    let row = PumpEventRow(record: Self.merging(record, onto: existing))
                    try row.upsert(db)
                    upserted.append(row.toDomain())
                }

                // 2. If and only if replacePendingEvents, revoke every live
                //    mutable row the batch did not assert.
                //
                //    Global scope, unbounded in time, matching LoopKit. Safe for
                //    a different reason than LoopKit's, though: LoopKit's purge
                //    spans at most `cacheStartDate` and ours spans 90 days of
                //    retention, and what makes that fine is that a mutable dose
                //    older than a few hours is an orphan by definition. That it
                //    is *also* how one malformed batch could revoke a genuinely
                //    in-flight dose anywhere in history is why §5.3 exists.
                var revoked: [PumpEventRecord] = []
                if replacePendingEvents {
                    let asserted = Set(upserted.map { $0.syncIdentifier })
                    let liveMutable = try PumpEventRow
                        .filter(Column("deleted_at") == nil)
                        .filter(Column("is_mutable") == true)
                        .fetchAll(db)
                        .map { $0.toDomain() }

                    for record in liveMutable where !asserted.contains(record.syncIdentifier) {
                        try db.execute(
                            sql: "UPDATE pump_event SET deleted_at = ? WHERE sync_identifier = ?",
                            arguments: [at.timeIntervalSince1970, record.syncIdentifier]
                        )
                        revoked.append(record)
                    }
                }

                // 3. Record the driver's reconciliation instant, which
                //    `LocalInsulinStorage` currently throws away (§5.2).
                try db.execute(
                    sql: "UPDATE store_state SET last_reconciliation = ? WHERE id = 0",
                    arguments: [lastReconciliation?.timeIntervalSince1970]
                )

                // 4. Give every resume the store now holds the rate the pod was
                //    programmed with. Before retention, so a resume that is about
                //    to be pruned does not get a record only to lose it, and
                //    before the clamp, because the clamp reads the earliest
                //    surviving record.
                let scheduledBasal = try Self.reconcileScheduledBasal(db, at: at)

                // 5. Retention, then advance the clamp with the boundary it
                //    actually used — not with the nominal cutoff (§4.3).
                let retention = try Self.runRetention(db, at: at)
                let historyCompleteSince = try Self.advanceHistoryCompleteSince(
                    db, retention: retention, at: at
                )

                return PumpEventIngestResult(
                    upserted: upserted,
                    revoked: revoked,
                    reassertedAfterRevocation: reasserted,
                    syntheticDoseIdentifiers: syntheticDoseIdentifiers,
                    retention: retention,
                    historyCompleteSince: historyCompleteSince,
                    scheduledBasal: scheduledBasal
                )
            }
        } catch let error as InsulinRecordStoreError {
            throw error
        } catch {
            throw InsulinRecordStoreError.writeFailed("ingest failed: \(error)")
        }
    }

    /// Collapses one batch to at most one row per `sync_identifier`, preferring
    /// the immutable version.
    ///
    /// A single batch can carry both revisions of the same dose — that is what
    /// the JSON path's `removeStaleMutableDoses` was reconstructing on every
    /// read. Here it is a fold, and the primary key does the rest.
    private static func collapse(batch: PumpEventBatch) -> [PumpEventRecord] {
        var byIdentifier: [String: PumpEventRecord] = [:]
        var order: [String] = []

        for event in batch.events {
            let record = PumpEventRecord(event: event, pump: batch.pump, at: batch.at)
            if let existing = byIdentifier[record.syncIdentifier] {
                // Keep the immutable one; between two of the same mutability the
                // later one in the batch wins, which is the driver's own order.
                if !existing.isMutable && record.isMutable { continue }
            } else {
                order.append(record.syncIdentifier)
            }
            byIdentifier[record.syncIdentifier] = record
        }

        return order.compactMap { byIdentifier[$0] }
    }

    /// The row to write, given what we already hold.
    ///
    /// `recordedAt` is the first time we saw the dose, not the latest — the gap
    /// between it and `date` is how late a dose arrived, and re-reporting a
    /// mutable dose every five minutes must not keep resetting that.
    /// `deletedAt` clears, because the driver is asserting the dose again.
    private static func merging(_ incoming: PumpEventRecord, onto existing: PumpEventRecord?) -> PumpEventRecord {
        guard let existing else { return incoming }
        return PumpEventRecord(
            syncIdentifier: incoming.syncIdentifier,
            date: incoming.date,
            eventType: incoming.eventType,
            alarmType: incoming.alarmType,
            doseStart: incoming.doseStart,
            doseEnd: incoming.doseEnd,
            rateUnitsPerHour: incoming.rateUnitsPerHour,
            programmedUnits: incoming.programmedUnits,
            deliveredUnits: incoming.deliveredUnits,
            insulinType: incoming.insulinType,
            automatic: incoming.automatic,
            manuallyEntered: incoming.manuallyEntered,
            isMutable: incoming.isMutable,
            deletedAt: nil,
            pumpPluginIdentifier: incoming.pumpPluginIdentifier,
            smallestDeliveryUnit: incoming.smallestDeliveryUnit,
            recordedAt: existing.recordedAt,
            raw: incoming.raw,
            title: incoming.title
        )
    }

    // MARK: - Retention

    /// Hard-deletes rows past the retention horizon, cutting at a resume rather
    /// than at the wall clock (§4.3).
    ///
    /// A `DELETE` rather than the soft delete revocation uses: a soft delete kept
    /// forever is not retention. What keeps this boundary from re-creating the
    /// bug the store fixes is `historyCompleteSince` moving with it (I4).
    ///
    /// **Why the cut lands on a resume.** Deleting at the nominal cutoff leaves
    /// the oldest surviving rate record *later* than the oldest surviving event,
    /// and the clamp has to sit at the record (scheduled-basal-history §7). The
    /// rows in between are retained and permanently uninferable: real doses that
    /// no gap-fill may span, at a left edge that rolls forward every day. Cutting
    /// at the newest resume at or before the cutoff collapses the deletion
    /// boundary, the first rate record, and the clamp onto one instant, so no
    /// such band exists. The cost is up to one pod cycle of extra rows — the
    /// store deliberately keeps *more* than 90 days so that 90 days of it are
    /// answerable.
    ///
    /// The anchor must carry a rate record, not merely be a resume: a resume with
    /// no record anchors the state but not the rate, which is the same band again.
    ///
    /// Two rows are exempt: the most recent suspend/resume and the most recent
    /// alarm/alarmClear, however old they are. This is the one legitimate
    /// residue of `getMostRecentStatefulOldEvents` — a state answer that must
    /// stay available past the deletion boundary — and it is safe now for the
    /// reason it was not before: I3 keeps those rows out of the array
    /// gap-filling walks, so a retained marker can inform the starting state
    /// without becoming a delivery boundary. Keeping them does *not* move
    /// `history_complete_since`: the span is still incomplete for delivery.
    ///
    /// The suspend/resume exemption is **provably inert whenever the boundary is
    /// anchored** — the anchor is itself a resume, so the newest suspend/resume
    /// is at or after it and survives regardless. It is kept rather than branched
    /// on because it stays load-bearing on the unanchored fallback path, and one
    /// query with an inert clause is easier to be sure of than two queries.
    private static func runRetention(_ db: Database, at: Date) throws -> RetentionOutcome {
        let cutoff = at.timeIntervalSince1970 - InsulinRecordStorePolicy.retention
        let anchor = try Self.retentionAnchor(db, cutoff: cutoff)
        let boundary = anchor?.date ?? cutoff

        try db.execute(
            sql: """
                DELETE FROM pump_event
                WHERE date < ?
                  AND sync_identifier NOT IN (
                    SELECT sync_identifier FROM pump_event
                    WHERE event_type IN ('suspend','resume') AND deleted_at IS NULL
                    ORDER BY date DESC, sync_identifier DESC LIMIT 1
                  )
                  AND sync_identifier NOT IN (
                    SELECT sync_identifier FROM pump_event
                    WHERE event_type IN ('alarm','alarmClear') AND deleted_at IS NULL
                    ORDER BY date DESC, sync_identifier DESC LIMIT 1
                  )
                """,
            arguments: [boundary]
        )

        return RetentionOutcome(
            pruned: db.changesCount,
            boundary: Date(timeIntervalSince1970: boundary),
            anchorSyncIdentifier: anchor?.syncIdentifier
        )
    }

    /// The newest resume at or before `cutoff` that carries a rate record, within
    /// `retentionAnchorMaxLookback` of it.
    ///
    /// The floor is the backstop. Anchoring makes retention a function of driver
    /// behavior rather than of time alone, so the degenerate case — no resumes
    /// arriving at all — has to be a bounded loss rather than a store that never
    /// prunes again.
    private static func retentionAnchor(_ db: Database, cutoff: Double) throws -> (syncIdentifier: String, date: Double)? {
        let floor = cutoff - InsulinRecordStorePolicy.retentionAnchorMaxLookback
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT e.sync_identifier, e.date
                FROM pump_event e
                JOIN scheduled_basal sb ON sb.resume_sync_id = e.sync_identifier
                WHERE e.deleted_at IS NULL
                  AND e.event_type = ?
                  AND e.date <= ?
                  AND e.date >= ?
                ORDER BY e.date DESC, e.sync_identifier DESC
                LIMIT 1
                """,
            arguments: [PumpEventKind.resume.rawValue, cutoff, floor]
        )
        guard let row,
              let syncIdentifier = row["sync_identifier"] as String?,
              let date = row["date"] as Double? else { return nil }
        return (syncIdentifier, date)
    }

    /// `max(previous, createdAt, retentionBoundary, earliestScheduledBasal)` —
    /// §4.2 of the parent doc and §7 of scheduled-basal-history, made monotonic.
    ///
    /// Monotonicity is the part worth stating: if this could move backwards, a
    /// clamp would re-open a span it has already refused to fill, and the first
    /// derivation after it moved would fabricate exactly once and then never
    /// again — the hardest possible version of this bug to catch.
    ///
    /// **The third term is retention's *actual* boundary, not the nominal
    /// cutoff.** Passing `at - retention` here instead is the one mistake that
    /// silently undoes §4.3: the nominal cutoff is later than an anchored
    /// boundary, so `max` would pick it and strand exactly the band the anchor
    /// exists to eliminate — with every row still present, so nothing would look
    /// wrong.
    ///
    /// The fourth term is what replaces a genesis record. When the boundary is
    /// anchored the two coincide by construction, since the anchor is the oldest
    /// surviving resume and it carries a rate record. They diverge only on the
    /// unanchored fallback, which is the case the term was written for: a band
    /// between the clamp and the first *retained* resume where inference is live
    /// but no rate record covers it, and the same band at the other end of
    /// history for a store created mid-life. The alternative — fall back to the
    /// current setting where no record covers the instant — reintroduces §1
    /// exactly, confined to that band, and would break the parent doc's
    /// idempotence property, since a settings edit would rewrite past
    /// derivations. A refusal is what we have grounds for.
    @discardableResult
    private static func advanceHistoryCompleteSince(_ db: Database, retention: RetentionOutcome, at: Date) throws -> Date {
        guard let state = try StoreStateRow.fetchOne(db, key: 0) else {
            throw InsulinRecordStoreError.writeFailed("store_state row is missing")
        }
        let retentionBoundary = retention.boundary.timeIntervalSince1970

        // **An empty table clamps everything.** This is the edge case dropping
        // genesis makes load-bearing, and the natural implementation gets it
        // backwards: coalesce the missing term to nil, let `max` fall through to
        // `createdAt`, and inference runs across a span with no rate at all.
        //
        // Coalescing to `at` instead means the clamp tracks now until the first
        // record exists, and then — because `max` keeps the larger and the first
        // record's instant is the last value `at` took — settles exactly on that
        // record. A fresh store therefore infers nothing until its first pod
        // change, which is a refusal rather than a wrong number.
        let earliestScheduledBasal = try Double.fetchOne(db, sql: """
            SELECT MIN(e.date)
            FROM scheduled_basal sb
            JOIN pump_event e ON e.sync_identifier = sb.resume_sync_id
            WHERE e.deleted_at IS NULL
            """) ?? at.timeIntervalSince1970

        let advanced = max(
            state.historyCompleteSince,
            state.createdAt,
            retentionBoundary,
            earliestScheduledBasal
        )
        if advanced > state.historyCompleteSince {
            try db.execute(
                sql: "UPDATE store_state SET history_complete_since = ? WHERE id = 0",
                arguments: [advanced]
            )
        }
        return Date(timeIntervalSince1970: advanced)
    }

    // MARK: - Scheduled basal (dev/backlog/scheduled-basal-history.md §4.1)

    func enqueueScheduledBasalProgram(rateUnitsPerHour: Double, at: Date) async throws {
        do {
            try await dbQueue.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO scheduled_basal_program (rate_units_per_hour, requested_at)
                        VALUES (?, ?)
                        """,
                    arguments: [rateUnitsPerHour, at.timeIntervalSince1970]
                )
                // Reconcile here as well as on ingest. The pod's resume may
                // already be in the store — at activation it is minted during the
                // session, well before `didOnboardPumpManager` fires — and if it
                // is, this is the moment it can finally be given a rate. Running
                // the same reconciliation from both sides is what removes the
                // ordering race rather than betting on one order.
                _ = try Self.reconcileScheduledBasal(db, at: at)
            }
        } catch {
            throw InsulinRecordStoreError.writeFailed("could not enqueue a scheduled basal program: \(error)")
        }
    }

    func scheduledBasalDiagnostics(at: Date) async throws -> ScheduledBasalDiagnostics {
        do {
            return try await dbQueue.read { db in
                // `-greatestFiniteMagnitude` as the edge makes the anchor query
                // find nothing and the range query find everything, so one
                // function serves both the I3-shaped timeline read and this.
                let history = try Self.fetchScheduledBasalHistory(
                    db,
                    inferenceStartSeconds: -Double.greatestFiniteMagnitude,
                    atSeconds: at.timeIntervalSince1970
                )
                let acknowledged = history.records.filter { $0.source == .acknowledged }.count
                let backfilled = history.records.filter { $0.source == .backfilled }.count

                let pending = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scheduled_basal_program
                    WHERE consumed_by_sync_id IS NULL AND abandoned_at IS NULL
                    """) ?? 0
                let abandoned = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM scheduled_basal_program WHERE abandoned_at IS NOT NULL
                    """) ?? 0

                // Only resumes old enough that a program should have arrived by
                // now. A younger one is deliberately undecided, not unresolved.
                let cutoff = at.timeIntervalSince1970 - InsulinRecordStorePolicy.scheduledBasalProgramMatchWindow
                let withoutRecord = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM pump_event e
                        LEFT JOIN scheduled_basal sb ON sb.resume_sync_id = e.sync_identifier
                        WHERE e.deleted_at IS NULL AND e.event_type = ?
                          AND sb.resume_sync_id IS NULL AND e.date < ?
                        """,
                    arguments: [PumpEventKind.resume.rawValue, cutoff]
                ) ?? 0

                return ScheduledBasalDiagnostics(
                    acknowledgedRecordCount: acknowledged,
                    backfilledRecordCount: backfilled,
                    changeCount: history.changeCount,
                    pendingProgramCount: pending,
                    abandonedProgramCount: abandoned,
                    resumesWithNoRecordCount: withoutRecord
                )
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("scheduledBasalDiagnostics failed: \(error)")
        }
    }

    /// Gives every resume the store holds the rate the pod was programmed with.
    ///
    /// Runs inside an existing transaction, from both ingest and enqueue. Each
    /// resume resolves one of three ways:
    ///
    /// 1. **A pending program within the window** claims it → the program's rate,
    ///    one-to-one, oldest first.
    /// 2. **Nothing pending, and old enough to give up waiting** → a bare
    ///    `resumeBasal`, which re-programs the schedule already on the pod, so it
    ///    re-asserts the previous record's rate. Derived rather than stored (§3.3),
    ///    which is what makes re-assertion free.
    /// 3. **Nothing pending, and still young** → left undecided until the next
    ///    pass. This is the case that matters: `OmniPumpManager` reports the resume
    ///    on its own cadence, so a program can be seconds behind the resume in wall
    ///    time and a whole loop period behind it in *arrival* time. Falling back to
    ///    the previous rate immediately would mint a record we could no longer
    ///    correct, since the primary key is already taken.
    ///
    /// A resume with no program and no preceding record is genuinely unresolved,
    /// which happens only before the first record exists.
    private static func reconcileScheduledBasal(_ db: Database, at: Date) throws -> ScheduledBasalIngestResult {
        let window = InsulinRecordStorePolicy.scheduledBasalProgramMatchWindow
        let atSeconds = at.timeIntervalSince1970

        let pendingResumes = try Row.fetchAll(
            db,
            sql: """
                SELECT e.sync_identifier AS sync_identifier, e.date AS date
                FROM pump_event e
                LEFT JOIN scheduled_basal sb ON sb.resume_sync_id = e.sync_identifier
                WHERE e.deleted_at IS NULL
                  AND e.event_type = ?
                  AND sb.resume_sync_id IS NULL
                ORDER BY e.date, e.sync_identifier
                """,
            arguments: [PumpEventKind.resume.rawValue]
        )

        var minted: [ScheduledBasalRecord] = []
        var unresolved: [String] = []

        for row in pendingResumes {
            let syncIdentifier: String = row["sync_identifier"]
            let dateSeconds: Double = row["date"]

            if let program = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, rate_units_per_hour FROM scheduled_basal_program
                    WHERE consumed_by_sync_id IS NULL AND abandoned_at IS NULL
                      AND ABS(requested_at - ?) <= ?
                    ORDER BY requested_at, id
                    LIMIT 1
                    """,
                arguments: [dateSeconds, window]
            ) {
                let programId: Int64 = program["id"]
                let rate: Double = program["rate_units_per_hour"]
                minted.append(try insertScheduledBasal(
                    db,
                    resumeSyncIdentifier: syncIdentifier,
                    effectiveAtSeconds: dateSeconds,
                    rateUnitsPerHour: rate,
                    source: .acknowledged,
                    recordedAtSeconds: atSeconds
                ))
                try db.execute(
                    sql: "UPDATE scheduled_basal_program SET consumed_by_sync_id = ? WHERE id = ?",
                    arguments: [syncIdentifier, programId]
                )
                continue
            }

            // Case 3: still young enough that a program may be on its way.
            guard atSeconds - dateSeconds > window else { continue }

            // Case 2: re-assertion. Records minted earlier in this same loop are
            // visible here, so a run of resumes chains from the one before it.
            guard let previousRate = try Double.fetchOne(
                db,
                sql: """
                    SELECT sb.rate_units_per_hour
                    FROM scheduled_basal sb
                    JOIN pump_event e ON e.sync_identifier = sb.resume_sync_id
                    WHERE e.deleted_at IS NULL AND e.date < ?
                    ORDER BY e.date DESC, e.sync_identifier DESC
                    LIMIT 1
                    """,
                arguments: [dateSeconds]
            ) else {
                unresolved.append(syncIdentifier)
                continue
            }

            minted.append(try insertScheduledBasal(
                db,
                resumeSyncIdentifier: syncIdentifier,
                effectiveAtSeconds: dateSeconds,
                rateUnitsPerHour: previousRate,
                source: .acknowledged,
                recordedAtSeconds: atSeconds
            ))
        }

        // Programs that aged out unconsumed: we programmed and never saw the
        // acknowledgment. Marked rather than left queued, so they stop being
        // candidates — which is the mis-attribution guard — and start being a
        // diagnostic. Run after matching, so a program a resume was about to claim
        // is never abandoned out from under it.
        try db.execute(
            sql: """
                UPDATE scheduled_basal_program SET abandoned_at = ?
                WHERE consumed_by_sync_id IS NULL AND abandoned_at IS NULL AND requested_at < ?
                """,
            arguments: [atSeconds, atSeconds - window]
        )

        return ScheduledBasalIngestResult(
            minted: minted,
            abandonedPrograms: db.changesCount,
            unresolvedResumeSyncIdentifiers: unresolved
        )
    }

    private static func insertScheduledBasal(
        _ db: Database,
        resumeSyncIdentifier: String,
        effectiveAtSeconds: Double,
        rateUnitsPerHour: Double,
        source: ScheduledBasalRecord.Source,
        recordedAtSeconds: Double
    ) throws -> ScheduledBasalRecord {
        try db.execute(
            sql: """
                INSERT INTO scheduled_basal
                    (resume_sync_id, rate_units_per_hour, source, recorded_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(resume_sync_id) DO NOTHING
                """,
            arguments: [resumeSyncIdentifier, rateUnitsPerHour, source.rawValue, recordedAtSeconds]
        )
        return ScheduledBasalRecord(
            resumeSyncIdentifier: resumeSyncIdentifier,
            effectiveAt: Date(timeIntervalSince1970: effectiveAtSeconds),
            rateUnitsPerHour: rateUnitsPerHour,
            source: source,
            recordedAt: Date(timeIntervalSince1970: recordedAtSeconds)
        )
    }

    // MARK: - The timeline read (§6.1, §6.2)

    func timeline(windowStart: Date, at: Date, includeRevoked: Bool = false) async throws -> PumpDoseTimeline {
        do {
            return try await dbQueue.read { db in
                let windowStartSeconds = windowStart.timeIntervalSince1970
                let atSeconds = at.timeIntervalSince1970
                // Every ordinary read filters this; only the verifier's `R`
                // counterfactual asks for the revoked rows back.
                let liveOnly = includeRevoked ? "" : "AND deleted_at IS NULL"

                // Dose range reads test **overlap**, never `dose_start` alone: a
                // temp basal can begin before a window and deliver inside it.
                //
                // Suspend and resume are excluded here and nowhere else. That
                // exclusion is I3 — it is why the fabricated segment cannot be
                // constructed rather than merely unlikely — and it is why the
                // suspension state travels beside this array instead of in it.
                var doses = try Self.fetchDoseRows(
                    db,
                    sql: """
                        SELECT * FROM pump_event
                        WHERE dose_start IS NOT NULL
                          AND event_type NOT IN ('suspend','resume')
                          AND dose_end >= ? AND dose_start < ?
                          \(liveOnly)
                        ORDER BY dose_start, sync_identifier
                        """,
                    arguments: [windowStartSeconds, atSeconds]
                )

                // The over-fetch (decision 3): bounded by the last basal-ish
                // dose *before* the window rather than by a fixed duration.
                //
                // This is the correct solution to the problem
                // `getMostRecentStatefulOldEvents` was invented for. Both answer
                // "what was in flight when the window opens"; retaining three
                // markers past a prune answers it by keeping a fossil and then
                // mistaking the fossil for evidence, and over-fetching from a
                // complete store answers it with the real events and throws the
                // surplus away. LoopKit over-fetches the same way but caps it at
                // a flat 24 hours, which silently truncates the case the
                // over-fetch exists to handle — a pod that ran unattended for 40
                // hours — so we bound by the data instead.
                let anchor = try Self.fetchDoseRows(
                    db,
                    sql: """
                        SELECT * FROM pump_event
                        WHERE dose_start IS NOT NULL
                          AND event_type IN ('tempBasal','basal')
                          AND dose_end <= ?
                          \(liveOnly)
                        ORDER BY dose_end DESC, sync_identifier DESC
                        LIMIT 1
                        """,
                    arguments: [windowStartSeconds]
                )
                doses = (anchor + doses).sorted { $0.startDate < $1.startDate }

                // Where inference actually begins, which is the anchor's end and
                // not `windowStart`.
                //
                // The over-fetch above means the first gap can open *before* the
                // window, so suspension evidence has to reach back exactly as far
                // as dose evidence does. Cutting it off at `windowStart` instead
                // left `[anchorEnd, windowStart]` holding doses but no
                // suspensions, and inference filled that stretch at the scheduled
                // rate no matter what the pump had really been doing — which is
                // the same "assert delivery over a span we cannot see" mistake as
                // the fabrication, pointed at a smaller span.
                //
                // The anchor query bounds `dose_end <= windowStart`, so this can
                // only ever move the left edge earlier, never later.
                let inferenceStart = anchor.first?.endDate ?? windowStart
                let inferenceStartSeconds = inferenceStart.timeIntervalSince1970

                // State, from queries that may look arbitrarily far back (I3).
                // Asked at the inference edge rather than the window's, so that
                // this answer plus the transitions below determine the suspension
                // picture over the whole span inference covers, with no gap
                // between them: `<=` here, `>` there.
                let suspensionAtInferenceStart = try Self.fetchSuspensionState(db, atSeconds: inferenceStartSeconds)

                let transitions = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT event_type, date FROM pump_event
                        WHERE deleted_at IS NULL
                          AND event_type IN ('suspend','resume')
                          AND date > ? AND date <= ?
                        ORDER BY date, sync_identifier
                        """,
                    arguments: [inferenceStartSeconds, atSeconds]
                ).map { row in
                    PumpSuspensionTransition(
                        at: Date(timeIntervalSince1970: row["date"]),
                        isSuspended: (row["event_type"] as String) == PumpEventKind.suspend.rawValue
                    )
                }

                // The newest pulse size we hold. Per row rather than global,
                // because a pod change can change it.
                let smallestDeliveryUnit = try Double.fetchOne(
                    db,
                    sql: """
                        SELECT smallest_delivery_unit FROM pump_event
                        WHERE deleted_at IS NULL AND smallest_delivery_unit IS NOT NULL
                        ORDER BY date DESC, sync_identifier DESC
                        LIMIT 1
                        """
                ) ?? InsulinRecordStorePolicy.smallestDeliveryUnitDefault

                // What the pod was programmed with, in the same transaction as the
                // rows above so the two cannot disagree. Same I3 shape as
                // suspension, and for the same reason: the answer at the edge may
                // look arbitrarily far back, the answers inside may not.
                let scheduledBasal = try Self.fetchScheduledBasalHistory(
                    db,
                    inferenceStartSeconds: inferenceStartSeconds,
                    atSeconds: atSeconds
                )

                let state = try StoreStateRow.fetchOne(db, key: 0)

                return PumpDoseTimeline(
                    doses: doses,
                    suspensionAtInferenceStart: suspensionAtInferenceStart,
                    suspensionTransitions: transitions,
                    historyCompleteSince: Date(timeIntervalSince1970: state?.historyCompleteSince ?? windowStartSeconds),
                    lastReconciliation: state?.lastReconciliation.map { Date(timeIntervalSince1970: $0) },
                    windowStart: windowStart,
                    inferenceStart: inferenceStart,
                    at: at,
                    smallestDeliveryUnit: smallestDeliveryUnit,
                    scheduledBasal: scheduledBasal
                )
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("timeline read failed: \(error)")
        }
    }

    // MARK: - State queries (§6.3)

    func isSuspended(at: Date) async throws -> Bool {
        do {
            return try await dbQueue.read { db in
                try Self.fetchSuspensionState(db, atSeconds: at.timeIntervalSince1970)?.isSuspended ?? false
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("isSuspended failed: \(error)")
        }
    }

    func pumpAlarm(at: Date) async throws -> PumpAlarmType? {
        do {
            return try await dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT event_type, alarm_type FROM pump_event
                        WHERE deleted_at IS NULL
                          AND event_type IN ('alarm','alarmClear')
                          AND date <= ?
                        ORDER BY date DESC, sync_identifier DESC
                        LIMIT 1
                        """,
                    arguments: [at.timeIntervalSince1970]
                ) else { return nil }

                // A clear means there is no alarm, which is a different answer
                // from "we have never seen one" only to a reader of the log.
                guard (row["event_type"] as String) == PumpEventKind.alarm.rawValue else { return nil }
                guard let raw: String = row["alarm_type"] else { return nil }
                return PumpAlarmType(rawValue: raw)
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("pumpAlarm failed: \(error)")
        }
    }

    func currentInsulinType(at: Date) async throws -> InsulinType? {
        do {
            return try await dbQueue.read { db in
                let raw = try String.fetchOne(
                    db,
                    sql: """
                        SELECT insulin_type FROM pump_event
                        WHERE deleted_at IS NULL AND insulin_type IS NOT NULL AND date <= ?
                        ORDER BY date DESC, sync_identifier DESC
                        LIMIT 1
                        """,
                    arguments: [at.timeIntervalSince1970]
                )
                return raw.flatMap { AiInsulinType(rawValue: $0) }?.insulinType
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("currentInsulinType failed: \(error)")
        }
    }

    func activeBolus(at: Date) async throws -> DoseEntry? {
        do {
            return try await dbQueue.read { db in
                // Same predicate as the JSON path: strictly started, not yet
                // finished. A bolus whose window has closed is history.
                try Self.fetchDoseRows(
                    db,
                    sql: """
                        SELECT * FROM pump_event
                        WHERE deleted_at IS NULL
                          AND event_type = 'bolus'
                          AND dose_start < ? AND dose_end >= ?
                        ORDER BY dose_start, sync_identifier
                        """,
                    arguments: [at.timeIntervalSince1970, at.timeIntervalSince1970]
                ).last
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("activeBolus failed: \(error)")
        }
    }

    func lastReconciliation() async throws -> Date? {
        do {
            return try await dbQueue.read { db in
                try StoreStateRow.fetchOne(db, key: 0)?.lastReconciliation.map { Date(timeIntervalSince1970: $0) }
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("lastReconciliation failed: \(error)")
        }
    }

    func historyCompleteSince() async throws -> Date {
        do {
            return try await dbQueue.read { db in
                guard let state = try StoreStateRow.fetchOne(db, key: 0) else {
                    throw InsulinRecordStoreError.readFailed("store_state row is missing")
                }
                return Date(timeIntervalSince1970: state.historyCompleteSince)
            }
        } catch let error as InsulinRecordStoreError {
            throw error
        } catch {
            throw InsulinRecordStoreError.readFailed("historyCompleteSince failed: \(error)")
        }
    }

    // MARK: - Diagnostics

    func records(from: Date, to: Date, includeRevoked: Bool) async throws -> [PumpEventRecord] {
        do {
            return try await dbQueue.read { db in
                let deletedFilter = includeRevoked ? "" : "AND deleted_at IS NULL"
                return try PumpEventRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM pump_event
                        WHERE date >= ? AND date <= ? \(deletedFilter)
                        ORDER BY date, sync_identifier
                        """,
                    arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]
                ).map { $0.toDomain() }
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("records read failed: \(error)")
        }
    }

    func staleMutableDoses(at: Date) async throws -> [StaleMutableDose] {
        do {
            return try await dbQueue.read { db in
                let threshold = at.timeIntervalSince1970 - InsulinRecordStorePolicy.staleMutableDoseThreshold
                return try PumpEventRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM pump_event
                        WHERE deleted_at IS NULL
                          AND is_mutable = 1
                          AND dose_start IS NOT NULL
                          AND dose_start < ?
                        ORDER BY dose_start, sync_identifier
                        """,
                    arguments: [threshold]
                ).map { $0.toDomain() }.compactMap { record in
                    guard let doseStart = record.doseStart else { return nil }
                    return StaleMutableDose(
                        syncIdentifier: record.syncIdentifier,
                        doseStart: doseStart,
                        age: at.timeIntervalSince(doseStart),
                        // What it would contribute if counted, so the log says
                        // how much is at stake and not merely that something is
                        // stale.
                        units: record.deliveredUnits ?? record.programmedUnits ?? 0
                    )
                }
            }
        } catch {
            throw InsulinRecordStoreError.readFailed("staleMutableDoses failed: \(error)")
        }
    }

    // MARK: - Export

    /// `VACUUM INTO` rather than sharing the live file, and here the reason is
    /// stronger than it is for the verifier: `DatabaseQueue` uses a rollback
    /// journal, so the main file needs its `-journal` sidecar to open
    /// consistently, and a share sheet hands over one file whenever it likes. A
    /// database copied mid-transaction is one that opens and then lies — which,
    /// for the store on trial, is the failure mode of silent agreement.
    ///
    /// The snapshot lands in the store's own directory so it inherits
    /// `NSFileProtectionNone` (§8), which means it cannot reuse the live name.
    /// `pump_events.export.sqlite` is the same `.export.` convention the verifier
    /// uses, and `verify_pump_db.py` looks for both spellings. Overwritten each
    /// time rather than accumulating.
    func exportSnapshotURL() async -> URL? {
        guard let url else { return nil }
        let snapshot = url.deletingLastPathComponent()
            .appendingPathComponent("pump_events.export.sqlite", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: snapshot.path) {
                try FileManager.default.removeItem(at: snapshot)
            }
            try await dbQueue.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [snapshot.path])
            }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.none],
                ofItemAtPath: snapshot.path
            )
            return snapshot
        } catch {
            log.error("could not snapshot the record store: %{public}@", String(describing: error))
            return nil
        }
    }

    // MARK: - Fetch helpers (run inside an existing transaction)

    private nonisolated static func fetchDoseRows(
        _ db: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> [DoseEntry] {
        return try PumpEventRow.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            row.toDomain().doseEntry()
        }
    }

    /// The rate history over the span one derivation reaches: the newest record at
    /// or before the inference edge, plus every record inside `(edge, at]`.
    ///
    /// **The join is where `effective_at` comes from.** There is no such column —
    /// the record's instant is the resume's own `date`, so the rate and the
    /// boundary come from one row and cannot drift apart. That is the whole reason
    /// the table is keyed on `resume_sync_id`: an earlier design stored a copy and
    /// needed the two doubles to stay bit-identical for a boundary comparison to
    /// be correct.
    ///
    /// `e.deleted_at IS NULL` is what makes a revoked resume take its record with
    /// it. The row survives for diagnostics; it simply stops being history, which
    /// is right — a revoked resume means the program did not stick.
    private nonisolated static func fetchScheduledBasalHistory(
        _ db: Database,
        inferenceStartSeconds: Double,
        atSeconds: Double
    ) throws -> ScheduledBasalHistory {
        let columns = """
            SELECT sb.resume_sync_id      AS resume_sync_id,
                   e.date                 AS effective_at,
                   sb.rate_units_per_hour AS rate_units_per_hour,
                   sb.source              AS source,
                   sb.recorded_at         AS recorded_at
            FROM scheduled_basal sb
            JOIN pump_event e ON e.sync_identifier = sb.resume_sync_id
            WHERE e.deleted_at IS NULL
            """

        let anchor = try Row.fetchAll(
            db,
            sql: columns + """
                  AND e.date <= ?
                ORDER BY e.date DESC, e.sync_identifier DESC
                LIMIT 1
                """,
            arguments: [inferenceStartSeconds]
        )
        let inside = try Row.fetchAll(
            db,
            sql: columns + """
                  AND e.date > ? AND e.date <= ?
                ORDER BY e.date, e.sync_identifier
                """,
            arguments: [inferenceStartSeconds, atSeconds]
        )

        return ScheduledBasalHistory(records: (anchor + inside).map { row in
            ScheduledBasalRecord(
                resumeSyncIdentifier: row["resume_sync_id"],
                effectiveAt: Date(timeIntervalSince1970: row["effective_at"]),
                rateUnitsPerHour: row["rate_units_per_hour"],
                source: ScheduledBasalRecord.Source.from(rawValue: row["source"]),
                recordedAt: Date(timeIntervalSince1970: row["recorded_at"])
            )
        })
    }

    /// The latest suspend/resume at or before `atSeconds`, with no lower bound.
    ///
    /// Looking back past the window is the point: an old `resume` may be the only
    /// thing that says the pump is running. It is not, however, arbitrarily old —
    /// **every pod activation mints a resume**, via `programInitialBasalSchedule`
    /// into `PodCommsSession.setBasalSchedule`, and a schedule change on a live pod
    /// mints a suspend as well because `OmniPumpManager.setBasalSchedule` cancels
    /// all delivery first. So the marker is bounded by pod life, roughly 80 hours.
    /// (An earlier comment here said a pod change produces neither, which was
    /// wrong; see dev/backlog/scheduled-basal-history.md §2.1.)
    ///
    /// Nothing found means not suspended, which is the safe direction: it counts
    /// scheduled basal we may not have delivered, so IOB reads high and the loop
    /// doses less.
    ///
    /// Returns the transition rather than a bare Bool so a caller can ask what
    /// happened *after* it. `InsulinRecordTimeline.suspendedAtInferenceStart`
    /// needs that: delivery after an unresumed suspend is evidence the pump
    /// resumed without saying so. Carrying the instant is also what lets the
    /// derivation put a gap's left edge on a resume that fell below the window.
    private nonisolated static func fetchSuspensionState(
        _ db: Database,
        atSeconds: Double
    ) throws -> PumpSuspensionTransition? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT event_type, date FROM pump_event
                WHERE deleted_at IS NULL
                  AND event_type IN ('suspend','resume')
                  AND date <= ?
                ORDER BY date DESC, sync_identifier DESC
                LIMIT 1
                """,
            arguments: [atSeconds]
        ) else { return nil }

        return PumpSuspensionTransition(
            at: Date(timeIntervalSince1970: row["date"]),
            isSuspended: (row["event_type"] as String) == PumpEventKind.suspend.rawValue
        )
    }
}
