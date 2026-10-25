//
//  ExercisePolicyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 10/25/26.
//
//  `ExercisePolicy`, which is pure: the override's target for a settings
//  target, and the exercise side of `TargetOverridePolicy.status` — the clock
//  ends it, a manual bolus does not. See dev/backlog/exercise.md §2 and §6.
//

import Testing
import Foundation
import LoopKit
@testable import BioKernel

struct ExercisePolicyTests {

    let startedAt = Date.f("2026-10-25 12:00:00 +0000")
    var expiresAt: Date { startedAt + ExercisePolicy.defaultDuration }

    // MARK: - Fixtures

    private func override(
        endedAt: Date? = nil,
        endReason: TargetOverrideEndReason? = nil
    ) -> TargetOverride {
        return TargetOverride(
            id: 1,
            kind: .exercise,
            startedAt: startedAt,
            expiresAt: expiresAt,
            settingsTargetMgDl: 90,
            endedAt: endedAt,
            endReason: endReason,
            endBolusSyncIdentifier: nil
        )
    }

    private func bolus(at: Date, automatic: Bool?, syncIdentifier: String) -> DoseEntry {
        return DoseEntry(
            type: .bolus,
            startDate: at,
            endDate: at + 40,
            value: 1.5,
            unit: .units,
            syncIdentifier: syncIdentifier,
            insulinType: .lyumjev,
            automatic: automatic
        )
    }

    // MARK: - target

    @Test func targetRaisesFifty() {
        #expect(ExercisePolicy.target(settingsTargetMgDl: 90) == 140)
        #expect(ExercisePolicy.target(settingsTargetMgDl: 80) == 130)
        #expect(ExercisePolicy.target(settingsTargetMgDl: 120) == 170)
        #expect(ExercisePolicy.target(settingsTargetMgDl: 140) == 190)
    }

    /// The service's clamp applies to the settings target *before* the raise,
    /// not after it. Clamping after would turn "+50" into "140" for any
    /// settings target of 90 or more (decision 1).
    @Test func theSettingsTargetIsClampedBeforeTheRaise() {
        #expect(ExercisePolicy.target(settingsTargetMgDl: 200) == 190, "clamped down to 140, then +50")
        #expect(ExercisePolicy.target(settingsTargetMgDl: 60) == 120, "clamped up to 70, then +50")
    }

    @Test func theDefaultDurationIsTwoHoursAndIsOneOfTheChoices() {
        #expect(ExercisePolicy.defaultDuration == 2.hoursToSeconds())
        #expect(ExercisePolicy.durations.contains(ExercisePolicy.defaultDuration))
        #expect(ExercisePolicy.durations == ExercisePolicy.durations.sorted(), "offered shortest to longest")
        #expect(ExercisePolicy.durations.allSatisfy { $0 > 0 })
    }

    // MARK: - status: the clock

    @Test func activeOneSecondBeforeExpiry() {
        let status = TargetOverridePolicy.status(of: override(), at: expiresAt - 1, doses: [])
        #expect(status == .active)
    }

    @Test func expiredAtExactlyTheDuration() {
        let status = TargetOverridePolicy.status(of: override(), at: expiresAt, doses: [])
        #expect(status == .ended(at: expiresAt, reason: .expired, bolusSyncIdentifier: nil))
    }

    // MARK: - status: boluses

    /// A snack bolus during a long workout should not drop the raised target
    /// (decision 4). The same dose ends a meal-soon override.
    @Test func aManualBolusDoesNotEndExercise() {
        let bolusAt = startedAt + 20.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 30.minutesToSeconds(),
            doses: [bolus(at: bolusAt, automatic: false, syncIdentifier: "manual-1")]
        )
        #expect(status == .active)
        #expect(!TargetOverrideKind.exercise.endsOnManualBolus)
        #expect(TargetOverrideKind.mealSoon.endsOnManualBolus)
    }

    @Test func aManualBolusDoesNotChangeWhenExerciseExpires() {
        let status = TargetOverridePolicy.status(
            of: override(),
            at: expiresAt + 10.minutesToSeconds(),
            doses: [bolus(at: startedAt + 20.minutesToSeconds(), automatic: nil, syncIdentifier: "unknown")]
        )
        #expect(status == .ended(at: expiresAt, reason: .expired, bolusSyncIdentifier: nil))
    }

    // MARK: - status: a closed row

    @Test func aClosedRowReturnsItsStoredReason() {
        let cancelledAt = startedAt + 5.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(endedAt: cancelledAt, endReason: .cancelled),
            at: startedAt + 3.hoursToSeconds(),
            doses: []
        )
        #expect(status == .ended(at: cancelledAt, reason: .cancelled, bolusSyncIdentifier: nil))
    }

    // MARK: - duration

    @Test func durationIsExpiresMinusStartedToTheSecond() {
        #expect(override().duration == 2.hoursToSeconds())
        let fractional = TargetOverride(
            id: 2,
            kind: .exercise,
            startedAt: startedAt,
            expiresAt: startedAt + 2.hoursToSeconds() + 0.4,
            settingsTargetMgDl: 90,
            endedAt: nil,
            endReason: nil,
            endBolusSyncIdentifier: nil
        )
        #expect(fractional.duration == 2.hoursToSeconds(), "rounded, so a store round trip still matches a picker choice")
    }

    @Test func sourceMapsBackToItsKind() {
        #expect(TargetGlucoseSource.settings.overrideKind == nil)
        #expect(TargetGlucoseSource.mealSoon.overrideKind == .mealSoon)
        #expect(TargetGlucoseSource.exercise.overrideKind == .exercise)
    }
}
