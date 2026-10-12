//
//  GRDBLoopRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/16/26.
//
//  The GRDB implementation of `LoopRecordStore`.
//
//  Structured to match the other three stores: private row structs, raw-SQL
//  schema, epoch-second dates, its own directory carrying `NSFileProtectionNone`.
//
//  Epoch seconds rather than GRDB's default ISO-8601 text, for the same reason
//  as the others: retention and the ledger's window are numeric range
//  comparisons, and text dates make those compare lexicographically in ways that
//  don't error.
//
//  **Where this file departs from its siblings:** the alert and insulin stores
//  write with raw `INSERT` statements. A `loop_result` row is 27 columns, 22 of
//  them `Double?`, and a positional argument list of that shape has one bug in
//  it that no compiler catches and no eyeball reliably does — `pid_ki`'s value
//  landing in `pid_kd`. So writes go through `PersistableRecord`, which derives
//  the column names from the struct's field names, and the misalignment stops
//  being expressible. Reads use the same struct.
//

import Foundation
import GRDB

actor GRDBLoopRecordStore: LoopRecordStore {

    // MARK: - The rows (private — never cross the protocol boundary)

    /// One loop tick.
    ///
    /// Field names map to columns by `convertToSnakeCase` in both directions, so
    /// `pidBasalRateIob` is `pid_basal_rate_iob`. Everything below `outcome` is
    /// optional because a `.skipped` tick never reached the pipeline and has
    /// none of it.
    private struct LoopResultRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "loop_result"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        /// nil on insert, where SQLite assigns it.
        var id: Int64?
        var at: Double
        var outcome: String
        var skipReason: String?

        var decisionKind: String?
        var decisionTempBasalUPerHr: Double?
        var decisionMicroBolusUnits: Double?
        var decisionSuspendMgDlPerHr: Double?

        var glucoseMgDl: Double?
        var insulinOnBoard: Double?

        var insulinSensitivity: Double?
        var basalRate: Double?
        var predictedAddedGlucoseMgDlPerHr: Double?
        var mlInsulinLastThreeHours: Double?

        var physiologicalTempBasal: Double?
        var mlTempBasal: Double?
        var physiologicalMicroBolus: Double?
        var mlMicroBolus: Double?

        var pidAt: Double?
        var pidKp: Double?
        var pidKi: Double?
        var pidKd: Double?
        var pidFilteredGlucose: Double?
        var pidError: Double?
        var pidAccumulatedError: Double?
        var pidDerivative: Double?
        var pidDeltaGlucoseError: Double?
        var pidBasalRateIob: Double?

        init(_ record: LoopRecord) {
            self.id = nil
            self.at = record.at.timeIntervalSince1970

            switch record.outcome {
            case .skipped(let reason):
                self.outcome = "skipped"
                self.skipReason = reason.rawValue
            case .dosed:
                self.outcome = "dosed"
                self.skipReason = nil
            case .pumpError:
                self.outcome = "pumpError"
                self.skipReason = nil
            }

            guard let snapshot = record.outcome.snapshot else { return }

            switch snapshot.decision {
            case .tempBasal(let unitsPerHour):
                self.decisionKind = "tempBasal"
                self.decisionTempBasalUPerHr = unitsPerHour
            case .microBolus(let units):
                self.decisionKind = "microBolus"
                self.decisionMicroBolusUnits = units
            case .suspendForBiologicalInvariant(let mgDlPerHour):
                self.decisionKind = "suspendForBiologicalInvariant"
                self.decisionSuspendMgDlPerHr = mgDlPerHour
            }

            self.glucoseMgDl = snapshot.glucoseInMgDl
            self.insulinOnBoard = snapshot.insulinOnBoard

            self.insulinSensitivity = snapshot.insulinSensitivity
            self.basalRate = snapshot.basalRate
            self.predictedAddedGlucoseMgDlPerHr = snapshot.predictedAddedGlucoseInMgDlPerHour
            self.mlInsulinLastThreeHours = snapshot.machineLearningInsulinLastThreeHours

            self.physiologicalTempBasal = snapshot.candidates.physiologicalTempBasal
            self.mlTempBasal = snapshot.candidates.mlTempBasal
            self.physiologicalMicroBolus = snapshot.candidates.physiologicalMicroBolus
            self.mlMicroBolus = snapshot.candidates.mlMicroBolus

            self.pidAt = snapshot.pid.at.timeIntervalSince1970
            self.pidKp = snapshot.pid.Kp
            self.pidKi = snapshot.pid.Ki
            self.pidKd = snapshot.pid.Kd
            self.pidFilteredGlucose = snapshot.pid.filteredGlucose
            self.pidError = snapshot.pid.error
            self.pidAccumulatedError = snapshot.pid.accumulatedError
            self.pidDerivative = snapshot.pid.derivative
            self.pidDeltaGlucoseError = snapshot.pid.deltaGlucoseError
            self.pidBasalRateIob = snapshot.pid.basalRateInsulinOnBoard
        }

        /// nil when the row does not describe a loop tick this build understands
        /// — an unknown outcome or skip reason, or a dosed row missing a column
        /// the domain type requires.
        ///
        /// Dropped rather than allowed to fail the query around it, the same rule
        /// the alert store's blob decode follows: one row written by a build whose
        /// shape has since changed must not cost us the rows either side of it.
        /// The caller logs the count.
        func toDomain() -> LoopRecord? {
            let at = Date(timeIntervalSince1970: self.at)
            switch outcome {
            case "skipped":
                guard let skipReason, let reason = SkipReason(rawValue: skipReason) else { return nil }
                return LoopRecord(at: at, outcome: .skipped(reason))
            case "dosed":
                guard let snapshot = toSnapshot() else { return nil }
                return LoopRecord(at: at, outcome: .dosed(snapshot))
            case "pumpError":
                guard let snapshot = toSnapshot() else { return nil }
                return LoopRecord(at: at, outcome: .pumpError(attempted: snapshot))
            default:
                return nil
            }
        }

        private func toSnapshot() -> LoopRecordSnapshot? {
            guard let decision = toDecision(),
                  let glucoseMgDl,
                  let insulinOnBoard,
                  let insulinSensitivity,
                  let basalRate,
                  let predictedAddedGlucoseMgDlPerHr,
                  let mlInsulinLastThreeHours,
                  let physiologicalTempBasal,
                  let mlTempBasal,
                  let physiologicalMicroBolus,
                  let mlMicroBolus,
                  let pidAt,
                  let pidKp,
                  let pidKi,
                  let pidKd,
                  let pidFilteredGlucose,
                  let pidError,
                  let pidAccumulatedError
            else { return nil }

            return LoopRecordSnapshot(
                glucoseInMgDl: glucoseMgDl,
                insulinOnBoard: insulinOnBoard,
                insulinSensitivity: insulinSensitivity,
                basalRate: basalRate,
                predictedAddedGlucoseInMgDlPerHour: predictedAddedGlucoseMgDlPerHr,
                machineLearningInsulinLastThreeHours: mlInsulinLastThreeHours,
                decision: decision,
                candidates: DoseCandidates(
                    physiologicalTempBasal: physiologicalTempBasal,
                    mlTempBasal: mlTempBasal,
                    physiologicalMicroBolus: physiologicalMicroBolus,
                    mlMicroBolus: mlMicroBolus
                ),
                pid: LoopRecordPID(
                    at: Date(timeIntervalSince1970: pidAt),
                    Kp: pidKp,
                    Ki: pidKi,
                    Kd: pidKd,
                    filteredGlucose: pidFilteredGlucose,
                    error: pidError,
                    accumulatedError: pidAccumulatedError,
                    derivative: pidDerivative,
                    deltaGlucoseError: pidDeltaGlucoseError,
                    basalRateInsulinOnBoard: pidBasalRateIob
                )
            )
        }

        private func toDecision() -> DosingDecision? {
            switch decisionKind {
            case "tempBasal":
                guard let decisionTempBasalUPerHr else { return nil }
                return .tempBasal(unitsPerHour: decisionTempBasalUPerHr)
            case "microBolus":
                guard let decisionMicroBolusUnits else { return nil }
                return .microBolus(units: decisionMicroBolusUnits)
            case "suspendForBiologicalInvariant":
                guard let decisionSuspendMgDlPerHr else { return nil }
                return .suspendForBiologicalInvariant(mgDlPerHour: decisionSuspendMgDlPerHr)
            default:
                return nil
            }
        }
    }

    /// One entry in the machine-learning insulin budget ledger.
    private struct SafetyStateRow: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "safety_state"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var id: Int64?
        /// `NOT NULL` in the schema, which is the invariant: a safety state
        /// cannot exist without the loop result it belongs to.
        var loopResultId: Int64
        var at: Double
        var duration: Double
        var kind: String
        /// Both NULL exactly when `kind` is `suspended`.
        var programmed: Double?
        var physiological: Double?

        init(_ state: SafetyState, loopResultId: Int64) {
            self.id = nil
            self.loopResultId = loopResultId
            self.at = state.at.timeIntervalSince1970
            self.duration = state.duration
            switch state.kind {
            case .tempBasal(let programmed, let physiological):
                self.kind = "tempBasal"
                self.programmed = programmed
                self.physiological = physiological
            case .microBolus(let programmed, let physiological):
                self.kind = "microBolus"
                self.programmed = programmed
                self.physiological = physiological
            case .suspended:
                self.kind = "suspended"
            }
        }

        func toDomain() -> SafetyState? {
            let resolved: SafetyState.Kind
            switch kind {
            case "tempBasal":
                guard let programmed, let physiological else { return nil }
                resolved = .tempBasal(programmed: programmed, physiological: physiological)
            case "microBolus":
                guard let programmed, let physiological else { return nil }
                resolved = .microBolus(programmed: programmed, physiological: physiological)
            case "suspended":
                resolved = .suspended
            default:
                return nil
            }
            return SafetyState(at: Date(timeIntervalSince1970: at), duration: duration, kind: resolved)
        }
    }

    /// The one-row singleton table, in the same database so it shares the
    /// transaction and the file-protection class.
    private struct StoreStateRow: Codable, FetchableRecord {
        static let databaseTableName = "store_state"
        static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
        static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

        var id: Int64
        var createdAt: Double
        /// Before this instant the ledger cannot account for what was delivered.
        /// Separate from `createdAt` so that if a seed is ever added it can move
        /// backwards without lying about when the store was made.
        var safetyHistoryCompleteSince: Double
    }

    // MARK: - State

    private let dbQueue: DatabaseQueue
    /// nil for the in-memory store, which has no file to snapshot.
    private let url: URL?
    private let log = DiagnosticLog(category: "LoopRecordStore")

    // MARK: - Init

    /// - Parameter createdAt: the store's creation instant, which becomes the
    ///   initial `safety_history_complete_since`. Injected rather than read from
    ///   the clock so the fail-closed window is testable.
    init(url: URL, createdAt: Date) throws {
        // Per GRDB's guidance each database lives in its OWN directory, so the
        // main file, the journal sidecar, and SQLite's temp files stay together
        // and inherit the directory's protection class.
        //
        // `NSFileProtectionNone` is not optional bookkeeping here. The app is
        // woken by CGM Bluetooth before first unlock, and a protected database
        // fails to open exactly on the wake path where a loop would otherwise
        // run — which for this store means the ledger read fails and the ML
        // budget is refused for the rest of the boot.
        do {
            try Self.makeUnprotectedDirectory(at: url.deletingLastPathComponent())
        } catch {
            throw LoopRecordStoreError.couldNotOpen("could not create the store directory: \(error)")
        }

        do {
            self.dbQueue = try DatabaseQueue(path: url.path, configuration: Configuration())
        } catch {
            throw LoopRecordStoreError.couldNotOpen("could not open \(url.lastPathComponent): \(error)")
        }
        self.url = url

        try Self.prepare(dbQueue, createdAt: createdAt)
    }

    /// In-memory store for tests, so nothing here touches a file system.
    init(inMemoryCreatedAt createdAt: Date) throws {
        do {
            self.dbQueue = try DatabaseQueue()
        } catch {
            throw LoopRecordStoreError.couldNotOpen("could not open an in-memory database: \(error)")
        }
        self.url = nil
        try Self.prepare(dbQueue, createdAt: createdAt)
    }

    private static func prepare(_ dbQueue: DatabaseQueue, createdAt: Date) throws {
        do {
            try migrator().migrate(dbQueue)
            try dbQueue.write { db in
                // Seeded once. `INSERT OR IGNORE` rather than an upsert: on every
                // launch after the first, these are already the right answers,
                // and rewriting `safety_history_complete_since` would re-open the
                // fail-closed window on every launch — which for a store that
                // reopens on each background wake means the ML budget would be
                // refused essentially forever.
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO store_state
                            (id, created_at, safety_history_complete_since)
                        VALUES (0, ?, ?)
                        """,
                    arguments: [createdAt.timeIntervalSince1970, createdAt.timeIntervalSince1970]
                )
            }
        } catch {
            throw LoopRecordStoreError.couldNotOpen("could not migrate the store: \(error)")
        }

        // `safety_state.loop_result_id` and the `ON DELETE CASCADE` that makes
        // retention a single DELETE are both worth exactly as much as this
        // pragma. GRDB turns it on by default; assert it rather than assume it,
        // because the failure is silent in both directions — orphan rows on the
        // way in, stranded rows on the way out.
        do {
            let enabled = try dbQueue.read { db in
                try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false
            }
            guard enabled else {
                throw LoopRecordStoreError.couldNotOpen("foreign key enforcement is off")
            }
        } catch let error as LoopRecordStoreError {
            throw error
        } catch {
            throw LoopRecordStoreError.couldNotOpen("could not check foreign key enforcement: \(error)")
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

    /// `Documents/LoopRecordStore/loop_records.sqlite`. Its own directory, per
    /// the rule above.
    static func defaultURL() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return documents
            .appendingPathComponent("LoopRecordStore", isDirectory: true)
            .appendingPathComponent("loop_records.sqlite", isDirectory: false)
    }

    // MARK: - Migrations

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // No import of either JSON file, the same straight cut the alert
            // store took. For `closed_loop_results.json` the cost is a blank
            // chart for a day and one possibly-early micro bolus. For
            // `safety_states.json` the cost would be much higher — an empty
            // ledger reads as a full ML budget — which is what
            // `safety_history_complete_since` below exists to prevent, and it
            // covers every other way of arriving at an empty ledger too, not
            // just this one upgrade.
            try db.execute(sql: """
                CREATE TABLE loop_result (
                  id                            INTEGER PRIMARY KEY AUTOINCREMENT,
                  at                            DOUBLE NOT NULL,  -- epoch seconds; the tick instant
                  outcome                       TEXT NOT NULL,    -- 'skipped' | 'dosed' | 'pumpError'
                  skip_reason                   TEXT,             -- non-NULL iff outcome = 'skipped'

                  -- The decision. NULL for skipped rows, which never reached the pipeline.
                  decision_kind                 TEXT,             -- 'tempBasal' | 'microBolus' | 'suspendForBiologicalInvariant'
                  decision_temp_basal_u_per_hr  DOUBLE,
                  decision_micro_bolus_units    DOUBLE,
                  decision_suspend_mg_dl_per_hr DOUBLE,

                  -- LoopSnapshotInputs
                  glucose_mg_dl                 DOUBLE,
                  insulin_on_board              DOUBLE,

                  -- PipelineOutputs, the read-back subset
                  insulin_sensitivity           DOUBLE,
                  basal_rate                    DOUBLE,
                  predicted_added_glucose_mg_dl_per_hr DOUBLE,
                  ml_insulin_last_three_hours   DOUBLE,

                  -- DoseCandidates
                  physiological_temp_basal      DOUBLE,
                  ml_temp_basal                 DOUBLE,
                  physiological_micro_bolus     DOUBLE,
                  ml_micro_bolus                DOUBLE,

                  -- PIDTempBasalResult, the read-back subset
                  pid_at                        DOUBLE,
                  pid_kp                        DOUBLE,
                  pid_ki                        DOUBLE,
                  pid_kd                        DOUBLE,
                  pid_filtered_glucose          DOUBLE,
                  pid_error                     DOUBLE,
                  pid_accumulated_error         DOUBLE,
                  pid_derivative                DOUBLE,   -- optional in the domain type
                  pid_delta_glucose_error       DOUBLE,   -- optional in the domain type
                  pid_basal_rate_iob            DOUBLE    -- optional in the domain type
                )
                """)

            // `id AUTOINCREMENT` rather than `at` as the primary key: `at` comes
            // from a `Date()` at the call site and nothing guarantees it is
            // unique across two ticks. It also gives `safety_state` something
            // stable to reference and gives reads a total order when two rows
            // share an instant.
            try db.execute(sql: "CREATE INDEX idx_loop_result_at ON loop_result(at)")

            // The one dosing-path read. A partial index so the scan is over
            // micro-bolus ticks only, not every row.
            try db.execute(sql: """
                CREATE INDEX idx_loop_result_micro_bolus ON loop_result(at)
                  WHERE outcome = 'dosed' AND decision_kind = 'microBolus'
                """)

            try db.execute(sql: """
                CREATE TABLE safety_state (
                  id             INTEGER PRIMARY KEY AUTOINCREMENT,
                  loop_result_id INTEGER NOT NULL
                                 REFERENCES loop_result(id) ON DELETE CASCADE,
                  at             DOUBLE NOT NULL,  -- epoch seconds
                  duration       DOUBLE NOT NULL,  -- the programmed correction duration
                  kind           TEXT NOT NULL,    -- 'tempBasal' | 'microBolus' | 'suspended'
                  programmed     DOUBLE,           -- NULL iff kind = 'suspended'
                  physiological  DOUBLE            -- NULL iff kind = 'suspended'
                )
                """)

            try db.execute(sql: "CREATE INDEX idx_safety_state_at ON safety_state(at)")

            try db.execute(sql: """
                CREATE TABLE store_state (
                  id                            INTEGER PRIMARY KEY,  -- always 0
                  created_at                    DOUBLE NOT NULL,
                  safety_history_complete_since DOUBLE NOT NULL
                )
                """)
        }

        return migrator
    }

    // MARK: - Writes

    func record(_ record: LoopRecord, safetyState: SafetyState?, at: Date) async throws {
        do {
            let pruned = try await dbQueue.write { db -> Int in
                var row = LoopResultRow(record)
                try row.insert(db)
                if let safetyState {
                    var stateRow = SafetyStateRow(safetyState, loopResultId: db.lastInsertedRowID)
                    try stateRow.insert(db)
                }
                return try Self.runRetention(db, at: at)
            }
            if pruned > 0 {
                log.default("retention pruned %d loop result(s)", pruned)
            }
        } catch {
            throw LoopRecordStoreError.writeFailed("could not store a loop record: \(error)")
        }
    }

    // MARK: - Retention

    /// Hard-deletes loop results past the horizon. `safety_state` follows via
    /// `ON DELETE CASCADE`, which is why both tables share one horizon and why
    /// this is a single statement.
    ///
    /// `changesCount` reports rows the DELETE itself removed; SQLite does not
    /// count cascade deletes there, so this is a count of loop results.
    private static func runRetention(_ db: Database, at: Date) throws -> Int {
        let cutoff = at.timeIntervalSince1970 - LoopRecordStorePolicy.retention
        try db.execute(sql: "DELETE FROM loop_result WHERE at < ?", arguments: [cutoff])
        return db.changesCount
    }

    // MARK: - Reads: the dosing path

    func lastMicroBolus() async throws -> Date? {
        do {
            return try await dbQueue.read { db in
                try Double.fetchOne(
                    db,
                    sql: """
                        SELECT at FROM loop_result
                        WHERE outcome = 'dosed' AND decision_kind = 'microBolus'
                        ORDER BY at DESC LIMIT 1
                        """
                ).map { Date(timeIntervalSince1970: $0) }
            }
        } catch {
            throw LoopRecordStoreError.readFailed("lastMicroBolus failed: \(error)")
        }
    }

    func safetyStates(from: Date, to: Date) async throws -> [SafetyState] {
        // The completeness check is bundled with the read, deliberately. Every
        // way of failing to answer this question — no store, a failed query, a
        // window older than the store — has to reach the same conservative
        // branch in `LocalSafetyService`, and bundling means there is one place
        // that can be forgotten instead of two.
        //
        // The guard is on `from` rather than on `to - safetyTimeHorizon`, which
        // is one `duration` stricter than §8 of the doc writes it. `from` is the
        // left edge of the span the tally actually reads: a temp basal that
        // *began* before the horizon can still have been running inside it, which
        // is exactly why the query reaches back that far. Guarding the narrower
        // span would declare the ledger complete over a window it cannot see all
        // of. The cost is that the fail-closed window after a cutover is a
        // correction duration longer, and it still heals on its own.
        let completeSince = try await safetyHistoryCompleteSince()
        guard from >= completeSince else {
            throw LoopRecordStoreError.historyIncomplete(
                "the ledger starts at \(completeSince) and the window opens at \(from)"
            )
        }

        let rows: [SafetyStateRow]
        do {
            rows = try await dbQueue.read { db in
                try SafetyStateRow.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM safety_state
                        WHERE at >= ? AND at < ?
                        ORDER BY at, id
                        """,
                    arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970]
                )
            }
        } catch {
            throw LoopRecordStoreError.readFailed("safetyStates failed: \(error)")
        }

        let states = rows.compactMap { $0.toDomain() }
        guard states.count == rows.count else {
            // Silently dropping a ledger row would under-count the budget and
            // grant deviation authority that was already spent, so unlike the
            // chart reads this one refuses rather than returning what it could
            // decode.
            throw LoopRecordStoreError.readFailed(
                "could not decode \(rows.count - states.count) of \(rows.count) safety state(s)"
            )
        }
        return states
    }

    /// The instant before which the ledger cannot account for what was
    /// delivered. Self-healing: `safetyTimeHorizon` after the store is created
    /// this stops mattering and never matters again.
    private func safetyHistoryCompleteSince() async throws -> Date {
        do {
            return try await dbQueue.read { db in
                guard let state = try StoreStateRow.fetchOne(db, sql: "SELECT * FROM store_state WHERE id = 0") else {
                    throw LoopRecordStoreError.readFailed("store_state row is missing")
                }
                return Date(timeIntervalSince1970: state.safetyHistoryCompleteSince)
            }
        } catch let error as LoopRecordStoreError {
            throw error
        } catch {
            throw LoopRecordStoreError.readFailed("safetyHistoryCompleteSince failed: \(error)")
        }
    }

    // MARK: - Reads: the chart path

    func records(since: Date) async throws -> [LoopRecord] {
        let rows: [LoopResultRow]
        do {
            rows = try await dbQueue.read { db in
                try LoopResultRow.fetchAll(
                    db,
                    sql: "SELECT * FROM loop_result WHERE at >= ? ORDER BY at, id",
                    arguments: [since.timeIntervalSince1970]
                )
            }
        } catch {
            throw LoopRecordStoreError.readFailed("records(since:) failed: \(error)")
        }
        return decode(rows)
    }

    func latestRecord() async throws -> LoopRecord? {
        do {
            return try await dbQueue.read { db in
                try LoopResultRow.fetchOne(
                    db,
                    sql: "SELECT * FROM loop_result ORDER BY at DESC, id DESC LIMIT 1"
                )?.toDomain()
            }
        } catch {
            throw LoopRecordStoreError.readFailed("latestRecord failed: \(error)")
        }
    }

    func filteredGlucose(since: Date) async throws -> [FilteredGlucose] {
        // Two columns rather than a projection of `records(since:)`. `pid_at IS
        // NOT NULL` is the same predicate as "this tick reached the pipeline",
        // which is what the array version expressed as `outcome.snapshot != nil`.
        do {
            return try await dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT pid_at, pid_filtered_glucose FROM loop_result
                        WHERE at >= ? AND pid_at IS NOT NULL
                        ORDER BY pid_at
                        """,
                    arguments: [since.timeIntervalSince1970]
                ).compactMap { row -> FilteredGlucose? in
                    guard let at: Double = row["pid_at"],
                          let glucose: Double = row["pid_filtered_glucose"] else { return nil }
                    return FilteredGlucose(glucose: glucose, at: Date(timeIntervalSince1970: at))
                }
            }
        } catch {
            throw LoopRecordStoreError.readFailed("filteredGlucose(since:) failed: \(error)")
        }
    }

    private func decode(_ rows: [LoopResultRow]) -> [LoopRecord] {
        let records = rows.compactMap { $0.toDomain() }
        if records.count != rows.count {
            log.error("dropped %d undecodable loop result row(s)", rows.count - records.count)
        }
        return records
    }

    // MARK: - Export

    /// `VACUUM INTO` rather than sharing the live file: `DatabaseQueue` uses a
    /// rollback journal, so the main file needs its `-journal` sidecar to open
    /// consistently, and a share sheet hands over one file whenever it likes.
    ///
    /// The snapshot lands in the store's own directory so it inherits
    /// `NSFileProtectionNone`, which means it cannot reuse the live name.
    /// Overwritten each time rather than accumulating.
    func exportSnapshotURL() async -> URL? {
        guard let url else { return nil }
        let snapshot = url.deletingLastPathComponent()
            .appendingPathComponent("loop_records.export.sqlite", isDirectory: false)
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
            log.error("could not snapshot the loop record store: %{public}@", String(describing: error))
            return nil
        }
    }
}
