//
//  InsulinStorageTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/20/23.
//
//  `LocalInsulinStorage`'s plumbing: what reaches the pump driver, and what the
//  app does when the record store cannot answer.
//
//  The insulin arithmetic these tests used to cover moved out with the JSON log.
//  Inference, reconciliation, quantization, and the clamp are
//  `InsulinRecordTimelineTests`; ingest, retention, and the state queries are
//  `InsulinRecordStoreTests`.

import Testing
import Foundation
import LoopKit

@testable import BioKernel

struct InsulinStorageTests {
    // What the actor does when the record store is the only history there is.
    //
    // The arithmetic is `InsulinRecordTimelineTests`' and `InsulinRecordStoreTests`'
    // subject, not this file's. What is left here is the plumbing: whether a write
    // failure reaches the driver, and whether a read failure stops the loop instead
    // of quietly answering zero.

    @MainActor private func makeStorage(
        recordStore: InsulinRecordStore?
    ) -> LocalInsulinStorage {
        let settings = MockSettingsStorage()
        return LocalInsulinStorage(
            healthKitStorage: MockHealthKitStore(),
            watchComms: { MockWatchComms() },
            settingsStorage: { settings },
            recordStore: recordStore
        )
    }

    private func bolus(at: Date, units: Double) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .bolus,
            startDate: at,
            endDate: at,
            value: units,
            unit: .units,
            deliveredUnits: units,
            syncIdentifier: "bolus \(units) \(at.timeIntervalSince1970)",
            insulinType: .lyumjev,
            isMutable: false
        )
        return NewPumpEvent(date: at, dose: dose, raw: Data(UUID().uuidString.utf8), title: "bolus", type: .bolus)
    }

    /// A failed ingest has to reach `OmniPumpManager` so it re-delivers rather than
    /// clearing `state.unstoredDoses` (§8). There is no second copy of the batch.
    @Test func anIngestFailureFailsTheBatch() async throws {
        let at = Self.now
        let store = FailableInsulinRecordStore(wrapping: try GRDBInsulinRecordStore(inMemoryCreatedAt: at - 1.0.daysToSeconds()))
        let storage = await makeStorage(recordStore: store)
        store.failIngest = true

        let error = await storage.addPumpEvents(
            [bolus(at: at, units: 1.0)],
            lastReconciliation: at,
            replacePendingEvents: true,
            pump: Self.omnipodLyumjev
        )

        #expect(error != nil)
    }

    /// And a successful one does not.
    @Test func aSuccessfulIngestDoesNotFailTheBatch() async throws {
        let at = Self.now
        let store = try GRDBInsulinRecordStore(inMemoryCreatedAt: at - 1.0.daysToSeconds())
        let storage = await makeStorage(recordStore: store)

        let error = await storage.addPumpEvents(
            [bolus(at: at, units: 1.0)],
            lastReconciliation: at,
            replacePendingEvents: true,
            pump: Self.omnipodLyumjev
        )

        #expect(error == nil)
        #expect(await storage.insulinOnBoard(at: at + 5.minutesToSeconds()) > 0)
    }

    /// **The load-bearing test for the deletion of the JSON log.**
    ///
    /// With no second opinion to fall back on, a store that cannot be read makes
    /// every `-> Double` read answer zero — and zero IOB is the failure §8 warns
    /// about, because the loop reads low and doses *more*. What prevents that is
    /// `lastPumpSync` reporting nil, which trips `ClosedLoopService`'s freshness
    /// guard before any IOB number is consulted. If this ever passes while
    /// `lastPumpSync` returns a date, the loop will dose off a zero.
    @Test func aFailedStoreReadReportsNoPumpSyncSoTheLoopSkips() async throws {
        let at = Self.now
        let store = FailableInsulinRecordStore(wrapping: try GRDBInsulinRecordStore(inMemoryCreatedAt: at - 1.0.daysToSeconds()))
        let storage = await makeStorage(recordStore: store)
        _ = await storage.addPumpEvents(
            [bolus(at: at - 5.minutesToSeconds(), units: 2.0)],
            lastReconciliation: at,
            replacePendingEvents: true,
            pump: Self.omnipodLyumjev
        )
        #expect(await storage.insulinOnBoard(at: at) > 0)
        #expect(await storage.lastPumpSync() != nil)

        store.failReads = true

        #expect(await storage.lastPumpSync() == nil)
        #expect(await storage.insulinOnBoard(at: at) == 0)
    }

    /// The same, for a database that never opened at all. `AppComposition` leaves
    /// `recordStore` nil there, and it is the case a signing or migration
    /// regression actually produces.
    @Test func noRecordStoreReportsNoPumpSyncSoTheLoopSkips() async throws {
        let storage = await makeStorage(recordStore: nil)

        #expect(await storage.lastPumpSync() == nil)
        #expect(await storage.insulinOnBoard(at: Self.now) == 0)
        #expect(await storage.recentPumpEvents(since: Self.now - 1.0.daysToSeconds()).isEmpty)
    }

    /// Decision 11's other half. The JSON log was trimmed to 24 hours and so could
    /// not answer for a window older than that however it was asked; the store can,
    /// and the caller's `since` now means what it says.
    @Test func recentPumpEventsReachesPastTwentyFourHours() async throws {
        let at = Self.now
        let store = try GRDBInsulinRecordStore(inMemoryCreatedAt: at - 10.0.daysToSeconds())
        let storage = await makeStorage(recordStore: store)

        let old = at - 48.hoursToSeconds()
        _ = await storage.addPumpEvents([bolus(at: old, units: 1.0)], lastReconciliation: old, replacePendingEvents: false, pump: Self.omnipodLyumjev)
        _ = await storage.addPumpEvents([bolus(at: at, units: 2.0)], lastReconciliation: at, replacePendingEvents: false, pump: Self.omnipodLyumjev)

        let events = await storage.recentPumpEvents(since: at - 72.hoursToSeconds())
        #expect(events.contains { $0.dose?.programmedUnits == 1.0 })
        #expect(events.contains { $0.dose?.programmedUnits == 2.0 })
    }

    /// A fixed instant, because retention and the clamp are both relative to
    /// `createdAt` and a test that drifts with the wall clock is a test that
    /// fails on a slow morning.
    static let now = Date.f("2026-08-10 16:00:00 +0000")

    /// What the parallel run actually ran on, so the pulse size these tests
    /// quantize against is the one the observed results came from.
    static let omnipodLyumjev = PumpMetadata(
        pluginIdentifier: "Omni",
        smallestDeliveryUnit: 0.05,
        insulinType: .lyumjev
    )
}

/// A record store that can be told to fail, wrapping a real one so every method
/// that is not under test behaves normally.
///
/// Phase 2's two new behaviors are both "what happens when the store is
/// unavailable", and neither can be reached with a store that works.
final class FailableInsulinRecordStore: InsulinRecordStore, @unchecked Sendable {
    private let wrapped: GRDBInsulinRecordStore
    var failIngest = false
    var failReads = false

    init(wrapping wrapped: GRDBInsulinRecordStore) {
        self.wrapped = wrapped
    }

    func ingest(_ batch: PumpEventBatch) async throws -> PumpEventIngestResult {
        if failIngest { throw InsulinRecordStoreError.writeFailed("injected") }
        return try await wrapped.ingest(batch)
    }

    func timeline(windowStart: Date, at: Date, includeRevoked: Bool) async throws -> PumpDoseTimeline {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.timeline(windowStart: windowStart, at: at, includeRevoked: includeRevoked)
    }

    func enqueueScheduledBasalProgram(rateUnitsPerHour: Double, at: Date) async throws {
        try await wrapped.enqueueScheduledBasalProgram(rateUnitsPerHour: rateUnitsPerHour, at: at)
    }

    func scheduledBasalDiagnostics(at: Date) async throws -> ScheduledBasalDiagnostics {
        return try await wrapped.scheduledBasalDiagnostics(at: at)
    }

    func isSuspended(at: Date) async throws -> Bool {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.isSuspended(at: at)
    }

    func pumpAlarm(at: Date) async throws -> PumpAlarmType? {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.pumpAlarm(at: at)
    }

    func currentInsulinType(at: Date) async throws -> InsulinType? {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.currentInsulinType(at: at)
    }

    func activeBolus(at: Date) async throws -> DoseEntry? {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.activeBolus(at: at)
    }

    func lastReconciliation() async throws -> Date? {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.lastReconciliation()
    }

    func historyCompleteSince() async throws -> Date {
        return try await wrapped.historyCompleteSince()
    }

    func records(from: Date, to: Date, includeRevoked: Bool) async throws -> [PumpEventRecord] {
        if failReads { throw InsulinRecordStoreError.readFailed("injected") }
        return try await wrapped.records(from: from, to: to, includeRevoked: includeRevoked)
    }

    func staleMutableDoses(at: Date) async throws -> [StaleMutableDose] {
        return try await wrapped.staleMutableDoses(at: at)
    }

    func exportSnapshotURL() async -> URL? {
        return await wrapped.exportSnapshotURL()
    }
}
