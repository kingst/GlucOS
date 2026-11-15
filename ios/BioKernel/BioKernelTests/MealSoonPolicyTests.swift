//
//  MealSoonPolicyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 10/20/26.
//
//  `MealSoonPolicy`, which is pure: meal soon's target for a settings
//  target, the offset it starts with, and what that offset does while it is
//  on. See dev/backlog/meal-soon.md §4.1 and dev/backlog/override-mechanism.md,
//  "The effect is stored on the row".
//
//  Meal soon used to end on a manual bolus, and the cases for that were here.
//  The override manager now ends on the clock alone
//  (override-mechanism, "Ending is on the clock"), so they are gone. The
//  status rule is in `OverrideGuardrailsTests`, and the other kinds' numbers
//  are in `SettingsAutomationPolicyTests`.
//

import Testing
import Foundation
@testable import BioKernel

struct MealSoonPolicyTests {

    let startedAt = Date.f("2026-10-20 12:00:00 +0000")
    var expiresAt: Date { startedAt + MealSoonPolicy.duration }

    // MARK: - Fixtures

    /// Meal soon as the screen starts it at `settingsTargetMgDl`.
    private func override(
        startedAtSettingsTargetMgDl settingsTargetMgDl: Double = 90,
        endedAt: Date? = nil,
        endReason: TargetOverrideEndReason? = nil
    ) -> TargetOverride {
        return TargetOverride(
            id: 1,
            policyIdentifier: TargetOverrideKind.mealSoon.policyIdentifier,
            effect: TargetOverrideKind.mealSoon.effect(settingsTargetMgDl: settingsTargetMgDl),
            startedAt: startedAt,
            expiresAt: expiresAt,
            settingsTargetMgDl: settingsTargetMgDl,
            endedAt: endedAt,
            endReason: endReason
        )
    }

    /// The target a tick ten minutes in doses toward.
    private func target(_ override: TargetOverride, settingsTargetMgDl: Double) -> Double {
        return OverrideGuardrails.resolve(override: override, at: startedAt + 10.minutesToSeconds(), settingsTargetMgDl: settingsTargetMgDl).mgDl
    }

    // MARK: - target

    @Test func targetDropsFifteenWithAFloorOfSeventyFive() {
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 90) == 75)
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 80) == 75, "floored, not 65")
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 120) == 105)
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 140) == 125)
    }

    // MARK: - the offset it starts with

    /// -15 for a settings target of 90 or more, and smaller below it, down to
    /// -5 at the bottom of the settings picker's range.
    @Test func theOffsetIsTheRuleLessTheSettingsTarget() {
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 140) == -15)
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 120) == -15)
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 90) == -15)
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 85) == -10, "the floor takes 5 of the 15")
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 80) == -5)
    }

    /// Outside the picker's range both ends go through the [70, 140] clamp, so
    /// the offset is the difference of the two clamped values.
    @Test func theOffsetIsBetweenTheClampedValues() {
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 200) == 0, "185 and 200 both clamp to 140")
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 145) == -10, "130 against 140")
        #expect(MealSoonPolicy.targetOffset(settingsTargetMgDl: 60) == 5, "the floor of 75 against 70")
    }

    @Test func startedAndReadAtOneSettingsTargetItDosesTowardTheRule() {
        for settingsTargetMgDl in [80.0, 85, 90, 100, 120, 140] {
            let mealSoon = override(startedAtSettingsTargetMgDl: settingsTargetMgDl)
            #expect(target(mealSoon, settingsTargetMgDl: settingsTargetMgDl) == MealSoonPolicy.target(settingsTargetMgDl: settingsTargetMgDl), "\(settingsTargetMgDl)")
        }
    }

    /// The floor is applied once, when meal soon starts. If the settings
    /// target is changed while it is on, the offset carries over and the
    /// floor is not worked out again.
    @Test func theFloorIsFixedWhenMealSoonStarts() {
        // Raised mid-run: started at 80 the offset is -5, so at 120 the
        // target is 115, where the rule on 120 alone would give 105.
        let startedAtEighty = override(startedAtSettingsTargetMgDl: 80)
        #expect(startedAtEighty.effect.targetOffsetMgDl == -5)
        #expect(target(startedAtEighty, settingsTargetMgDl: 120) == 115)

        // Lowered mid-run: started at 90 the offset is the full -15, so at 80
        // the sum is 65 and the guardrail's 70 is the floor, where the rule
        // on 80 alone would give 75.
        let startedAtNinety = override(startedAtSettingsTargetMgDl: 90)
        #expect(startedAtNinety.effect.targetOffsetMgDl == -15)
        #expect(target(startedAtNinety, settingsTargetMgDl: 80) == 70)
        #expect(target(startedAtNinety, settingsTargetMgDl: 85) == 70)
        #expect(target(startedAtNinety, settingsTargetMgDl: 120) == 105, "above the floor nothing differs")
    }

    // MARK: - status: the clock

    @Test func activeOneSecondBeforeExpiry() {
        #expect(OverrideGuardrails.status(of: override(), at: expiresAt - 1) == .active)
    }

    @Test func expiredAtExactlySixtyMinutes() {
        #expect(OverrideGuardrails.status(of: override(), at: expiresAt) == .ended(at: expiresAt, reason: .expired))
    }

    // MARK: - status: a closed row

    /// Cancelling from the UI closes the row directly, and that is how the rule
    /// sees a cancel. The stored reason wins over anything the clock would
    /// otherwise say.
    @Test func aClosedRowReturnsItsStoredReason() {
        let cancelledAt = startedAt + 5.minutesToSeconds()
        let status = OverrideGuardrails.status(
            of: override(endedAt: cancelledAt, endReason: .cancelled),
            at: startedAt + 90.minutesToSeconds()
        )
        #expect(status == .ended(at: cancelledAt, reason: .cancelled))
    }

    /// What an older build left behind when a manual bolus ended meal soon.
    /// The reason still reads back. Nothing writes it any more.
    @Test func aRowClosedByABolusInAnOlderBuildKeepsItsReason() {
        let bolusAt = startedAt + 20.minutesToSeconds()
        let status = OverrideGuardrails.status(
            of: override(endedAt: bolusAt, endReason: .manualBolus),
            at: startedAt + 21.minutesToSeconds()
        )
        #expect(status == .ended(at: bolusAt, reason: .manualBolus))
    }

    // MARK: - isActive

    @Test func isActiveIsOpenAndBeforeExpiry() {
        #expect(override().isActive(at: expiresAt - 1))
        #expect(!override().isActive(at: expiresAt))
        #expect(!override(endedAt: startedAt + 1, endReason: .cancelled).isActive(at: startedAt + 2))
    }
}
