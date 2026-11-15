//
//  ExercisePolicyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 10/25/26.
//
//  `ExercisePolicy`, which is pure: the target exercise soon and exercise
//  share for a settings target, the offset they start with, and the exercise
//  soon side of the clock. See dev/backlog/exercise.md §2 and §6.
//
//  Exercise soon is what was called exercise when these were written, and it
//  still does exactly what that did. The table of numbers for all five kinds
//  is in `SettingsAutomationPolicyTests`, and the status rule itself is in
//  `OverrideGuardrailsTests`.
//

import Testing
import Foundation
@testable import BioKernel

struct ExercisePolicyTests {

    let startedAt = Date.f("2026-10-25 12:00:00 +0000")
    var expiresAt: Date { startedAt + TargetOverrideKind.exerciseSoon.defaultDuration }

    // MARK: - Fixtures

    private func override(
        endedAt: Date? = nil,
        endReason: TargetOverrideEndReason? = nil
    ) -> TargetOverride {
        return TargetOverride(
            id: 1,
            policyIdentifier: TargetOverrideKind.exerciseSoon.policyIdentifier,
            effect: TargetOverrideKind.exerciseSoon.effect(settingsTargetMgDl: 90),
            startedAt: startedAt,
            expiresAt: expiresAt,
            settingsTargetMgDl: 90,
            endedAt: endedAt,
            endReason: endReason
        )
    }

    // MARK: - target

    @Test func targetRaisesFifty() {
        #expect(ExercisePolicy.target(settingsTargetMgDl: 90) == 140)
        #expect(ExercisePolicy.target(settingsTargetMgDl: 80) == 130)
        #expect(ExercisePolicy.target(settingsTargetMgDl: 120) == 170)
        #expect(ExercisePolicy.target(settingsTargetMgDl: 140) == 190)
    }

    /// The [70, 140] clamp applies to the settings target *before* the raise,
    /// not after it. Clamping after would turn "+50" into "140" for any
    /// settings target of 90 or more (decision 1).
    @Test func theSettingsTargetIsClampedBeforeTheRaise() {
        #expect(ExercisePolicy.target(settingsTargetMgDl: 200) == 190, "clamped down to 140, then +50")
        #expect(ExercisePolicy.target(settingsTargetMgDl: 60) == 120, "clamped up to 70, then +50")
    }

    /// Both exercise settings start with the raise as their offset, whatever
    /// the settings target, and the override manager adds it to the clamped
    /// settings target of each tick. So the override follows a change to the
    /// settings target while it is on, and lands on the rule.
    @Test func theOffsetIsTheRaiseAndTheTickLandsOnTheRule() {
        for kind in [TargetOverrideKind.exerciseSoon, .exercise] {
            for settingsTargetMgDl in [60.0, 80, 90, 120, 140, 200] {
                #expect(kind.effect(settingsTargetMgDl: settingsTargetMgDl).targetOffsetMgDl == ExercisePolicy.raiseMgDl)
            }
        }
        for settingsTargetMgDl in [60.0, 80, 90, 120, 140, 200] {
            let answer = OverrideGuardrails.resolve(override: override(), at: startedAt + 1, settingsTargetMgDl: settingsTargetMgDl)
            #expect(answer.mgDl == ExercisePolicy.target(settingsTargetMgDl: settingsTargetMgDl), "\(settingsTargetMgDl)")
        }
    }

    /// Exercise soon keeps the picker exercise had, including the four hour
    /// maximum, which is also the guardrail's.
    @Test func theDefaultDurationIsTwoHoursAndIsOneOfTheChoices() {
        let exerciseSoon = TargetOverrideKind.exerciseSoon
        #expect(exerciseSoon.defaultDuration == 2.hoursToSeconds())
        #expect(exerciseSoon.durations.contains(exerciseSoon.defaultDuration))
        #expect(exerciseSoon.durations == [30, 60, 90, 120, 180, 240].map { $0.minutesToSeconds() })
        #expect(exerciseSoon.durations.max() == OverrideGuardrails.maxDuration)
    }

    // MARK: - status: the clock

    @Test func activeOneSecondBeforeExpiry() {
        #expect(OverrideGuardrails.status(of: override(), at: expiresAt - 1) == .active)
    }

    @Test func expiredAtExactlyTheDuration() {
        #expect(OverrideGuardrails.status(of: override(), at: expiresAt) == .ended(at: expiresAt, reason: .expired))
    }

    // MARK: - status: a closed row

    @Test func aClosedRowReturnsItsStoredReason() {
        let cancelledAt = startedAt + 5.minutesToSeconds()
        let status = OverrideGuardrails.status(
            of: override(endedAt: cancelledAt, endReason: .cancelled),
            at: startedAt + 3.hoursToSeconds()
        )
        #expect(status == .ended(at: cancelledAt, reason: .cancelled))
    }
}
