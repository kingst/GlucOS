//
//  AlertRecordStore.swift
//  BioKernel
//
//  Created by Sam King on 8/16/26.
//
//  The protocol seam over the store of LoopKit alerts that replaced
//  `alerts.json`. See dev/backlog/migrate-json-to-grdb.md §6.
//
//  Same shape as `GlucoseRecordStore` and `InsulinRecordStore`, and the smallest
//  of the three by a wide margin — the doc comments should not pretend
//  otherwise. This store was not migrated for throughput. Alerts arrive a
//  handful of times a day and the JSON file was never large. It moved because
//  the file was a queryable table wearing an array: every accessor was a
//  `WHERE`, `retractAlert` rewrote the whole file to change one field on one
//  row, and nothing pruned it, so it grew for the life of the install.
//
//  As with the other two, GRDB never crosses this boundary: the row struct is
//  private to `GRDBAlertRecordStore` and everything here speaks LoopKit domain
//  values.
//

import Foundation
import LoopKit

enum AlertRecordStoreError: Error {
    case couldNotOpen(String)
    case writeFailed(String)
    case readFailed(String)
}

protocol AlertRecordStore: Sendable {
    /// Appends a newly issued alert, unretracted and unacknowledged.
    ///
    /// - Parameter at: the issue instant. Injected rather than read from the
    ///   clock so retention and ordering are testable.
    func issue(_ alert: Alert, at: Date) async throws

    /// Stamps `retracted_at` on every *live* row carrying this identifier, and
    /// is a no-op when there are none.
    ///
    /// Rows already retracted keep the instant they were retracted at. The JSON
    /// path re-stamped those too, which quietly exempted a repeatedly re-issued
    /// alert from retention — see `GRDBAlertRecordStore.retract`.
    func retract(identifier: Alert.Identifier, at: Date) async throws

    /// Appends an alert that already happened and is already over, with the same
    /// instant for both its issue and its retraction. Never presented to the
    /// user; it exists so the record shows the alert fired.
    func recordRetracted(_ alert: Alert, at: Date) async throws

    /// Whether any row carries this identifier, retracted or not.
    ///
    /// Retracted rows count, matching the JSON path. The question LoopKit asks
    /// through this is "have I issued this before", not "is it live now".
    func issuedAlertExists(identifier: Alert.Identifier) async throws -> Bool

    /// Unretracted alerts from one manager, in the order they were issued.
    func unretracted(managerIdentifier: String) async throws -> [PersistedAlert]

    /// The same, minus anything acknowledged.
    ///
    /// Nothing in the app writes `acknowledged_at` today — the column exists
    /// because LoopKit's `PersistedAlert` has the field and the JSON path
    /// carried it — so this currently returns what `unretracted` does. Kept
    /// separate because the distinction is LoopKit's to make, not ours.
    func unacknowledgedUnretracted(managerIdentifier: String) async throws -> [PersistedAlert]

    /// The newest live alert across all managers, or nil when there is none.
    ///
    /// "Newest" is by insertion order rather than by `issued_at`, because
    /// `recordRetracted` can append a row whose issue instant is in the past and
    /// the JSON path took the last element of the array. No priority scheme yet;
    /// this drives `observableState.activeAlert` and nothing else.
    func mostRecentActive() async throws -> Alert?
}

// MARK: - Policy constants

enum AlertRecordStorePolicy {
    /// Matches `GlucoseRecordStorePolicy.retention` and the insulin store's, so
    /// every store answers retrospective questions over the same span.
    ///
    /// Applies only to alerts that have been retracted. An unretracted alert is
    /// live state no matter how old it is — it is exactly what
    /// `unretracted(managerIdentifier:)` exists to return — so pruning one would
    /// silently drop an outstanding alert rather than an old record of one. Same
    /// exemption in spirit as the insulin store's retained suspend/resume
    /// markers.
    static let retention = 90.0.daysToSeconds()
}
