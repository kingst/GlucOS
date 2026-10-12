//
//  AiInterfaceStorage.swift
//  BioKernel
//
//  Created by Sam King on 8/1/26.
//
//  Publishes GlucOS's insulin delivery history and its CGM readings into the
//  shared app-group container for AI apps to read, plus the marker that says
//  which CGM reading GlucOS has finished looping on. See dev/ai-interface.md for
//  the format and dev/backlog/ai-interface-prompt.md §6 for the insulin half's
//  implementation notes.
//
//  The rule that shapes everything here: a record may be appended to a daily
//  file only when it can never change again. Once a line is in a `.jsonl` file
//  we can't take it back, so anything still in motion stays in
//  `current_insulin_dosing.json` where it gets rewritten every pass.
//
//  Which is why glucose is the easy half — a CGM reading arrives once, immutable,
//  already carrying its own identifier, so it is appendable the moment we see it
//  and there is no `current` equivalent for it at all.
//

import Foundation
import HealthKit
import LoopKit

protocol AiInterfaceStorage {
    /// - Parameter pump: nil when no pump has reported yet this session, e.g.
    ///   the launch pass. The exporter falls back to the last metadata it
    ///   persisted; if it has never seen a pump at all it publishes nothing,
    ///   because it cannot mint stable ids without one.
    func exportInsulinDosing(
        doses: [DoseEntry],
        scheduledBasalRateUnitsPerHour: Double,
        pump: PumpMetadata?,
        at: Date
    ) async

    /// Appends CGM readings to `glucose.<UTC_DAY>.jsonl`.
    ///
    /// - Parameter readings: readings the store holds, in any order and with any
    ///   overlap with what has already been published — the ledger keeps a
    ///   reading to one line. Callers are expected to offer more than they think
    ///   is new, since that is what turns a failed append into a retry rather
    ///   than a hole in the file.
    func exportGlucose(readings: [NewGlucoseSample], at: Date) async

    /// Records that a loop ran on the CGM reading measured at `cgmReadingAt` and
    /// has finished issuing the pump commands it decided on, and republishes
    /// `current_insulin_dosing.json` so an AI app polling it sees the marker
    /// without waiting for the next pump sync.
    ///
    /// Only called when there were commands to set: a skipped or failed run
    /// leaves the previous marker standing, which is what "GlucOS did not act on
    /// that reading" looks like to a reader.
    func recordCgmTickHandled(cgmReadingAt: Date, at: Date) async

    /// Deletes everything GlucOS has published and clears the dedup ledger, so
    /// the next pass republishes from scratch. For the diagnostics UI — the
    /// shared container isn't reachable from Xcode or `devicectl`, so this is
    /// the only way to clear it.
    func resetPublishedData() async
}

/// Dedup ledger, persisted in the app's own documents directory rather than the
/// shared container — it is our bookkeeping, not published data.
struct AiExportState: Codable {
    /// Ledger key -> when we appended it. Gates every append, so nothing is ever
    /// written twice across a restart.
    ///
    /// Keyed by `LocalAiInterfaceStorage.ledgerKey(for:)` rather than by the
    /// published id, which carries a pump-plugin namespace that can change.
    var exportedIds: [String: Double] = [:]
    /// The same, for glucose, keyed by the CGM's `syncIdentifier`.
    ///
    /// Its own dictionary rather than a shared one: the two id spaces come from
    /// different devices and are only unique within themselves, so a collision
    /// across them would silently drop a reading or a dose.
    var exportedGlucoseIds: [String: Double] = [:]
    /// Survives a relaunch with no pump connected, so records keep their
    /// insulin/pump pairing even before the first sync of a session.
    var lastPumpMetadata: PumpMetadata?
    /// The UTC day retention last ran for, so pruning happens at most once a day.
    var lastRetentionDay: String?
    /// The CGM timestamp published as `lastCgmTickHandledAt`, as epoch seconds.
    ///
    /// Persisted so a relaunch republishes the marker it was last standing on
    /// rather than dropping it until the next loop — a reader watching it go
    /// backwards or vanish has no way to tell that from GlucOS re-handling an
    /// older reading.
    var lastCgmTickHandledAt: Double?

    /// Comfortably past the 24-hour pump event log, so a pruned id can never
    /// come back and be re-appended. The daily files keep 90 days; this ledger
    /// only has to outlive the window in which a record could reappear.
    ///
    /// For glucose that window is whatever the caller re-offers, which is
    /// `LocalGlucoseStorage.aiInterfaceCatchUpWindow` — hours, not days.
    static let ledgerRetention = 7.0.daysToSeconds()
}

actor LocalAiInterfaceStorage: AiInterfaceStorage {
    private let container: AiInterfaceContainer?
    private let stateStorage: StoredObject
    private let log = DiagnosticLog(category: "AiInterfaceStorage")

    private var state = AiExportState()
    private var hasReadStateFromDisk = false
    private var hasLoggedMissingContainer = false
    private var hasReassertedFileProtection = false
    private var lastExportAt: Date?
    /// What we last wrote to `current_insulin_dosing.json`.
    ///
    /// The CGM tick path has to rewrite that file to publish its marker, and the
    /// dosing half of the object is none of its business — it has seen no pump
    /// events. Rather than rebuild a timeline it doesn't have, it reuses this.
    private var lastPublishedCurrent: CurrentInsulinDosing?

    init(container: AiInterfaceContainer?, stateStorage: StoredObject) {
        self.container = container
        self.stateStorage = stateStorage
    }

    // MARK: - Export

    func exportInsulinDosing(
        doses: [DoseEntry],
        scheduledBasalRateUnitsPerHour: Double,
        pump: PumpMetadata?,
        at: Date
    ) async {
        guard let container else {
            // A signing regression takes the app group away. Say so once and
            // keep looping — publishing is never allowed to be load-bearing.
            if !hasLoggedMissingContainer {
                hasLoggedMissingContainer = true
                log.error("no app group container; skipping insulin dosing export")
            }
            return
        }

        // Callers fire these off without awaiting so the loop is never delayed,
        // which means two passes can land out of order. A strictly older pass
        // has nothing a newer one hasn't already written, and letting it run
        // would walk `current_insulin_dosing.json` and its `updatedAt`
        // backwards. Equal timestamps still run — the ledger makes that a no-op.
        if let lastExportAt, at < lastExportAt { return }

        readStateFromDisk()

        // Ids are namespaced by the pump's plugin identifier, so without pump
        // metadata we cannot mint a stable one. Publishing under a placeholder
        // and re-publishing under the real namespace once the pump reports
        // would put every dose in the file twice under two different ids, which
        // the ledger can't catch and a reader would sum as double the insulin.
        //
        // So a launch pass before the very first pump sync of a fresh install
        // publishes nothing. The next sync, a few minutes later, publishes the
        // whole backfill correctly.
        guard let effectivePump = pump ?? state.lastPumpMetadata else {
            log.default("no pump metadata yet; deferring export until the pump reports")
            return
        }

        lastExportAt = at
        state.lastPumpMetadata = effectivePump

        reassertFileProtectionOnce(container: container)

        let export = Self.buildExport(
            doses: doses,
            scheduledBasalRateUnitsPerHour: scheduledBasalRateUnitsPerHour,
            pump: effectivePump,
            alreadyExported: Set(state.exportedIds.keys),
            at: at,
            // Carried through from the loop's own path so an export never drops a
            // marker the tick path published.
            lastCgmTickHandledAt: state.lastCgmTickHandledAt.map { Date(timeIntervalSince1970: $0) },
            log: log
        )

        // Append first, then rewrite current. A reader landing between the two
        // sees a record in both files and over-counts IoB for a few
        // milliseconds; the other order can under-count, which would make an AI
        // dose more.
        appendFinalized(export.newlyFinalized, to: container, at: at)
        writeCurrent(export.current, to: container)

        runRetentionIfNeeded(container: container, at: at)
        pruneLedger(at: at)
        writeStateToDisk()
    }

    func exportGlucose(readings: [NewGlucoseSample], at: Date) async {
        guard let container else {
            if !hasLoggedMissingContainer {
                hasLoggedMissingContainer = true
                log.error("no app group container; skipping glucose export")
            }
            return
        }

        readStateFromDisk()
        reassertFileProtectionOnce(container: container)

        // No pass-ordering guard, unlike the insulin export: this path only ever
        // appends, and the ledger already makes a second look at the same reading
        // a no-op, so an older pass landing late has nothing to walk backwards.
        appendGlucose(Self.newGlucoseRecords(
            readings: readings,
            alreadyExported: Set(state.exportedGlucoseIds.keys)
        ), to: container, at: at)

        runRetentionIfNeeded(container: container, at: at)
        pruneLedger(at: at)
        writeStateToDisk()
    }

    /// The readings we have not published yet, oldest first.
    ///
    /// Sorted rather than left in whatever order the caller passed, so the file
    /// reads chronologically for the usual case where nothing was dropped, and
    /// deduplicated within the batch as well as against the ledger, because
    /// callers deliberately hand us overlapping lists.
    static func newGlucoseRecords(
        readings: [NewGlucoseSample],
        alreadyExported: Set<String>
    ) -> [GlucoseRecord] {
        var seen = alreadyExported
        return readings
            .sorted { $0.date < $1.date }
            .compactMap { reading in
                guard seen.insert(reading.syncIdentifier).inserted else { return nil }
                return GlucoseRecord(
                    id: reading.syncIdentifier,
                    measuredAt: reading.date,
                    glucoseInMgDl: reading.quantity.doubleValue(for: .milligramsPerDeciliter)
                )
            }
    }

    // MARK: - CGM tick

    func recordCgmTickHandled(cgmReadingAt: Date, at: Date) async {
        guard let container else {
            if !hasLoggedMissingContainer {
                hasLoggedMissingContainer = true
                log.error("no app group container; skipping the CGM tick marker")
            }
            return
        }

        readStateFromDisk()

        // Monotonic. A loop that ran on a reading we have already marked has
        // nothing to add, and moving the marker back would leave an AI app
        // waiting for an update that has already happened.
        if let published = state.lastCgmTickHandledAt, cgmReadingAt.timeIntervalSince1970 <= published { return }
        state.lastCgmTickHandledAt = cgmReadingAt.timeIntervalSince1970

        // Nothing published yet means no pump metadata yet, so there is no
        // dosing object to attach the marker to. Persist it and let the first
        // export carry it — which happens on the pump sync that made this loop
        // possible in the first place.
        if let lastPublishedCurrent {
            writeCurrent(CurrentInsulinDosing(
                updatedAt: at.timeIntervalSince1970,
                bolus: lastPublishedCurrent.bolus,
                basal: lastPublishedCurrent.basal,
                lastCgmTickHandledAt: cgmReadingAt
            ), to: container)
        }

        writeStateToDisk()
    }

    // MARK: - Reset

    func resetPublishedData() async {
        guard let container else { return }
        readStateFromDisk()

        let deleted = container.deletePublishedFiles()

        // The ledger has to go with the files. Clearing the files alone would
        // leave every record marked as already exported, so the republished
        // history would come back missing them; clearing the ledger alone would
        // re-append into the existing files. They only make sense together.
        state.exportedIds = [:]
        state.exportedGlucoseIds = [:]
        state.lastRetentionDay = nil
        // `lastPumpMetadata` and `lastCgmTickHandledAt` deliberately survive: the
        // first lets the next pass republish immediately instead of waiting for a
        // pump sync, and the second is a true statement about a loop that really
        // ran, which deleting a file does not undo.
        lastExportAt = nil
        lastPublishedCurrent = nil
        writeStateToDisk()

        log.default("reset published data: removed %d file(s)", deleted)
    }

    // MARK: - The finalization state machine

    struct InsulinDosingExport: Equatable {
        let newlyFinalized: [FinalizedDoseRecord]
        let current: CurrentInsulinDosing
    }

    /// Pure, so the interesting behavior is testable without a file system.
    ///
    /// - Parameter lastCgmTickHandledAt: republished as-is. This path never
    ///   advances the marker — a pump event is not a loop — it only carries
    ///   forward what the tick path last set.
    static func buildExport(
        doses: [DoseEntry],
        scheduledBasalRateUnitsPerHour: Double,
        pump: PumpMetadata,
        alreadyExported: Set<String>,
        at: Date,
        lastCgmTickHandledAt: Date? = nil,
        log: DiagnosticLog? = nil
    ) -> InsulinDosingExport {
        let segments = InsulinTimeline.basalSegments(
            doses: doses,
            scheduledRateInUnitsPerHour: scheduledBasalRateUnitsPerHour,
            unknownInsulinType: pump.insulinType.insulinType,
            at: at
        )

        var finalized: [FinalizedDoseRecord] = []

        // MARK: basal
        //
        // The last segment always covers `at`, so it is what the pump is doing
        // right now and is never finalized. Everything before it finalizes only
        // when both bounding doses are immutable and the segment has actually
        // ended — a segment bounded on the right by a mutable temp basal can
        // still move when that temp basal's endDate settles.
        for segment in segments.dropLast() {
            guard segment.hasSettledBoundaries, segment.endDate <= at else { continue }
            finalized.append(FinalizedDoseRecord(
                id: basalId(for: segment, pump: pump),
                startTime: segment.startDate,
                endTime: segment.endDate,
                unitsDelivered: segment.unitsDelivered,
                insulinType: AiInsulinType(segment.insulinType),
                smallestDeliveryUnit: pump.smallestDeliveryUnit,
                // A suspension segment is `.basal` too, at a rate of 0.
                kind: .basal
            ))
        }

        let currentBasal = segments.last.map { segment in
            CurrentBasal(
                id: basalId(for: segment, pump: pump),
                startTime: segment.startDate,
                endTime: segment.endDate,
                rateInUnitsPerHour: segment.rateInUnitsPerHour,
                insulinType: AiInsulinType(segment.insulinType),
                smallestDeliveryUnit: pump.smallestDeliveryUnit
            )
        }

        // MARK: bolus
        //
        // A bolus is done when the pump has stopped revising it *and* it has
        // actually finished delivering.
        //
        // The second condition is nearly always implied by the first: the pump
        // reports a bolus as mutable while it runs and immutable once it
        // completes, and 128 of the 132 distinct doses in the recorded logs
        // appear in both forms. It is here for the cases where they come apart
        // — pump/phone clock skew, which LoopKit models with
        // `detectedSystemTimeOffset`, can leave a completed dose's `endDate` a
        // few seconds past our `now`; and replaying a finished log, which is
        // what the parity tests do, hands us the immutable revision of a dose
        // that was still in flight at the replayed instant.
        //
        // Both want the same answer. A record reaching into the future is not
        // a completed delivery, and a reader discretizing one drops every pulse
        // that hasn't happened yet, under-counting IoB — the direction that
        // makes an AI dose more. Held in `current` instead, the reader treats
        // it as fully delivered at `startTime`, which over-counts, and self
        // corrects the moment the real delivered amount settles.
        let boluses = doses.filter { $0.type == .bolus }.sorted { $0.startDate < $1.startDate }
        func hasSettled(_ bolus: DoseEntry) -> Bool {
            return !bolus.isMutable && bolus.endDate <= at
        }
        let unsettledBoluses = boluses.filter { !hasSettled($0) }

        for bolus in boluses where hasSettled(bolus) {
            finalized.append(bolusRecord(for: bolus, pump: pump))
        }

        // There should be at most one bolus in flight. If the pump ever gives
        // us more, the older ones are finalized at their best-known amount
        // rather than left to accumulate in a file that only holds one.
        if unsettledBoluses.count > 1 {
            log?.error("%d unsettled boluses; finalizing all but the newest", unsettledBoluses.count - 1)
            for bolus in unsettledBoluses.dropLast() {
                finalized.append(bolusRecord(for: bolus, pump: pump))
            }
        }

        let currentBolus = unsettledBoluses.last.map { bolus in
            CurrentBolus(
                id: doseId(for: bolus, pump: pump),
                startTime: bolus.startDate,
                programmedUnits: bolus.programmedUnits,
                insulinType: insulinType(of: bolus, pump: pump),
                smallestDeliveryUnit: pump.smallestDeliveryUnit
            )
        }

        return InsulinDosingExport(
            newlyFinalized: finalized.filter { !alreadyExported.contains(ledgerKey(for: $0.id)) },
            current: CurrentInsulinDosing(
                updatedAt: at.timeIntervalSince1970,
                bolus: currentBolus,
                basal: currentBasal,
                lastCgmTickHandledAt: lastCgmTickHandledAt
            )
        )
    }

    private static func bolusRecord(for bolus: DoseEntry, pump: PumpMetadata) -> FinalizedDoseRecord {
        return FinalizedDoseRecord(
            id: doseId(for: bolus, pump: pump),
            startTime: bolus.startDate,
            endTime: bolus.endDate,
            // Same fallback `insulinDeliveredForSegment` uses. A canceled bolus
            // reports what it actually delivered.
            unitsDelivered: bolus.deliveredUnits ?? bolus.programmedUnits,
            insulinType: insulinType(of: bolus, pump: pump),
            smallestDeliveryUnit: pump.smallestDeliveryUnit,
            kind: .bolus
        )
    }

    /// Falls back to the pump's last known insulin when a dose carries none.
    private static func insulinType(of dose: DoseEntry, pump: PumpMetadata) -> AiInsulinType {
        guard let insulinType = dose.insulinType else { return pump.insulinType }
        return AiInsulinType(insulinType)
    }

    // MARK: - Ids
    //
    // Ids must be deterministic: re-deriving the same timeline has to produce
    // the same id or the dedup ledger stops meaning anything, and a record that
    // moves from `current` to `finalized` has to keep its id so a reader can
    // recognize it as the same delivery. Nothing here may be random.

    /// `syncIdentifier` is assigned by the pump driver and only guaranteed
    /// unique within one pod's history, so it gets namespaced.
    private static func doseId(for dose: DoseEntry, pump: PumpMetadata) -> String {
        guard let syncIdentifier = dose.syncIdentifier else {
            return syntheticId(kind: "dose", startDate: dose.startDate)
        }
        return "\(pump.pluginIdentifier):\(syncIdentifier)"
    }

    private static func basalId(for segment: BasalSegment, pump: PumpMetadata) -> String {
        switch segment.kind {
        case .tempBasal(let syncIdentifier):
            guard let syncIdentifier else {
                return syntheticId(kind: "tempbasal", startDate: segment.startDate)
            }
            return "\(pump.pluginIdentifier):\(syncIdentifier)"
        case .suspended:
            return syntheticId(kind: "suspended", startDate: segment.startDate)
        case .scheduled:
            return syntheticId(kind: "basal", startDate: segment.startDate)
        }
    }

    /// Inferred segments have no `syncIdentifier` of their own. Anchored to the
    /// segment's start in whole milliseconds, which is stable across passes
    /// because a segment's left edge is fixed by a dose that already happened.
    private static func syntheticId(kind: String, startDate: Date) -> String {
        let milliseconds = Int64((startDate.timeIntervalSince1970 * 1000).rounded())
        return "glucos:\(kind):\(milliseconds)"
    }

    /// What the dedup ledger keys on: the published id with its namespace
    /// stripped.
    ///
    /// The namespace is the pump's plugin identifier, which is a property of
    /// whatever pump is connected right now rather than of the dose. If it ever
    /// changes — a driver swap, or metadata arriving late — keying on the whole
    /// id would make every dose in the log look new and republish it under the
    /// new namespace. The remainder identifies the dose itself and doesn't move.
    static func ledgerKey(for id: String) -> String {
        guard let separator = id.firstIndex(of: ":") else { return id }
        return String(id[id.index(after: separator)...])
    }

    // MARK: - File output

    /// The records spell their timestamps as `Date`, so this strategy is what
    /// actually puts epoch seconds on the wire — it is the format, not a
    /// formatting preference. A reader must decode with the matching
    /// `.secondsSince1970`; a default `JSONDecoder` reads the same numbers as
    /// seconds since 2001 and lands 31 years off without ever erroring.
    ///
    /// Never `.prettyPrinted`: a record has to be one line to be one jsonl row.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func appendFinalized(_ records: [FinalizedDoseRecord], to container: AiInterfaceContainer, at: Date) {
        guard !records.isEmpty else { return }

        // The day comes from when we append, not from the record's own
        // timestamps: a record that finalizes just after midnight UTC belongs
        // in the new day's file even though it started yesterday.
        let day = AiInterfaceContainer.utcDay(for: at)
        let encoder = Self.makeEncoder()

        for record in records {
            guard var line = try? encoder.encode(record) else {
                log.error("could not encode a finalized record; dropping it")
                continue
            }
            line.append(0x0A) // '\n', written with the record in a single call

            // Only mark it exported if the bytes actually landed, so a full
            // disk means we retry next pass instead of losing the record.
            if container.appendFinalized(line: line, utcDay: day) {
                state.exportedIds[Self.ledgerKey(for: record.id)] = at.timeIntervalSince1970
            }
        }
    }

    private func appendGlucose(_ records: [GlucoseRecord], to container: AiInterfaceContainer, at: Date) {
        guard !records.isEmpty else { return }

        // Append day, not measurement day, exactly as above: a reading taken at
        // 23:59 UTC and appended a minute later belongs in the new day's file.
        let day = AiInterfaceContainer.utcDay(for: at)
        let encoder = Self.makeEncoder()

        for record in records {
            guard var line = try? encoder.encode(record) else {
                log.error("could not encode a glucose record; dropping it")
                continue
            }
            line.append(0x0A)

            if container.appendGlucose(line: line, utcDay: day) {
                // Keyed on the CGM's own identifier with no namespace stripped:
                // unlike a pump's, it is the same key GlucOS's glucose store
                // treats as globally unique, so there is nothing to strip.
                state.exportedGlucoseIds[record.id] = at.timeIntervalSince1970
            }
        }
    }

    private func writeCurrent(_ current: CurrentInsulinDosing, to container: AiInterfaceContainer) {
        // `updatedAt` is the write instant, but the two writers stamp theirs at
        // different points and can arrive out of order — a loop stamps its `at`
        // before it spends seconds talking to the pump, so the export triggered
        // by the temp basal it just set carries a *later* instant than the tick
        // write that follows it. Clamping keeps the field non-decreasing, which
        // is what "when did GlucOS last write this" has to mean for a reader
        // telling idle from dead; the cost is being optimistic by the width of
        // that interleaving.
        let clamped = CurrentInsulinDosing(
            updatedAt: max(current.updatedAt, lastPublishedCurrent?.updatedAt ?? 0),
            bolus: current.bolus,
            basal: current.basal,
            lastCgmTickHandledAt: current.lastCgmTickHandledAt
        )
        guard let data = try? Self.makeEncoder().encode(clamped) else {
            log.error("could not encode current_insulin_dosing.json")
            return
        }
        // Only mirrored once the bytes have landed, so a failed write leaves the
        // mirror describing what the file actually says.
        guard container.writeCurrentInsulinDosing(data) else { return }
        lastPublishedCurrent = clamped
    }

    // MARK: - Retention

    private func runRetentionIfNeeded(container: AiInterfaceContainer, at: Date) {
        let today = AiInterfaceContainer.utcDay(for: at)
        guard state.lastRetentionDay != today else { return }
        state.lastRetentionDay = today
        // Both families, whichever export got here first today.
        container.pruneFinalizedFiles(at: at)
        container.pruneGlucoseFiles(at: at)
    }

    private func pruneLedger(at: Date) {
        let cutoff = at.timeIntervalSince1970 - AiExportState.ledgerRetention
        state.exportedIds = state.exportedIds.filter { $0.value >= cutoff }
        state.exportedGlucoseIds = state.exportedGlucoseIds.filter { $0.value >= cutoff }
    }

    // MARK: - File protection

    private func reassertFileProtectionOnce(container: AiInterfaceContainer) {
        guard !hasReassertedFileProtection else { return }
        hasReassertedFileProtection = true
        // Files written by an older build may still be protected, which would
        // fail to open on a before-first-unlock CGM wake.
        container.reassertFileProtection()
    }

    // MARK: - State

    private func readStateFromDisk() {
        guard !hasReadStateFromDisk else { return }
        hasReadStateFromDisk = true
        if let stored: AiExportState = try? stateStorage.read() {
            state = stored
        }
    }

    private func writeStateToDisk() {
        do {
            try stateStorage.write(state)
        } catch {
            // Losing the ledger means duplicate lines after a restart, not a
            // dosing problem. Log and carry on.
            log.error("could not persist the AI export ledger: %{public}@", String(describing: error))
        }
    }
}
