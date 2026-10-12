//
//  AlertRecordStoreTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/16/26.
//
//  `GRDBAlertRecordStore`: schema, the lifecycle queries, retention, and the
//  blob round-trip.
//
//  The original `LocalAlertStorage` shipped with "I haven't figured out how to
//  test this well yet, so who knows if it's correct" at the top of the file.
//  Most of what made it hard to test was that it owned a file; a store with an
//  in-memory `DatabaseQueue` and an injected `at` has neither problem, so these
//  are the tests that note was asking for.
//
//  One of them pins behavior that is arguably wrong but is what the JSON path
//  did: `issuedAlertExists` counts retracted rows. It is here so that changing
//  it is a deliberate act with a failing test attached, rather than something
//  that drifts.
//
//  The JSON path's other oddity — `retract` re-stamping rows it had already
//  retracted, which exempted a repeatedly re-issued alert from retention — was
//  fixed rather than preserved, and is pinned from the other direction.
//

import Testing
import Foundation
import GRDB
import LoopKit
@testable import BioKernel

// MARK: - Fixtures

enum AlertFixtures {
    static func identifier(manager: String = "pump", alert: String) -> Alert.Identifier {
        return Alert.Identifier(managerIdentifier: manager, alertIdentifier: alert)
    }

    /// Exercises the parts of `Alert` that are not plain strings, because the
    /// blob round-trip is the one thing a column-per-field schema would have
    /// given us for free and this one has to earn.
    static func alert(
        manager: String = "pump",
        alert: String,
        trigger: Alert.Trigger = .immediate,
        sound: Alert.Sound? = .vibrate,
        interruptionLevel: Alert.InterruptionLevel = .timeSensitive,
        metadata: Alert.Metadata? = nil
    ) -> Alert {
        return Alert(
            identifier: identifier(manager: manager, alert: alert),
            foregroundContent: Alert.Content(
                title: "Foreground \(alert)",
                body: "body",
                acknowledgeActionButtonLabel: "OK"
            ),
            backgroundContent: Alert.Content(
                title: "Background \(alert)",
                body: "body",
                acknowledgeActionButtonLabel: "OK"
            ),
            trigger: trigger,
            interruptionLevel: interruptionLevel,
            sound: sound,
            metadata: metadata
        )
    }
}

// MARK: - Tests

struct AlertRecordStoreTests {
    /// A fixed instant, because `Date()` in a test that asserts about time is a
    /// test that fails on a slow machine.
    static let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeStore() throws -> GRDBAlertRecordStore {
        return try GRDBAlertRecordStore(inMemory: ())
    }

    // MARK: - Schema

    @Test func aNewStoreIsEmpty() async throws {
        let store = try makeStore()
        #expect(try await store.mostRecentActive() == nil)
        #expect(try await store.unretracted(managerIdentifier: "pump").isEmpty)
        #expect(try await store.unacknowledgedUnretracted(managerIdentifier: "pump").isEmpty)
        #expect(try await store.issuedAlertExists(identifier: AlertFixtures.identifier(alert: "nope")) == false)
    }

    @Test func anUnopenableDatabaseIsLoud() async throws {
        // Same rule as the other two stores: a store that cannot open must say
        // so, not present as an empty history. `AppComposition` is what decides
        // how the app degrades, and it cannot decide anything about a silent
        // success.
        let url = URL(fileURLWithPath: "/dev/null/not-a-directory/alerts.sqlite")
        #expect(throws: AlertRecordStoreError.self) {
            _ = try GRDBAlertRecordStore(url: url)
        }
    }

    @Test func alertsSurviveReopening() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("alerts.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try GRDBAlertRecordStore(url: url)
        try await first.issue(AlertFixtures.alert(alert: "podExpiring"), at: Self.now)

        let second = try GRDBAlertRecordStore(url: url)
        let restored = try await second.unretracted(managerIdentifier: "pump")
        #expect(restored.count == 1)
        #expect(restored.first?.alert.identifier.alertIdentifier == "podExpiring")
    }

    // MARK: - The blob round-trip

    @Test func anAlertRoundTripsThroughTheBlob() async throws {
        // `Trigger` and `Sound` are enums with associated values and hand-written
        // Codable conformances, and `Metadata` is open-ended. If any of that were
        // going to be lossy, it would be lossy here.
        let original = AlertFixtures.alert(
            alert: "lowReservoir",
            trigger: .repeating(repeatInterval: 15.minutesToSeconds()),
            sound: .sound(name: "alarm.caf"),
            interruptionLevel: .critical,
            metadata: Alert.Metadata(dict: ["unitsRemaining": 8.5])
        )

        let store = try makeStore()
        try await store.issue(original, at: Self.now)

        let restored = try #require(try await store.unretracted(managerIdentifier: "pump").first)
        #expect(restored.alert == original)
        #expect(restored.issuedDate == Self.now)
        #expect(restored.retractedDate == nil)
        #expect(restored.acknowledgedDate == nil)
    }

    // MARK: - Issue and retract

    @Test func retractingRemovesAnAlertFromTheLiveQueries() async throws {
        let store = try makeStore()
        let alert = AlertFixtures.alert(alert: "podExpiring")
        try await store.issue(alert, at: Self.now)

        #expect(try await store.mostRecentActive() == alert)
        #expect(try await store.unretracted(managerIdentifier: "pump").count == 1)

        try await store.retract(identifier: alert.identifier, at: Self.now + 60)

        #expect(try await store.mostRecentActive() == nil)
        #expect(try await store.unretracted(managerIdentifier: "pump").isEmpty)
        #expect(try await store.unacknowledgedUnretracted(managerIdentifier: "pump").isEmpty)
    }

    @Test func retractingOnlyTouchesTheMatchingIdentifier() async throws {
        let store = try makeStore()
        let expiring = AlertFixtures.alert(alert: "podExpiring")
        let reservoir = AlertFixtures.alert(alert: "lowReservoir")
        try await store.issue(expiring, at: Self.now)
        try await store.issue(reservoir, at: Self.now + 1)

        try await store.retract(identifier: expiring.identifier, at: Self.now + 60)

        let live = try await store.unretracted(managerIdentifier: "pump")
        #expect(live.map { $0.alert.identifier.alertIdentifier } == ["lowReservoir"])
    }

    @Test func lookupsAreScopedToOneManager() async throws {
        let store = try makeStore()
        try await store.issue(AlertFixtures.alert(manager: "pump", alert: "podExpiring"), at: Self.now)
        try await store.issue(AlertFixtures.alert(manager: "cgm", alert: "sensorExpiring"), at: Self.now + 1)

        #expect(try await store.unretracted(managerIdentifier: "pump").count == 1)
        #expect(try await store.unretracted(managerIdentifier: "cgm").count == 1)
        #expect(try await store.unretracted(managerIdentifier: "watch").isEmpty)
    }

    @Test func lookupsComeBackInIssueOrder() async throws {
        let store = try makeStore()
        for (index, name) in ["first", "second", "third"].enumerated() {
            try await store.issue(
                AlertFixtures.alert(alert: name),
                at: Self.now + Double(index)
            )
        }

        let live = try await store.unretracted(managerIdentifier: "pump")
        #expect(live.map { $0.alert.identifier.alertIdentifier } == ["first", "second", "third"])
    }

    @Test func theActiveAlertIsTheNewestLiveOne() async throws {
        let store = try makeStore()
        let older = AlertFixtures.alert(alert: "older")
        let newer = AlertFixtures.alert(alert: "newer")
        try await store.issue(older, at: Self.now)
        try await store.issue(newer, at: Self.now + 60)

        #expect(try await store.mostRecentActive() == newer)

        // Retracting the newest falls back to the one still standing, rather
        // than to nothing.
        try await store.retract(identifier: newer.identifier, at: Self.now + 120)
        #expect(try await store.mostRecentActive() == older)
    }

    // MARK: - Already-retracted alerts

    @Test func anAlreadyRetractedAlertIsNeverLive() async throws {
        let store = try makeStore()
        let alert = AlertFixtures.alert(alert: "deliverySuspended")
        try await store.recordRetracted(alert, at: Self.now)

        #expect(try await store.mostRecentActive() == nil)
        #expect(try await store.unretracted(managerIdentifier: "pump").isEmpty)
        // But it is on the record, which is the entire point of the call.
        #expect(try await store.issuedAlertExists(identifier: alert.identifier) == true)
    }

    // MARK: - Preserved JSON-path semantics

    @Test func issuedAlertExistsCountsRetractedAlerts() async throws {
        // Pins the JSON path's behavior: the question is "have I issued this
        // before", not "is it live now". Tightening this is a behavior change,
        // and this test is what makes it a deliberate one.
        let store = try makeStore()
        let alert = AlertFixtures.alert(alert: "podExpiring")
        try await store.issue(alert, at: Self.now)
        try await store.retract(identifier: alert.identifier, at: Self.now + 60)

        #expect(try await store.issuedAlertExists(identifier: alert.identifier) == true)
        #expect(try await store.unretracted(managerIdentifier: "pump").isEmpty)
    }

    @Test func retractingAnAlreadyRetractedAlertLeavesItsRetractionInstantAlone() async throws {
        // The JSON path re-stamped every row carrying the identifier, so a
        // second retraction pushed the first row's retention cutoff forward and
        // an alert that fired repeatedly never aged out. `retract` now touches
        // only live rows, which makes a retraction with nothing live a complete
        // no-op — and that is what this checks.
        //
        // Retention is the only place `retracted_at`'s value is observable at
        // all: both lookups filter to rows where it is NULL, so no read can
        // return it.
        let store = try makeStore()
        let alert = AlertFixtures.alert(alert: "podExpiring")

        try await store.issue(alert, at: Self.now)
        try await store.retract(identifier: alert.identifier, at: Self.now + 60)

        // A redundant second retraction, long after the fact. LoopKit does this
        // — a driver reconnecting retracts what it believes is outstanding
        // whether or not we still hold it as live.
        try await store.retract(identifier: alert.identifier, at: Self.now + AlertRecordStorePolicy.retention)

        // Sweep with a cutoff just past the *first* retraction. The row is
        // pruned because that is still the instant it carries; under the JSON
        // path's behavior the second retraction would have moved it out of
        // reach and it would survive here.
        try await store.issue(
            AlertFixtures.alert(alert: "unrelated"),
            at: Self.now + 61 + AlertRecordStorePolicy.retention
        )

        #expect(try await store.issuedAlertExists(identifier: alert.identifier) == false)
    }

    @Test func retractingTwiceStillClearsTheAlert() async throws {
        // The other half of the same change: skipping already-retracted rows
        // must not make a repeated retraction fail to retract the live one.
        let store = try makeStore()
        let alert = AlertFixtures.alert(alert: "podExpiring")

        try await store.issue(alert, at: Self.now)
        try await store.retract(identifier: alert.identifier, at: Self.now + 60)
        // Fires again, and is retracted again.
        try await store.issue(alert, at: Self.now + 120)
        #expect(try await store.mostRecentActive() == alert)

        try await store.retract(identifier: alert.identifier, at: Self.now + 180)
        #expect(try await store.mostRecentActive() == nil)
        #expect(try await store.unretracted(managerIdentifier: "pump").isEmpty)
    }

    // MARK: - Retention

    @Test func retentionPrunesOldRetractedAlerts() async throws {
        let store = try makeStore()
        let old = AlertFixtures.alert(alert: "ancient")
        try await store.issue(old, at: Self.now)
        try await store.retract(identifier: old.identifier, at: Self.now)

        // Retention runs on the write paths that add rows, so this issue is what
        // triggers the sweep.
        let cutoffCrossed = Self.now + AlertRecordStorePolicy.retention + 1
        try await store.issue(AlertFixtures.alert(alert: "current"), at: cutoffCrossed)

        #expect(try await store.issuedAlertExists(identifier: old.identifier) == false)
        #expect(try await store.unretracted(managerIdentifier: "pump").count == 1)
    }

    @Test func retentionKeepsAnUnretractedAlertHoweverOld() async throws {
        // The exemption that makes retention safe. An unretracted alert is
        // outstanding state, so its age says nothing about whether it can go —
        // pruning it would silently drop the alert `lookupAllUnretracted` exists
        // to return.
        let store = try makeStore()
        let stillOutstanding = AlertFixtures.alert(alert: "outstanding")
        try await store.issue(stillOutstanding, at: Self.now)

        try await store.issue(
            AlertFixtures.alert(alert: "current"),
            at: Self.now + AlertRecordStorePolicy.retention * 10
        )

        let live = try await store.unretracted(managerIdentifier: "pump")
        #expect(live.map { $0.alert.identifier.alertIdentifier } == ["outstanding", "current"])
    }

    @Test func retentionKeepsRecentlyRetractedAlerts() async throws {
        let store = try makeStore()
        let recent = AlertFixtures.alert(alert: "recent")
        try await store.issue(recent, at: Self.now)
        try await store.retract(identifier: recent.identifier, at: Self.now)

        // One second inside the horizon.
        try await store.issue(
            AlertFixtures.alert(alert: "current"),
            at: Self.now + AlertRecordStorePolicy.retention - 1
        )

        #expect(try await store.issuedAlertExists(identifier: recent.identifier) == true)
    }
}
