//
//  GlucoseRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/5/26.
//
//  The protocol seam over the store of CGM-reported glucose readings that
//  replaced the 24-hour `glucose.json` log. That log's contents were imported once,
//  by hand, and no import path survives here — see `LocalGlucoseStorage`.
//
//  This is the same shape as `InsulinRecordStore`, deliberately, but it is a much
//  smaller problem and the doc comments should not pretend otherwise. Insulin
//  needed a design document because a pump event has a lifecycle: a dose is
//  mutable until the pump finalizes it, a batch can revoke doses it does not
//  assert, and a gap in the history gets *inferred* — so which rows a read
//  returns changes how much insulin the loop delivers. A CGM reading has none of
//  that. It arrives once, immutable, already carrying its own identifier, and
//  nothing is derived to fill the space between two of them. The store is
//  therefore an indexed, deduplicating, 90-day append log and nothing more.
//
//  What the extra history buys, given the loop itself never looks back further
//  than a few hours:
//
//    - the retrospective questions (time in range, overnight patterns, how a meal
//      actually played out) that a 24-hour window cannot answer at all
//    - readings survive a relaunch, so the added-glucose data frame is warm at
//      launch instead of two hours later
//
//  As with insulin, GRDB never crosses this boundary: the row struct is private
//  to `GRDBGlucoseRecordStore` and everything here speaks LoopKit domain values.
//

import Foundation
import LoopKit

/// What one ingest did.
///
/// `inserted` is the subset of the batch the store had not already seen, by
/// `syncIdentifier`. It exists because every side effect around this store is
/// keyed to *new* readings rather than to reported ones: a CGM backfill
/// re-reports the last several hours on every connection, and firing a low alert
/// or a HealthKit write per re-report would be wrong.
struct GlucoseIngestResult {
    let inserted: [NewGlucoseSample]
    /// Rows retention hard-deleted on this call. Logged, not acted on.
    let prunedByRetention: Int
}

enum GlucoseRecordStoreError: Error {
    case couldNotOpen(String)
    case writeFailed(String)
    case readFailed(String)
}

protocol GlucoseRecordStore: Sendable {
    /// One transaction per batch, `INSERT OR IGNORE` per reading.
    ///
    /// Ignoring rather than upserting is the whole dedup policy, and it differs
    /// from the insulin store's for a reason: a pump revises a dose it has
    /// already reported, so there the later report has to win. A CGM does not
    /// revise a reading — a corrected value arrives as a new sample with a new
    /// identifier — so the first version of a `syncIdentifier` we saw is the one
    /// the CGM stands behind, and a re-report is a backfill duplicate.
    ///
    /// - Parameter at: the ingest instant. Becomes each row's `recorded_at` and
    ///   anchors the retention cutoff, injected rather than read from the clock
    ///   so retention is testable.
    func ingest(_ samples: [NewGlucoseSample], at: Date) async throws -> GlucoseIngestResult

    /// The newest reading the store holds, or nil when it holds none.
    ///
    /// nil is load-bearing rather than merely empty: `LoopRunner` refuses to dose
    /// without a reading fresher than its staleness threshold, so no glucose
    /// means no dosing, which is the safe direction.
    func lastReading() async throws -> NewGlucoseSample?

    /// Readings in `[startDate, endDate]`, oldest first.
    ///
    /// Both ends inclusive, matching the JSON path this replaces. Callers depend
    /// on the right edge being closed: `AddedGlucoseDataFrame.createDataFrame`
    /// passes `at` and then checks that the newest reading it got back is within
    /// one time step of it.
    func readingsBetween(startDate: Date, endDate: Date) async throws -> [NewGlucoseSample]

}

// MARK: - Policy constants

enum GlucoseRecordStorePolicy {
    /// Matches `InsulinRecordStorePolicy.retention`, so the two stores answer
    /// retrospective questions over the same span. Nothing in the loop reads
    /// anywhere near this far back.
    static let retention = 90.0.daysToSeconds()

    /// How much history the glucose chart draws. `GlucoseChartView` fixes its
    /// x-axis to `[now - 24h, now]`, so points older than this would be laid out
    /// off the left edge of every scroll position — and at 5-minute samples over
    /// 90 days there would be ~26,000 of them.
    static let chartWindow = 24.0.hoursToSeconds()
}
