//
//  TargetGlucoseServiceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 10/20/26.
//
//  `LocalTargetGlucoseService`, the override manager: an open row moves the
//  target or scales dosing and the clock ends it, `start` refuses what is
//  outside the guardrails and writes nothing, a row that did not come through
//  `start` is clamped on every tick, a policy identifier nobody knows doses
//  like any other, the later start wins, every failure lands on the settings
//  target with no dosing override, and what it publishes to
//  `AppObservableState.targetOverride` matches what the store holds. See
//  dev/backlog/override-mechanism.md, dev/backlog/meal-soon.md §4.3 and §10,
//  dev/backlog/exercise.md §6 and dev/backlog/more-settings-automation.md.
//
//  Most of this runs against a real `GRDBLoopRecordStore` over an in-memory
//  database, so the row the service reads is the row the store writes. The
//  failure cases and the re-entrancy cases use `MockLoopRecordStore`, which
//  can be made to fail on demand and to hold a read open.
//
//  The service takes no `InsulinStorage`, so there is no dose it could end an
//  override on. Meal soon used to end on a manual bolus, and the tests for
//  that are gone with the rule.
//

import Testing
import Foundation
@testable import BioKernel

@MainActor
struct TargetGlucoseServiceTests {

    let now = Date.f("2026-10-20 12:00:00 +0000")
    /// Target 90 by default, which meal soon drops to 75.
    let settings = MockSettingsStorage()

    // MARK: - Fixtures

    private func makeService(store: LoopRecordStore?) -> (service: LocalTargetGlucoseService, state: AppObservableState) {
        let state = AppObservableState()
        let service = LocalTargetGlucoseService(recordStore: store, observableState: state)
        return (service, state)
    }

    /// What each kind reports with a settings target of 90: the target it
    /// doses toward, the settings target beside it, and its dosing
    /// multiplier. Written out here, not read back from the kind, so a wrong
    /// number in the table is a failure and not a tautology.
    private func expectedAnswer(for kind: TargetOverrideKind) -> TargetGlucoseFields {
        switch kind {
        case .mealSoon:
            return .target("mealSoon", mgDl: 75, settingsMgDl: 90)
        case .digestion:
            return .dosingOnly("digestion", settingsMgDl: 90, dosingMultiplier: 1.3)
        case .exerciseSoon:
            return .target("exerciseSoon", mgDl: 140, settingsMgDl: 90)
        case .exercise:
            return .target("exercise", mgDl: 140, settingsMgDl: 90, dosingMultiplier: 0.6)
        case .postExercise:
            return .dosingOnly("postExercise", settingsMgDl: 90, dosingMultiplier: 0.8)
        }
    }

    // MARK: - An open row and the clock

    @Test func mealSoonLowersTheTargetOnAnOpenRowAndTheClockEndsIt() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        #expect(state.targetOverride?.policyIdentifier == "mealSoon")
        #expect(state.targetOverride?.effect == OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil))
        #expect(state.targetOverride?.startedAt == now)
        #expect(state.targetOverride?.expiresAt == now + 60.minutesToSeconds())
        #expect(state.targetOverride?.settingsTargetMgDl == 90)

        #expect(await service.targetGlucose(at: now + 59.minutesToSeconds(), settings: settings.snapshot()).fields == .target("mealSoon", mgDl: 75, settingsMgDl: 90))
        #expect(state.targetOverride?.isActive(at: now + 59.minutesToSeconds()) == true)

        // Expiry is a function of the row and the clock. Nothing had to fire.
        #expect(await service.targetGlucose(at: now + 60.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 1)
        #expect(rows[0].endedAt == now + 60.minutesToSeconds())
        #expect(rows[0].endReason == .expired)
    }

    /// The offset is added to the *current* settings target on every tick.
    /// `settings_target_mg_dl` is a record of what the target was when the
    /// override began, not the value in use (meal-soon §4.1, decision 5).
    @Test func theOverrideFollowsTheCurrentSettingsTarget() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())

        settings.targetGlucoseInMgDl = 120
        #expect(await service.targetGlucose(at: now + 10.minutesToSeconds(), settings: settings.snapshot()).fields == .target("mealSoon", mgDl: 105, settingsMgDl: 120))
        #expect(state.targetOverride?.settingsTargetMgDl == 90)
    }

    /// The settings target is clamped to [70, 140] before the offset is
    /// added, on every tick. Meal soon's offset is worked out once, at the
    /// settings target it started with: at 200 both the settings target and
    /// the lowered target clamp to 140, so the offset is zero, and it stays
    /// zero when the settings target changes.
    @Test func theSettingsTargetIsClampedBeforeTheOffset() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)

        settings.targetGlucoseInMgDl = 200
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .settings(140))
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("mealSoon", mgDl: 140, settingsMgDl: 140))

        settings.targetGlucoseInMgDl = 60
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("mealSoon", mgDl: 70, settingsMgDl: 70),
                "the offset carries over, and the floor is not worked out again")
        try await service.cancelOverride(at: now)
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .settings(70))
    }

    /// A tick whose time is before the row's `startedAt` gets the settings
    /// target, and nothing is written or published for it. That is a loop
    /// that began before the tap, and it is a clock that was set back, which
    /// used to keep the override on for as long as the clock was moved.
    @Test func aTickFromBeforeTheStartGetsTheSettingsTargetAndChangesNothing() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.start(.exercise, at: now, duration: 1.hoursToSeconds(), settings: settings.snapshot())
        let published = try #require(state.targetOverride)

        for before in [now - 1, now - 5.minutesToSeconds(), now - 3.hoursToSeconds()] {
            #expect(await service.targetGlucose(at: before, settings: settings.snapshot()).fields == .settings(90))
            #expect(await service.activeOverride(at: before) == nil)
            #expect(state.targetOverride == published, "still published: it has not ended")
            #expect(try await store.openTargetOverride() == published, "and still open")
        }

        // Once the clock is back inside the window it is in effect again,
        // and it still ends when it was going to.
        #expect(await service.targetGlucose(at: now + 30.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .exercise))
        #expect(await service.targetGlucose(at: now + 1.hoursToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(try await store.targetOverrides(since: .distantPast).map { $0.endedAt } == [now + 1.hoursToSeconds()])
    }

    // MARK: - Cancel

    @Test func cancelClosesTheRowAsCancelled() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        // Nothing open: a no-op that still publishes the truth.
        try await service.cancelOverride(at: now)
        #expect(state.targetOverride == nil)
        #expect(try await store.targetOverrides(since: .distantPast).isEmpty)

        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        #expect(state.targetOverride != nil)

        let cancelledAt = now + 10.minutesToSeconds()
        try await service.cancelOverride(at: cancelledAt)
        #expect(state.targetOverride == nil)
        #expect(await service.targetGlucose(at: cancelledAt, settings: settings.snapshot()).fields == .settings(90))

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.endedAt == cancelledAt)
        #expect(row.endReason == .cancelled)
    }

    /// A cancel the store could not do is an error the screen can show, the
    /// same as a failed start. What the store says is still what is
    /// published, so the override shows as on and the loop keeps dosing with
    /// it.
    @Test func aFailedCancelThrowsAndTheOverrideStaysPublished() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.start(.digestion, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        let published = try #require(state.targetOverride)

        await store.setFailWrites(true)
        await #expect(throws: LoopRecordStoreError.self) {
            try await service.cancelOverride(at: now + 10.minutesToSeconds())
        }
        #expect(state.targetOverride == published)
        #expect(await service.targetGlucose(at: now + 11.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .digestion))

        // A read that fails is a failed cancel too, and with the store
        // unreadable nothing is published as on.
        await store.setFailWrites(false)
        await store.setFailReads(true)
        await #expect(throws: LoopRecordStoreError.self) {
            try await service.cancelOverride(at: now + 12.minutesToSeconds())
        }
        #expect(state.targetOverride == nil)

        await store.setFailReads(false)
        try await service.cancelOverride(at: now + 13.minutesToSeconds())
        #expect(state.targetOverride == nil)
        #expect(try await store.openTargetOverride() == nil)
    }

    @Test func startingAgainSupersedesTheOpenOverride() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        try await service.start(.mealSoon, at: now + 50.minutesToSeconds(), duration: MealSoonPolicy.duration, settings: settings.snapshot())

        #expect(state.targetOverride?.startedAt == now + 50.minutesToSeconds())
        // The fresh 60 minutes run past where the first would have expired.
        #expect(await service.targetGlucose(at: now + 100.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .mealSoon))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 2)
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == now + 50.minutesToSeconds())
        #expect(rows[1].endedAt == nil)
    }

    // MARK: - Guardrails at start (dev/backlog/override-mechanism.md)

    /// `start` refuses an override outside the guardrails and writes nothing,
    /// so a policy with a wrong number finds out at once.
    @Test func startRefusesEachKindOfOutOfRangeValueAndWritesNothing() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        let hour = 1.hoursToSeconds()

        let refused: [(effect: OverrideEffect, duration: TimeInterval, violation: OverrideGuardrailViolation)] = [
            (OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: nil), hour, .noEffect),
            (OverrideEffect(targetOffsetMgDl: .nan, dosingMultiplier: nil), hour, .notFinite),
            (OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: .infinity), hour, .notFinite),
            (OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil), .infinity, .notFinite),
            (OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil), 0, .durationOutOfRange),
            (OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil), -1, .durationOutOfRange),
            (OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil), 4 * hour + 1, .durationOutOfRange),
            (OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 1.6), hour, .dosingMultiplierOutOfRange),
            (OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 0.4), hour, .dosingMultiplierOutOfRange),
            (OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 0), hour, .dosingMultiplierOutOfRange),
            (OverrideEffect(targetOffsetMgDl: 111, dosingMultiplier: nil), hour, .targetOutOfRange),
            (OverrideEffect(targetOffsetMgDl: -21, dosingMultiplier: nil), hour, .targetOutOfRange),
            // One good side does not excuse the other.
            (OverrideEffect(targetOffsetMgDl: 50, dosingMultiplier: 2), hour, .dosingMultiplierOutOfRange),
            (OverrideEffect(targetOffsetMgDl: 500, dosingMultiplier: 0.6), hour, .targetOutOfRange)
        ]
        for (effect, duration, violation) in refused {
            await #expect(throws: violation, "\(effect) for \(duration) seconds") {
                try await service.start(policyIdentifier: "test-policy", effect: effect, at: now, duration: duration, settings: settings.snapshot())
            }
        }
        #expect(state.targetOverride == nil)
        #expect(try await store.targetOverrides(since: .distantPast).isEmpty, "nothing was written")
    }

    /// A refused start leaves whatever was running alone.
    @Test func aRefusedStartDoesNotSupersedeTheOpenOverride() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.start(.digestion, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        let published = try #require(state.targetOverride)

        await #expect(throws: OverrideGuardrailViolation.dosingMultiplierOutOfRange) {
            try await service.start(policyIdentifier: "test-policy", effect: OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 5), at: now + 60, duration: 600, settings: settings.snapshot())
        }
        #expect(state.targetOverride == published)
        #expect(try await store.openTargetOverride() == published)
    }

    /// The target is checked at the settings target of the moment the
    /// override starts: the same offset is accepted at one and refused at
    /// another.
    @Test func theTargetIsCheckedAtTheSettingsTargetOfTheMoment() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)
        let raise = OverrideEffect(targetOffsetMgDl: 100, dosingMultiplier: nil)

        settings.targetGlucoseInMgDl = 120
        await #expect(throws: OverrideGuardrailViolation.targetOutOfRange) {
            try await service.start(policyIdentifier: "test-policy", effect: raise, at: now, duration: 600, settings: settings.snapshot())
        }
        settings.targetGlucoseInMgDl = 100
        try await service.start(policyIdentifier: "test-policy", effect: raise, at: now, duration: 600, settings: settings.snapshot())
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("test-policy", mgDl: 200, settingsMgDl: 100))

        // Accepted at 100, and the per-tick clamp is what holds it at the
        // top of the range when the settings target then goes up.
        settings.targetGlucoseInMgDl = 140
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("test-policy", mgDl: 200, settingsMgDl: 140))
    }

    /// The duration choices belong to the screen. `start` checks the
    /// guardrail maximum and nothing else, so a duration no picker offers
    /// starts.
    @Test func aDurationThatNoPickerOffersStarts() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        let started: [(kind: TargetOverrideKind, duration: TimeInterval)] = [
            (.mealSoon, 45.minutesToSeconds()),
            (.mealSoon, 3.hoursToSeconds()),
            (.postExercise, 4.hoursToSeconds()),
            (.digestion, 7.minutesToSeconds())
        ]
        for (kind, duration) in started {
            #expect(!kind.durations.contains(duration))
            try await service.start(kind, at: now, duration: duration, settings: settings.snapshot())
            #expect(state.targetOverride?.kind == kind)
            #expect(state.targetOverride?.duration == duration)
        }
    }

    // MARK: - Guardrails on every tick

    /// A row that did not come through `start`, here written straight to the
    /// store with numbers `start` would refuse. The tick clamps the target
    /// and the multiplier into their ranges, and the row ends at the maximum
    /// duration whatever its `expiresAt` says.
    @Test func aRowThatDidNotComeThroughStartIsClampedOnEveryTick() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        _ = try await store.startTargetOverride(
            policyIdentifier: "another-build",
            effect: OverrideEffect(targetOffsetMgDl: 500, dosingMultiplier: 3),
            at: now,
            expiresAt: now + 10.hoursToSeconds(),
            settingsTargetMgDl: 90
        )
        let (service, state) = makeService(store: store)
        let clamped = TargetGlucoseFields.target("another-build", mgDl: 200, settingsMgDl: 90, dosingMultiplier: 1.5)

        #expect(await service.targetGlucose(at: now + 1.minutesToSeconds(), settings: settings.snapshot()).fields == clamped)
        #expect(await service.targetGlucose(at: now + 4.hoursToSeconds() - 1, settings: settings.snapshot()).fields == clamped)
        #expect(state.targetOverride?.policyIdentifier == "another-build")

        #expect(await service.targetGlucose(at: now + 4.hoursToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)
        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.endedAt == now + 4.hoursToSeconds(), "at the maximum, not at its own expiry")
        #expect(row.endReason == .expired)
    }

    /// The other direction, and a multiplier that cannot be divided by.
    @Test func aRowWithNumbersBelowTheRangeIsClampedUp() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)

        _ = try await store.startTargetOverride(policyIdentifier: "another-build", effect: OverrideEffect(targetOffsetMgDl: -80, dosingMultiplier: 0.1), at: now, expiresAt: now + 1.hoursToSeconds(), settingsTargetMgDl: 90)
        #expect(await service.targetGlucose(at: now + 1, settings: settings.snapshot()).fields == .target("another-build", mgDl: 70, settingsMgDl: 90, dosingMultiplier: 0.5))

        _ = try await store.startTargetOverride(policyIdentifier: "another-build", effect: OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 0), at: now + 60, expiresAt: now + 1.hoursToSeconds(), settingsTargetMgDl: 90)
        #expect(await service.targetGlucose(at: now + 61, settings: settings.snapshot()).fields == .dosingOnly("another-build", settingsMgDl: 90, dosingMultiplier: nil),
                "a multiplier of zero is no dosing override at all")
    }

    /// A row at the maximum duration is inside it and runs its whole length.
    @Test func aRowAtTheMaximumDurationRunsItsWholeLength() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)
        try await service.start(.exercise, at: now, duration: 4.hoursToSeconds(), settings: settings.snapshot())

        #expect(await service.targetGlucose(at: now + 3.5.hoursToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .exercise))
        #expect(await service.targetGlucose(at: now + 4.hoursToSeconds() - 1, settings: settings.snapshot()).fields == expectedAnswer(for: .exercise))
        #expect(await service.targetGlucose(at: now + 4.hoursToSeconds(), settings: settings.snapshot()).fields == .settings(90))
    }

    // MARK: - A policy the mechanism has never heard of

    /// The policy identifier is a label. A source that is not one of the five
    /// settings starts, doses and expires like any of them, under its own
    /// identifier, with nothing changed in the service or the store.
    @Test func anUnknownPolicyIdentifierStartsDosesAndExpires() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        let effect = OverrideEffect(targetOffsetMgDl: 20, dosingMultiplier: 0.9)

        try await service.start(policyIdentifier: "ai.picked-target", effect: effect, at: now, duration: 45.minutesToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.policyIdentifier == "ai.picked-target")
        #expect(state.targetOverride?.kind == nil, "not one of the five")
        #expect(state.targetOverride?.effect == effect)
        #expect(state.targetOverride?.isActive(at: now + 1) == true)

        let answer = TargetGlucoseFields.target("ai.picked-target", mgDl: 110, settingsMgDl: 90, dosingMultiplier: 0.9)
        #expect(await service.targetGlucose(at: now + 44.minutesToSeconds(), settings: settings.snapshot()).fields == answer)

        // Another process picks the same open row up from the store.
        let (secondService, secondState) = makeService(store: store)
        #expect(await secondService.activeOverride(at: now + 44.minutesToSeconds()) == state.targetOverride)
        #expect(secondState.targetOverride == state.targetOverride)

        #expect(await service.targetGlucose(at: now + 45.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.policyIdentifier == "ai.picked-target")
        #expect(row.effect == effect)
        #expect(row.endedAt == now + 45.minutesToSeconds())
        #expect(row.endReason == .expired)
    }

    /// And it is superseded by, and supersedes, one of the five.
    @Test func anUnknownPolicyAndASettingSupersedeEachOther() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.start(policyIdentifier: "ai.picked-target", effect: OverrideEffect(targetOffsetMgDl: 20, dosingMultiplier: nil), at: now, duration: 600, settings: settings.snapshot())
        try await service.start(.digestion, at: now + 60, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .digestion)
        try await service.start(policyIdentifier: "ai.picked-target", effect: OverrideEffect(targetOffsetMgDl: 20, dosingMultiplier: nil), at: now + 120, duration: 600, settings: settings.snapshot())
        #expect(await service.targetGlucose(at: now + 121, settings: settings.snapshot()).fields == .target("ai.picked-target", mgDl: 110, settingsMgDl: 90))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.policyIdentifier } == ["ai.picked-target", "digestion", "ai.picked-target"])
        #expect(rows.map { $0.endReason } == [.cancelled, .cancelled, nil])
    }

    // MARK: - Re-entrancy: a superseded row is never published

    /// The actor is re-entrant. An evaluation reads meal soon and is still
    /// suspended on that read when Exercise starts and is published. The row
    /// the evaluation is holding has been superseded, so it reads again, and
    /// Exercise is what ends up published and what the tick doses with.
    /// Publishing what it first read would leave the screens on meal soon
    /// while the store holds Exercise.
    @Test func aStartThatLandsDuringAnEvaluationIsWhatEndsUpPublished() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        let snapshot = settings.snapshot()
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: snapshot)

        let exerciseAt = now + 10.minutesToSeconds()
        await store.setAfterNextOpenRead {
            try? await service.start(.exercise, at: exerciseAt, duration: 1.hoursToSeconds(), settings: snapshot)
        }
        let answer = await service.targetGlucose(at: exerciseAt + 1.minutesToSeconds(), settings: snapshot)

        #expect(state.targetOverride?.kind == .exercise)
        #expect(state.targetOverride?.startedAt == exerciseAt)
        #expect(answer.fields == expectedAnswer(for: .exercise))
        #expect(try await store.openTargetOverride() == state.targetOverride)
    }

    /// The same window on the other suspension. An evaluation finds meal soon
    /// expired and is suspended writing its end when Digestion starts and is
    /// published. Publishing "nothing is on" after that would drop the
    /// switch while Digestion runs.
    @Test func aStartThatLandsWhileAnExpiryIsBeingRecordedIsNotPublishedOver() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        let snapshot = settings.snapshot()
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: snapshot)

        let later = now + 2.hoursToSeconds()
        await store.setAfterNextEndWrite {
            try? await service.start(.digestion, at: later, duration: 2.hoursToSeconds(), settings: snapshot)
        }
        let answer = await service.targetGlucose(at: later, settings: snapshot)

        #expect(state.targetOverride?.kind == .digestion)
        #expect(answer.fields == expectedAnswer(for: .digestion))
        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.policyIdentifier } == ["mealSoon", "digestion"])
        #expect(rows.map { $0.endReason } == [.expired, nil])
        #expect(rows[0].endedAt == now + 60.minutesToSeconds())
    }

    /// And a cancel that lands during an evaluation: the row it read is
    /// closed by the time the read returns, so nothing is published as on.
    @Test func aCancelThatLandsDuringAnEvaluationIsWhatEndsUpPublished() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        let snapshot = settings.snapshot()
        try await service.start(.exercise, at: now, duration: 1.hoursToSeconds(), settings: snapshot)

        let cancelledAt = now + 10.minutesToSeconds()
        await store.setAfterNextOpenRead {
            try? await service.cancelOverride(at: cancelledAt)
        }
        let answer = await service.targetGlucose(at: cancelledAt + 1, settings: snapshot)

        #expect(state.targetOverride == nil)
        #expect(answer.fields == .settings(90))
    }

    // MARK: - Fail directions

    /// The end-write is log-only. If it fails the rule still evaluates to
    /// ended on the next call from the row and the clock.
    @Test func aFailingEndWriteStillReturnsTheSettingsTarget() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        await store.setFailWrites(true)

        let expired = now + 60.minutesToSeconds()
        #expect(await service.targetGlucose(at: expired, settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)
        // The row is still open in the store, and the next evaluation agrees
        // anyway.
        #expect(try await store.openTargetOverride() != nil)
        #expect(await service.targetGlucose(at: expired + 1, settings: settings.snapshot()).fields == .settings(90))
    }

    @Test func aFailingReadReturnsTheSettingsTarget() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        #expect(state.targetOverride != nil)

        await store.setFailReads(true)
        #expect(await service.targetGlucose(at: now + 1, settings: settings.snapshot()).fields == .settings(90),
                "the settings target is the higher one")
        #expect(state.targetOverride == nil)
    }

    @Test func noStoreMeansTheSettingsTarget() async throws {
        let (service, state) = makeService(store: nil)

        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)
        #expect(await service.activeOverride(at: now) == nil)

        for kind in TargetOverrideKind.allCases {
            await #expect(throws: TargetGlucoseServiceError.self) {
                try await service.start(kind, at: now, duration: kind.defaultDuration, settings: settings.snapshot())
            }
        }
        // Nothing to cancel is not an error.
        try await service.cancelOverride(at: now)
        #expect(state.targetOverride == nil)
    }

    /// `AppObservableState.targetOverride` is hydrated by the first
    /// `activeOverride` call, not at construction (§4.3): a row left open by a previous process
    /// is picked up by whoever asks first.
    @Test func activeOverrideHydratesTheObservableStateFromTheStore() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        _ = try await store.startTargetOverride(
            policyIdentifier: "mealSoon",
            effect: OverrideEffect(targetOffsetMgDl: -15, dosingMultiplier: nil),
            at: now,
            expiresAt: now + 60.minutesToSeconds(),
            settingsTargetMgDl: 90
        )

        let (service, state) = makeService(store: store)
        #expect(state.targetOverride == nil, "nothing is read at construction")
        let open = await service.activeOverride(at: now + 1)
        #expect(open?.startedAt == now)
        #expect(state.targetOverride == open)
    }

    // MARK: - Exercise soon (dev/backlog/exercise.md §6)
    //
    // What these call exercise soon is what exercise.md calls exercise.

    @Test func exerciseSoonRaisesTheTargetForTheChosenDuration() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.start(.exerciseSoon, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .exerciseSoon)
        #expect(state.targetOverride?.startedAt == now)
        #expect(state.targetOverride?.expiresAt == now + 2.hoursToSeconds())
        #expect(state.targetOverride?.duration == 2.hoursToSeconds())

        #expect(await service.targetGlucose(at: now + 119.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .exerciseSoon))
        #expect(await service.targetGlucose(at: now + 120.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 1)
        #expect(rows[0].kind == .exerciseSoon)
        #expect(rows[0].endedAt == now + 2.hoursToSeconds())
        #expect(rows[0].endReason == .expired)
    }

    /// The settings clamp applies to the settings target before the raise,
    /// and the guardrail range above it is wide enough that the raise is not
    /// cut back to the settings ceiling (exercise, decision 1).
    @Test func exerciseSoonIsNotCappedAtTheSettingsCeiling() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)
        try await service.start(.exerciseSoon, at: now, duration: 1.hoursToSeconds(), settings: settings.snapshot())

        settings.targetGlucoseInMgDl = 120
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("exerciseSoon", mgDl: 170, settingsMgDl: 120),
                "would be 140 if the settings clamp ran after the raise")
        settings.targetGlucoseInMgDl = 200
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("exerciseSoon", mgDl: 190, settingsMgDl: 140))
        settings.targetGlucoseInMgDl = 60
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .target("exerciseSoon", mgDl: 120, settingsMgDl: 70))
    }

    /// Exercise can be started at the top of the settings picker's range,
    /// where it reaches 190. That is the furthest any of the five goes, and
    /// it is inside the guardrail.
    @Test(arguments: [TargetOverrideKind.exerciseSoon, .exercise])
    func theExerciseSettingsStartAtTheTopOfTheSettingsRange(kind: TargetOverrideKind) async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)
        settings.targetGlucoseInMgDl = 140

        try await service.start(kind, at: now, duration: kind.defaultDuration, settings: settings.snapshot())
        let answer = await service.targetGlucose(at: now + 1, settings: settings.snapshot())
        #expect(answer.mgDl == 190)
        #expect(answer.overridePolicy == kind.policyIdentifier)
    }

    /// Meal soon and exercise soon cannot both be on: the later setting wins,
    /// in both directions (exercise §3).
    @Test func theLaterOfMealSoonAndExerciseSoonWins() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        try await service.start(.exerciseSoon, at: now + 10.minutesToSeconds(), duration: 2.hoursToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .exerciseSoon)
        #expect(await service.targetGlucose(at: now + 11.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .exerciseSoon))

        try await service.start(.mealSoon, at: now + 20.minutesToSeconds(), duration: MealSoonPolicy.duration, settings: settings.snapshot())
        #expect(state.targetOverride?.kind == .mealSoon)
        #expect(await service.targetGlucose(at: now + 21.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .mealSoon))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.kind } == [.mealSoon, .exerciseSoon, .mealSoon])
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
    @Test func startingExerciseSoonAgainRestartsItFromNowWithTheNewDuration() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.start(.exerciseSoon, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        try await service.start(.exerciseSoon, at: now + 30.minutesToSeconds(), duration: 1.hoursToSeconds(), settings: settings.snapshot())

        #expect(state.targetOverride?.startedAt == now + 30.minutesToSeconds())
        #expect(state.targetOverride?.expiresAt == now + 90.minutesToSeconds())
        #expect(state.targetOverride?.duration == 1.hoursToSeconds())
        #expect(await service.targetGlucose(at: now + 89.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: .exerciseSoon))
        #expect(await service.targetGlucose(at: now + 90.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 2)
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == now + 30.minutesToSeconds())
        #expect(rows[1].endReason == .expired)
    }

    @Test func cancelClosesAnExerciseSoonRowAsCancelled() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        try await service.start(.exerciseSoon, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())

        let cancelledAt = now + 45.minutesToSeconds()
        try await service.cancelOverride(at: cancelledAt)
        #expect(state.targetOverride == nil)
        #expect(await service.targetGlucose(at: cancelledAt, settings: settings.snapshot()).fields == .settings(90))

        let row = try #require(try await store.targetOverrides(since: .distantPast).first)
        #expect(row.kind == .exerciseSoon)
        #expect(row.endedAt == cancelledAt)
        #expect(row.endReason == .cancelled)
    }

    @Test(arguments: TargetOverrideKind.allCases)
    func everyChoiceOfEveryKindStarts(kind: TargetOverrideKind) async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        for duration in kind.durations {
            try await service.start(kind, at: now, duration: duration, settings: settings.snapshot())
            #expect(state.targetOverride?.kind == kind)
            #expect(state.targetOverride?.duration == duration)
        }
    }

    /// Meal soon runs for the duration it was started with, shorter or longer
    /// than its default hour, and ends when that is up.
    @Test func mealSoonRunsForThePickedDuration() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        let mealSoon = expectedAnswer(for: .mealSoon)

        try await service.start(.mealSoon, at: now, duration: 30.minutesToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.expiresAt == now + 30.minutesToSeconds())
        #expect(await service.targetGlucose(at: now + 29.minutesToSeconds(), settings: settings.snapshot()).fields == mealSoon)
        #expect(await service.targetGlucose(at: now + 30.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))

        let restartedAt = now + 40.minutesToSeconds()
        try await service.start(.mealSoon, at: restartedAt, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        #expect(state.targetOverride?.expiresAt == restartedAt + 2.hoursToSeconds())
        #expect(await service.targetGlucose(at: restartedAt + 90.minutesToSeconds(), settings: settings.snapshot()).fields == mealSoon,
                "still on past the default hour")
        #expect(await service.targetGlucose(at: restartedAt + 2.hoursToSeconds() - 1, settings: settings.snapshot()).fields == mealSoon)
        #expect(await service.targetGlucose(at: restartedAt + 2.hoursToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.endReason } == [.expired, .expired])
        #expect(rows.map { $0.endedAt } == [now + 30.minutesToSeconds(), restartedAt + 2.hoursToSeconds()])
    }

    // MARK: - The five settings (dev/backlog/more-settings-automation.md)

    /// The Status section of the Settings automation screen shows a target
    /// and a multiplier without asking the service. It applies
    /// `OverrideGuardrails.resolve` to the published row, which is the rule
    /// the service applies to the stored one. This holds the two together,
    /// clamps included, so the status cannot show a number the loop is not
    /// dosing with.
    @Test(arguments: [60.0, 80, 90, 120, 140, 200])
    func theStatusIsWhatTheServiceDosesWith(settingsTargetMgDl: Double) async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        settings.targetGlucoseInMgDl = settingsTargetMgDl

        let withNothingOn = await service.targetGlucose(at: now, settings: settings.snapshot())
        #expect(OverrideGuardrails.resolve(override: state.targetOverride, at: now, settingsTargetMgDl: settingsTargetMgDl) == withNothingOn)
        #expect(SettingsAutomationView.dosingMultiplierText(for: withNothingOn.dosingOverride) == "1x")

        for kind in TargetOverrideKind.allCases {
            try await service.start(kind, at: now, duration: kind.defaultDuration, settings: settings.snapshot())
            let answer = await service.targetGlucose(at: now, settings: settings.snapshot())
            #expect(OverrideGuardrails.resolve(override: state.targetOverride, at: now, settingsTargetMgDl: settingsTargetMgDl) == answer, "\(kind)")
        }
    }

    @Test func theStatusWritesTheMultiplierTheWayTheScreenShowsIt() {
        #expect(SettingsAutomationView.dosingMultiplierText(for: nil) == "1x")
        #expect(SettingsAutomationView.dosingMultiplierText(for: DosingOverride(dosingMultiplier: 1.3)) == "1.3x")
        #expect(SettingsAutomationView.dosingMultiplierText(for: DosingOverride(dosingMultiplier: 0.6)) == "0.6x")
    }

    @Test(arguments: TargetOverrideKind.allCases)
    func eachKindReportsItsTargetAndDosingOverrideAndExpiresOnTheClock(kind: TargetOverrideKind) async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)
        let duration = kind.defaultDuration

        try await service.start(kind, at: now, duration: duration, settings: settings.snapshot())
        #expect(state.targetOverride?.kind == kind)
        #expect(state.targetOverride?.policyIdentifier == kind.policyIdentifier)
        #expect(state.targetOverride?.effect == kind.effect(settingsTargetMgDl: 90))
        #expect(state.targetOverride?.startedAt == now)
        #expect(state.targetOverride?.expiresAt == now + duration)

        #expect(await service.targetGlucose(at: now + duration - 1, settings: settings.snapshot()).fields == expectedAnswer(for: kind))
        #expect(state.targetOverride?.isActive(at: now + duration - 1) == true)

        // Expiry is a function of the row and the clock, and it takes the
        // dosing override with it.
        #expect(await service.targetGlucose(at: now + duration, settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.count == 1)
        #expect(rows[0].kind == kind)
        #expect(rows[0].endedAt == now + duration)
        #expect(rows[0].endReason == .expired)
    }

    /// Digestion and post exercise leave the target alone, so their answer
    /// follows the settings target, clamp included, and still carries the
    /// multiplier.
    @Test func aDosingOnlyKindFollowsTheSettingsTarget() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, _) = makeService(store: store)
        try await service.start(.digestion, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())

        settings.targetGlucoseInMgDl = 120
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .dosingOnly("digestion", settingsMgDl: 120, dosingMultiplier: 1.3))
        settings.targetGlucoseInMgDl = 200
        #expect(await service.targetGlucose(at: now, settings: settings.snapshot()).fields == .dosingOnly("digestion", settingsMgDl: 140, dosingMultiplier: 1.3))
    }

    /// All five are mutually exclusive: starting any kind closes whatever is
    /// open, itself included, as cancelled. The target and the dosing override
    /// both come from the later row, so a tick never pairs one setting's
    /// target with another's multiplier.
    @Test(arguments: TargetOverrideKind.allCases, TargetOverrideKind.allCases)
    func startingAnyKindSupersedesAnyOther(first: TargetOverrideKind, second: TargetOverrideKind) async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.start(first, at: now, duration: first.defaultDuration, settings: settings.snapshot())
        let secondAt = now + 10.minutesToSeconds()
        try await service.start(second, at: secondAt, duration: second.defaultDuration, settings: settings.snapshot())

        #expect(state.targetOverride?.kind == second)
        #expect(state.targetOverride?.startedAt == secondAt)
        #expect(await service.targetGlucose(at: secondAt + 1.minutesToSeconds(), settings: settings.snapshot()).fields == expectedAnswer(for: second))

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.kind } == [first, second])
        #expect(rows[0].endReason == .cancelled)
        #expect(rows[0].endedAt == secondAt)
        #expect(rows[1].endedAt == nil)
    }

    /// Nothing chains: meal soon ending does not start digestion, and exercise
    /// ending does not start post exercise. Every start is a call to `start`.
    @Test func nothingStartsWhenASettingEnds() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let (service, state) = makeService(store: store)

        try await service.start(.mealSoon, at: now, duration: MealSoonPolicy.duration, settings: settings.snapshot())
        #expect(await service.targetGlucose(at: now + 60.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(await service.targetGlucose(at: now + 90.minutesToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let exerciseAt = now + 2.hoursToSeconds()
        try await service.start(.exercise, at: exerciseAt, duration: 1.hoursToSeconds(), settings: settings.snapshot())
        #expect(await service.targetGlucose(at: exerciseAt + 1.hoursToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(await service.targetGlucose(at: exerciseAt + 2.hoursToSeconds(), settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)

        let rows = try await store.targetOverrides(since: .distantPast)
        #expect(rows.map { $0.kind } == [.mealSoon, .exercise])
        #expect(rows.map { $0.endReason } == [.expired, .expired])
    }

    // MARK: - Fail directions with a dosing override on

    /// The fail directions extend the target's: a failing read means the
    /// settings target and no dosing override.
    @Test(arguments: [TargetOverrideKind.digestion, .exercise, .postExercise])
    func aFailingReadDropsTheDosingOverride(kind: TargetOverrideKind) async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.start(kind, at: now, duration: kind.defaultDuration, settings: settings.snapshot())
        #expect(await service.targetGlucose(at: now + 1, settings: settings.snapshot()).fields == expectedAnswer(for: kind))

        await store.setFailReads(true)
        #expect(await service.targetGlucose(at: now + 2, settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)
    }

    /// The end-write is log-only for these too: an expired dosing override
    /// stays off even when the store could not record that it ended.
    @Test func aFailingEndWriteStillDropsTheDosingOverride() async throws {
        let store = MockLoopRecordStore()
        let (service, state) = makeService(store: store)
        try await service.start(.digestion, at: now, duration: 2.hoursToSeconds(), settings: settings.snapshot())
        await store.setFailWrites(true)

        let expired = now + 2.hoursToSeconds()
        #expect(await service.targetGlucose(at: expired, settings: settings.snapshot()).fields == .settings(90))
        #expect(state.targetOverride == nil)
        #expect(try await store.openTargetOverride() != nil, "the row is still open in the store")
        #expect(await service.targetGlucose(at: expired + 1, settings: settings.snapshot()).fields == .settings(90))
    }

    /// One read of the open row per tick, so the target and the multiplier
    /// always come from the same row.
    @Test func theOpenRowIsReadOncePerTick() async throws {
        let store = MockLoopRecordStore()
        let (service, _) = makeService(store: store)
        try await service.start(.exercise, at: now, duration: 1.hoursToSeconds(), settings: settings.snapshot())

        let before = await store.readCount
        _ = await service.targetGlucose(at: now + 1, settings: settings.snapshot())
        #expect(await store.readCount == before + 1)
    }
}
