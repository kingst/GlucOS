//
//  TargetGlucoseServiceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 10/20/26.
//
//  `LocalTargetGlucoseService`: the source flips to `.mealSoon` on an open row
//  and back on expiry or a manual bolus, `.exercise` raises the target for the
//  chosen duration and ignores boluses, the later of the two wins, every
//  failure lands on the settings target, and what it publishes to
//  `AppObservableState.targetOverride` matches what it returns. See
//  dev/backlog/meal-soon.md §4.3 and §10, dev/backlog/exercise.md §6.
//
//  Most of this runs against a real `GRDBLoopRecordStore` over an in-memory
//  database, so the row the service reads is the row the store writes. The
//  failure cases use `MockLoopRecordStore`, which can be made to fail on demand.
//

import Testing
import Foundation
import LoopKit
@testable import BioKernel

/// `MockInsulinStorage` reports no pump events. This one reports what a test
/// hands it, windowed the way the record store windows a dose: by overlap.
class MockInsulinStorageWithEvents: MockInsulinStorage {
    var events: [NewPumpEvent] = []

    override func pumpEvents(from: Date, to: Date) async -> [NewPumpEvent] {
        return events.filter { event in
            guard let dose = event.dose else { return event.date >= from && event.date < to }
            return dose.startDate < to && dose.endDate > from
        }
    }
}

@MainActor
struct TargetGlucoseServiceTests {

    let now = Date.f("2026-10-20 12:00:00 +0000")
    /// Target 90 by default, which the override drops to 75.
    let settings = MockSettingsStorage()

    // MARK: - Fixtures

    private func makeService(
        store: LoopRecordStore?,
        insulinStorage: InsulinStorage = MockInsulinStorage()
    ) -> (service: LocalTargetGlucoseService, state: AppObservableState) {
        let state = AppObservableState()
        let service = LocalTargetGlucoseService(recordStore: store, insulinStorage: insulinStorage, observableState: state)
        return (service, state)
    }

    /// `NewPumpEvent.init` overwrites the dose's `syncIdentifier` with the hex
    /// of `raw`, which is how every pod event gets its identifier. So the id a
    /// test should expect is `event.dose?.syncIdentifier`, not the string
    /// handed in here.
    private func bolusEvent(at: Date, automatic: Bool?, raw: String) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .bolus,
            startDate: at,
            endDate: at + 40,
            value: 2,
            unit: .units,
            insulinType: .lyumjev,
            automatic: automatic,
            isMutable: true
        )
        return NewPumpEvent(date: at, dose: dose, raw: Data(raw.utf8), title: "bolus", type: .bolus)
    }

    // MARK: - The source

    @Test func theSourceFlipsToMealSoonOnAnOpenRowAndBackOnExpiry() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
        #expect(state.targetOverride == nil)

        try await service.startMealSoon(at: now, settings: settings.snapshot())
        #expect(state.targetOverride?.startedAt == now)
        #expect(state.targetOverride?.expiresAt == now + 60.minutesToSeconds())
        #expect(state.targetOverride?.settingsTargetMgDl == 90)

        #expect(await service.targetGlucose(at: now + 59.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 75, source: .mealSoon))
        #expect(state.targetOverride?.isActive(at: now + 59.minutesToSeconds()) == true)

        // Expiry is a function of the row and the clock. Nothing had to fire.
        #expect(await service.targetGlucose(at: now + 60.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 1)
        #expect(rows[0].endedAt == now + 60.minutesToSeconds())
        #expect(rows[0].endReason == .expired)
        #expect(rows[0].endBolusSyncIdentifier == nil)
    }

    @Test func aManualBolusEndsItAtTheBolusAndRecordsTheDose() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let insulin = MockInsulinStorageWithEvents()
        let (service, state) = makeService(store: store, insulinStorage: insulin)
        try await service.startMealSoon(at: now, settings: settings.snapshot())

        let bolusAt = now + 20.minutesToSeconds()
        let bolus = bolusEvent(at: bolusAt, automatic: false, raw: "manual-bolus")
        insulin.events = [bolus]

        #expect(await service.targetGlucose(at: now + 25.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
        #expect(state.targetOverride == nil)

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.endedAt == bolusAt, "ended when the bolus started, not when the service noticed")
        #expect(row.endReason == .manualBolus)
        let expectedIdentifier = try #require(bolus.dose?.syncIdentifier)
        #expect(row.endBolusSyncIdentifier == expectedIdentifier, "the pump's identifier for the dose, as the insulin store keys it")
    }

    @Test func anAutomaticBolusDoesNotEndIt() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let insulin = MockInsulinStorageWithEvents()
        let (service, state) = makeService(store: store, insulinStorage: insulin)
        try await service.startMealSoon(at: now, settings: settings.snapshot())
        insulin.events = [bolusEvent(at: now + 20.minutesToSeconds(), automatic: true, raw: "micro-bolus")]

        #expect(await service.targetGlucose(at: now + 25.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 75, source: .mealSoon))
        #expect(state.targetOverride?.endedAt == nil)
    }

    /// `settings_target_mg_dl` is a record of what the target was when the
    /// override began, not the value in use (§4.1, decision 5).
    @Test func theOverrideTracksTheCurrentSettingsTarget() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.startMealSoon(at: now, settings: settings.snapshot())

        settings.targetGlucoseInMgDl = 120
        #expect(await service.targetGlucose(at: now + 10.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 105, source: .mealSoon))
        #expect(state.targetOverride?.settingsTargetMgDl == 90)
    }

    @Test func theTargetIsClampedAfterTheDrop() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)

        settings.targetGlucoseInMgDl = 200
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 140, source: .settings))
        try await service.startMealSoon(at: now, settings: settings.snapshot())
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 140, source: .mealSoon),
                "185 before the clamp; the clamp is the last word")

        settings.targetGlucoseInMgDl = 60
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 75, source: .mealSoon),
                "the floor is above the clamp's low end")
        await service.cancelOverride(at: now)
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 70, source: .settings))
    }

    // MARK: - Cancel

    @Test func cancelClosesTheRowAsCancelled() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        // Nothing open: a no-op that still publishes the truth.
        await service.cancelOverride(at: now)
        #expect(state.targetOverride == nil)
        #expect(try await store.targetOverrides(since: .distantPast).isEmpty)

        try await service.startMealSoon(at: now, settings: settings.snapshot())
        #expect(state.targetOverride != nil)

        let cancelledAt = now + 10.minutesToSeconds()
        await service.cancelOverride(at: cancelledAt)
        #expect(state.targetOverride == nil)
        #expect(await service.targetGlucose(at: cancelledAt, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.endedAt == cancelledAt)
        #expect(row.endReason == .cancelled)
    }

    @Test func startingAgainSupersedesTheOpenOverride() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.startMealSoon(at: now, settings: settings.snapshot())
        try await service.startMealSoon(at: now + 50.minutesToSeconds(), settings: settings.snapshot())

        #expect(state.targetOverride?.startedAt == now + 50.minutesToSeconds())
        // The fresh 60 minutes run past where the first would have expired.
        #expect(await service.targetGlucose(at: now + 100.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 75, source: .mealSoon))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 2)
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == now + 50.minutesToSeconds())
        #expect(rows[1].endedAt == nil)
    }

    // MARK: - Fail directions

    /// The end-write is log-only. If it fails the rule still evaluates to
    /// ended on the next call from `started_at` and the pump events.
    @Test func aFailingEndWriteStillReturnsTheSettingsTarget() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.startMealSoon(at: now, settings: settings.snapshot())
        await store.setFailWrites(true)

        let expired = now + 60.minutesToSeconds()
        #expect(await service.targetGlucose(at: expired, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
        #expect(state.targetOverride == nil)
        // The row is still open in the store, and the next evaluation agrees
        // anyway.
        #expect(try await store.openTargetOverride() != nil)
        #expect(await service.targetGlucose(at: expired + 1, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
    }

    @Test func aFailingReadReturnsTheSettingsTarget() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.startMealSoon(at: now, settings: settings.snapshot())
        #expect(state.targetOverride != nil)

        await store.setFailReads(true)
        #expect(await service.targetGlucose(at: now + 1, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings),
                "the settings target is the higher one")
        #expect(state.targetOverride == nil)
    }

    @Test func noStoreMeansTheSettingsTarget() async throws {
        let (service, state) = makeService(store: nil)

        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
        #expect(state.targetOverride == nil)
        #expect(await service.activeOverride(at: now) == nil)

        await #expect(throws: TargetGlucoseServiceError.self) {
            try await service.startMealSoon(at: now, settings: settings.snapshot())
        }
        await #expect(throws: TargetGlucoseServiceError.self) {
            try await service.startExercise(at: now, duration: ExercisePolicy.defaultDuration, settings: settings.snapshot())
        }
        await service.cancelOverride(at: now)
        #expect(state.targetOverride == nil)
    }

    /// `AppObservableState.targetOverride` is hydrated by the first
    /// `activeOverride` call, not at construction (§4.3): a row left open by a previous process
    /// is picked up by whoever asks first.
    @Test func activeOverrideHydratesTheObservableStateFromTheStore() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        _ = try await store.startTargetOverride(kind: .mealSoon, at: now, expiresAt: now + 60.minutesToSeconds(), settingsTargetMgDl: 90)

        let (service, state) = makeService(store: store)
        #expect(state.targetOverride == nil, "nothing is read at construction")
        let open = await service.activeOverride(at: now + 1)
        #expect(open?.startedAt == now)
        #expect(state.targetOverride == open)
    }

    // MARK: - Exercise (dev/backlog/exercise.md §6)

    @Test func exerciseRaisesTheTargetForTheChosenDuration() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.startExercise(at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .exercise)
        #expect(state.targetOverride?.startedAt == now)
        #expect(state.targetOverride?.expiresAt == now + 2.hoursToSeconds())
        #expect(state.targetOverride?.duration == 2.hoursToSeconds())

        #expect(await service.targetGlucose(at: now + 119.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 140, source: .exercise))
        #expect(await service.targetGlucose(at: now + 120.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .exercise)
        #expect(rows[0].endedAt == now + 2.hoursToSeconds())
        #expect(rows[0].endReason == .expired)
    }

    /// The clamp applies to the settings target before the raise, and the
    /// service does not clamp again afterwards (exercise, decision 1).
    @Test func exerciseIsNotCappedAtTheSettingsCeiling() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)
        try await service.startExercise(at: now, duration: 1.hoursToSeconds(), settings: settings.snapshot())

        settings.targetGlucoseInMgDl = 120
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 170, source: .exercise),
                "would be 140 if the clamp ran after the raise")
        settings.targetGlucoseInMgDl = 200
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 190, source: .exercise))
        settings.targetGlucoseInMgDl = 60
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()) == TargetGlucose(mgDl: 120, source: .exercise))
    }

    /// A snack bolus during a workout does not end exercise (exercise,
    /// decision 4), and the service does not even ask the pump.
    @Test func aManualBolusDoesNotEndExercise() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let insulin = MockInsulinStorageWithEvents()
        let (service, state) = makeService(store: store, insulinStorage: insulin)
        try await service.startExercise(at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        insulin.events = [bolusEvent(at: now + 20.minutesToSeconds(), automatic: false, raw: "snack")]

        #expect(await service.targetGlucose(at: now + 25.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 140, source: .exercise))
        #expect(state.targetOverride?.endedAt == nil)
        #expect(try await store.openTargetOverride()?.kind == .exercise)
    }

    /// Meal soon and exercise cannot both be on: the later setting wins, in
    /// both directions (exercise §3).
    @Test func theLaterOfMealSoonAndExerciseWins() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.startMealSoon(at: now, settings: settings.snapshot())
        try await service.startExercise(at: now + 10.minutesToSeconds(), duration: 2.hoursToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .exercise)
        #expect(await service.targetGlucose(at: now + 11.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 140, source: .exercise))

        try await service.startMealSoon(at: now + 20.minutesToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .mealSoon)
        #expect(await service.targetGlucose(at: now + 21.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 75, source: .mealSoon))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.kind } == [.mealSoon, .exercise, .mealSoon])
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == now + 10.minutesToSeconds())
        #expect(rows[1].endReason == .cancelled)
        #expect(rows[1].endedAt == now + 20.minutesToSeconds())
        #expect(rows[2].endedAt == nil)
        #expect(rows.filter { $0.endedAt == nil }.count == 1, "never more than one open row")
    }

    /// Changing the duration mid-run is a fresh start from now (exercise,
    /// decision 3): the old row is cancelled, the new one runs the full new
    /// duration from the change, not from the original start.
    @Test func startingExerciseAgainRestartsItFromNowWithTheNewDuration() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.startExercise(at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        try await service.startExercise(at: now + 30.minutesToSeconds(), duration: 1.hoursToSeconds(), settings: settings.snapshot())

        #expect(state.targetOverride?.startedAt == now + 30.minutesToSeconds())
        #expect(state.targetOverride?.expiresAt == now + 90.minutesToSeconds())
        #expect(state.targetOverride?.duration == 1.hoursToSeconds())
        #expect(await service.targetGlucose(at: now + 89.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 140, source: .exercise))
        #expect(await service.targetGlucose(at: now + 90.minutesToSeconds(), settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 2)
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == now + 30.minutesToSeconds())
        #expect(rows[1].endReason == .expired)
    }

    @Test func cancelClosesAnExerciseRowAsCancelled() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.startExercise(at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())

        let cancelledAt = now + 45.minutesToSeconds()
        await service.cancelOverride(at: cancelledAt)
        #expect(state.targetOverride == nil)
        #expect(await service.targetGlucose(at: cancelledAt, settings: settings.snapshot()) == TargetGlucose(mgDl: 90, source: .settings))

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.kind == .exercise)
        #expect(row.endedAt == cancelledAt)
        #expect(row.endReason == .cancelled)
    }

    @Test func exerciseRejectsANonPositiveDuration() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        await #expect(throws: TargetGlucoseServiceError.self) {
            try await service.startExercise(at: now, duration: 0, settings: settings.snapshot())
        }
        await #expect(throws: TargetGlucoseServiceError.self) {
            try await service.startExercise(at: now, duration: -1, settings: settings.snapshot())
        }
        #expect(state.targetOverride == nil)
        #expect(try await store.targetOverrides(since: .distantPast).isEmpty, "nothing was written")
    }
}
