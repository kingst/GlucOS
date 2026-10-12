//
//  LoopRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/16/26.
//
//  The protocol seam over the store that replaced `closed_loop_results.json` and
//  `safety_states.json`. See dev/backlog/loop-record-store-grdb.md.
//
//  Same shape as `GlucoseRecordStore`, `InsulinRecordStore` and
//  `AlertRecordStore` — GRDB never crosses this boundary, the row structs are
//  private to `GRDBLoopRecordStore`, and everything here speaks domain values.
//
//  Two things make this store different from the other three:
//
//  1. **It killed the app.** On 2026-08-15 at 22:44 a background launch spent
//     its whole 30-second allowance in `JSONDecoder.decode` on the main thread
//     and was killed by the process-launch watchdog
//     (`BioKernel-2026-08-15-224405.ips`). `LoopRunner.init` read the file
//     synchronously from an `@MainActor` composition root, so *every* launch paid
//     a full decode — including the before-first-unlock Bluetooth wakes the CGM
//     generates. Nothing here is loaded at construction, which is the fix.
//
//  2. **One of its reads fails open.** The safety ledger is not diagnostic:
//     `LocalSafetyService` tallies it into `historicalMlInsulin`, which is
//     subtracted from the machine-learning deviation budget. An *empty* ledger
//     therefore reads as "no ML insulin has been delivered", which grants the
//     maximum deviation — so a read that cannot be answered must not return an
//     empty tally. `safetyStates(from:to:)` throws rather than returning `[]`
//     for every such case, including the one that is not an error at all: a
//     window reaching back further than the store has existed. See §7 and §8.
//

import Foundation

enum LoopRecordStoreError: Error {
    case couldNotOpen(String)
    case writeFailed(String)
    case readFailed(String)
    /// The safety ledger cannot account for the whole of the requested window,
    /// because part of it predates the store. Distinct from `readFailed` so the
    /// caller can log the two differently: this one is expected for the first
    /// three hours after a cutover, a reinstall, or a restore, and it stops on
    /// its own. Both land on the same conservative branch.
    case historyIncomplete(String)
}

protocol LoopRecordStore: Sendable {
    /// The whole of one loop tick, in one transaction.
    ///
    /// The pairing is the point. `safetyService.record` used to run inside
    /// `runLoop` and `storeClosedLoopResult` after it returned — two atomic file
    /// writes with no transaction between them, so a kill in the gap left the
    /// safety ledger holding a record the loop log did not, disagreeing about
    /// what the app had just done. Taking both here makes that unrepresentable
    /// rather than merely unlikely.
    ///
    /// - Parameter safetyState: nil for `.skipped` and `.pumpError` ticks, which
    ///   never got as far as programming a dose.
    /// - Parameter at: the instant retention measures back from. Injected rather
    ///   than read from the clock so the sweep is testable.
    func record(_ record: LoopRecord, safetyState: SafetyState?, at: Date) async throws

    /// The instant of the newest `.dosed` tick whose decision was a micro-bolus,
    /// or nil when there is none.
    ///
    /// Replaces a reverse scan over the whole in-memory array. Feeds
    /// `MicroBolusPolicy.pastThrottleWindow`, whose window is 252 s while loops
    /// are ~300 s apart — so the throttle only binds when two runs land closer
    /// together than 4.2 minutes, which is a pump heartbeat and a CGM reading
    /// arriving near each other. A wrong answer loosens a throttle; it does not
    /// change a dose amount.
    func lastMicroBolus() async throws -> Date?

    /// The safety ledger over `[from, to)`, in time order.
    ///
    /// Throws `historyIncomplete` when `from` reaches back before the store
    /// could possibly have recorded anything. Read the doc comment on
    /// `LoopRecordStoreError.historyIncomplete` before making this return `[]`
    /// instead: an empty ledger is a specific, wrong, unsafe answer here.
    func safetyStates(from: Date, to: Date) async throws -> [SafetyState]

    /// Loop records at or after `since`, oldest first. The chart's window.
    func records(since: Date) async throws -> [LoopRecord]

    /// The PID's filtered-glucose series at or after `since`, oldest first.
    ///
    /// Its own query rather than a projection of `records(since:)` because it is
    /// two columns of a 28-column table and it runs on every loop.
    func filteredGlucose(since: Date) async throws -> [FilteredGlucose]

    /// The newest record of any outcome, or nil on an empty store.
    ///
    /// Exists so the digestion gauge survives a relaunch: `lastClosedLoopRun` is
    /// in-memory and nil until a loop runs in *this* process, which left the
    /// gauge blank after every launch even though the data was on disk.
    func latestRecord() async throws -> LoopRecord?

    /// A consistent, shareable copy of the database, or nil when one could not
    /// be made. See `GRDBLoopRecordStore.exportSnapshotURL`.
    func exportSnapshotURL() async -> URL?
}

// MARK: - Policy constants

enum LoopRecordStorePolicy {
    /// Matches `GlucoseRecordStorePolicy.retention`, `InsulinRecordStorePolicy`
    /// and `AlertRecordStorePolicy`, so every store answers retrospective
    /// questions over the same span.
    ///
    /// No exemptions, unlike the insulin store's retained suspend/resume markers
    /// or the alert store's unretracted rows: nothing here is state that
    /// outlives its own timestamp. The ledger is only ever read over a 3-hour
    /// window and the chart over 24 hours.
    ///
    /// The 24-hour cap this replaces was never a requirement. It was the largest
    /// number that could survive being rewritten 288 times a day.
    static let retention = 90.0.daysToSeconds()

    /// How much history the diagnostic charts draw. A stated window, so that
    /// when the store holds 90 days the view asks for a day because that is what
    /// it shows — not because that is all there is. Same reasoning as
    /// `DiagnosticViewModel.pumpHistoryWindow`.
    static let chartWindow = 24.0.hoursToSeconds()

    /// The safety ledger's lookback, moved here from `LocalSafetyService`
    /// because the store's completeness check needs the same number.
    static let safetyTimeHorizon = 3.0.hoursToSeconds()
}
