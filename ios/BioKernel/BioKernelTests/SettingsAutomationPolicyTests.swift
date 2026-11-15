//
//  SettingsAutomationPolicyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/13/26.
//
//  The policies: the `DosingOverride` arithmetic, and the table of numbers on
//  `TargetOverrideKind`, which is the five settings the Settings automation
//  screen offers. Which of them move the target and by how much, which scale
//  dosing and by how much, how long each runs and what its picker offers. See
//  dev/backlog/more-settings-automation.md, "The five settings", and
//  dev/backlog/override-mechanism.md, "Policies".
//
//  The numbers are written out here, not read back from the kind, so a wrong
//  entry in the table is a failure. The target rules themselves are in
//  `MealSoonPolicyTests` and `ExercisePolicyTests`, and the mechanism the
//  settings run on is in `OverrideGuardrailsTests`.
//

import Testing
import Foundation
@testable import BioKernel

struct SettingsAutomationPolicyTests {

    let accuracy = 1e-12
    let startedAt = Date.f("2026-11-13 12:00:00 +0000")

    // MARK: - DosingOverride

    /// basalRateMultiplier = dosingMultiplier, and insulinSensitivityMultiplier
    /// = 1 / dosingMultiplier. So the basal rate is multiplied by it, the
    /// insulin sensitivity is divided by it, and their product does not move.
    @Test(arguments: [1.3, 0.6, 0.8])
    func theBasalRateIsMultipliedAndTheInsulinSensitivityDivided(dosingMultiplier: Double) throws {
        let dosingOverride = try #require(DosingOverride(dosingMultiplier: dosingMultiplier))
        #expect(dosingOverride.dosingMultiplier == dosingMultiplier)
        #expect(dosingOverride.basalRateMultiplier == dosingMultiplier)
        #expect(abs(dosingOverride.insulinSensitivityMultiplier - 1 / dosingMultiplier) <= accuracy)

        let basalRate = 0.85
        let insulinSensitivity = 46.5
        let effectiveBasalRate = basalRate * dosingOverride.basalRateMultiplier
        let effectiveInsulinSensitivity = insulinSensitivity * dosingOverride.insulinSensitivityMultiplier
        #expect(abs(effectiveBasalRate - basalRate * dosingMultiplier) <= accuracy)
        #expect(abs(effectiveInsulinSensitivity - insulinSensitivity / dosingMultiplier) <= accuracy)
        #expect(abs(effectiveBasalRate * effectiveInsulinSensitivity - basalRate * insulinSensitivity) <= accuracy)
    }

    /// A higher basal rate and a lower sensitivity both mean more insulin.
    @Test func aMultiplierAboveOneMeansMoreInsulinAndBelowOneMeansLess() throws {
        let more = try #require(DosingOverride(dosingMultiplier: 1.3))
        #expect(more.basalRateMultiplier > 1)
        #expect(more.insulinSensitivityMultiplier < 1)

        let less = try #require(DosingOverride(dosingMultiplier: 0.6))
        #expect(less.basalRateMultiplier < 1)
        #expect(less.insulinSensitivityMultiplier > 1)
    }

    /// A multiplier that is not greater than zero is no dosing override, and
    /// so is one that is not a finite number. Neither can be divided by.
    @Test(arguments: [0, -0.5, Double.infinity, -Double.infinity, Double.nan])
    func aMultiplierThatCannotBeDividedByIsNoDosingOverride(dosingMultiplier: Double) {
        #expect(DosingOverride(dosingMultiplier: dosingMultiplier) == nil)
    }

    // MARK: - The five settings

    @Test func theKindsAreInTheOrderTheScreenListsThem() {
        #expect(TargetOverrideKind.allCases == [.mealSoon, .digestion, .exerciseSoon, .exercise, .postExercise])
    }

    /// The policy identifier is what a row is stored under and what a tick
    /// records, so it is part of the schema. `exercise` in particular has to
    /// stay `exercise`.
    @Test func thePolicyIdentifierOfEachKind() {
        #expect(TargetOverrideKind.allCases.map { $0.policyIdentifier } == ["mealSoon", "digestion", "exerciseSoon", "exercise", "postExercise"])
    }

    @Test func theDosingMultiplierOfEachKind() {
        #expect(TargetOverrideKind.mealSoon.effect(settingsTargetMgDl: 90).dosingMultiplier == nil)
        #expect(TargetOverrideKind.digestion.effect(settingsTargetMgDl: 90).dosingMultiplier == 1.3)
        #expect(TargetOverrideKind.exerciseSoon.effect(settingsTargetMgDl: 90).dosingMultiplier == nil)
        #expect(TargetOverrideKind.exercise.effect(settingsTargetMgDl: 90).dosingMultiplier == 0.6)
        #expect(TargetOverrideKind.postExercise.effect(settingsTargetMgDl: 90).dosingMultiplier == 0.8)
    }

    /// Meal soon, exercise soon and exercise move the target. Digestion and
    /// post exercise do not. Exercise is the one kind with both a target
    /// offset and a dosing multiplier.
    @Test func theTargetOffsetOfEachKind() {
        #expect(TargetOverrideKind.mealSoon.effect(settingsTargetMgDl: 90).targetOffsetMgDl == -15)
        #expect(TargetOverrideKind.digestion.effect(settingsTargetMgDl: 90).targetOffsetMgDl == nil)
        #expect(TargetOverrideKind.exerciseSoon.effect(settingsTargetMgDl: 90).targetOffsetMgDl == 50)
        #expect(TargetOverrideKind.exercise.effect(settingsTargetMgDl: 90).targetOffsetMgDl == 50)
        #expect(TargetOverrideKind.postExercise.effect(settingsTargetMgDl: 90).targetOffsetMgDl == nil)

        #expect(TargetOverrideKind.allCases.filter { $0.movesTarget } == [.mealSoon, .exerciseSoon, .exercise])
        // Every kind does something, at any settings target, and whether it
        // moves the target does not depend on the settings target.
        for settingsTargetMgDl in [60.0, 80, 90, 140, 200] {
            for kind in TargetOverrideKind.allCases {
                let effect = kind.effect(settingsTargetMgDl: settingsTargetMgDl)
                #expect((effect.targetOffsetMgDl != nil) == kind.movesTarget, "\(kind) at \(settingsTargetMgDl)")
                #expect(effect.targetOffsetMgDl != nil || effect.dosingMultiplier != nil, "\(kind) at \(settingsTargetMgDl)")
            }
        }
        #expect(TargetOverrideKind.allCases.filter { $0.movesTarget && $0.effect(settingsTargetMgDl: 90).dosingMultiplier != nil } == [.exercise])
    }

    /// One tick of `kind`, started and read at the same settings target.
    private func tick(_ kind: TargetOverrideKind, settingsTargetMgDl: Double) -> TargetGlucoseFields {
        let override = TargetOverride(
            id: 1,
            policyIdentifier: kind.policyIdentifier,
            effect: kind.effect(settingsTargetMgDl: settingsTargetMgDl),
            startedAt: startedAt,
            expiresAt: startedAt + kind.defaultDuration,
            settingsTargetMgDl: settingsTargetMgDl,
            endedAt: nil,
            endReason: nil
        )
        return OverrideGuardrails.resolve(override: override, at: startedAt + 1.minutesToSeconds(), settingsTargetMgDl: settingsTargetMgDl).fields
    }

    /// What each kind doses with at a settings target of 90, written out.
    @Test func whatEachKindDosesWithAtASettingsTargetOfNinety() {
        #expect(tick(.mealSoon, settingsTargetMgDl: 90) == .target("mealSoon", mgDl: 75, settingsMgDl: 90))
        #expect(tick(.digestion, settingsTargetMgDl: 90) == .dosingOnly("digestion", settingsMgDl: 90, dosingMultiplier: 1.3))
        #expect(tick(.exerciseSoon, settingsTargetMgDl: 90) == .target("exerciseSoon", mgDl: 140, settingsMgDl: 90))
        #expect(tick(.exercise, settingsTargetMgDl: 90) == .target("exercise", mgDl: 140, settingsMgDl: 90, dosingMultiplier: 0.6))
        #expect(tick(.postExercise, settingsTargetMgDl: 90) == .dosingOnly("postExercise", settingsMgDl: 90, dosingMultiplier: 0.8))
    }

    /// Storing the effect on the row did not change what the five settings
    /// do. Started and read at one settings target, each kind's effect gives
    /// the target its rule gave when the service worked the target out from
    /// the kind: the meal soon rule clamped to [70, 140] afterwards, the
    /// exercise rule with the settings target clamped first, and the clamped
    /// settings target for the two that leave it alone. On both sides of the
    /// clamp.
    @Test(arguments: [50.0, 60, 70, 75, 80, 85, 89, 90, 100, 120, 140, 145, 150, 160, 200])
    func eachKindsEffectReproducesItsTargetRule(settingsTargetMgDl: Double) {
        let clampedSettingsTarget = min(max(settingsTargetMgDl, 70), 140)
        let mealSoonTarget = min(max(MealSoonPolicy.target(settingsTargetMgDl: settingsTargetMgDl), 70), 140)
        let exerciseTarget = ExercisePolicy.target(settingsTargetMgDl: settingsTargetMgDl)

        #expect(tick(.mealSoon, settingsTargetMgDl: settingsTargetMgDl) == .target("mealSoon", mgDl: mealSoonTarget, settingsMgDl: clampedSettingsTarget))
        #expect(tick(.digestion, settingsTargetMgDl: settingsTargetMgDl) == .dosingOnly("digestion", settingsMgDl: clampedSettingsTarget, dosingMultiplier: 1.3))
        #expect(tick(.exerciseSoon, settingsTargetMgDl: settingsTargetMgDl) == .target("exerciseSoon", mgDl: exerciseTarget, settingsMgDl: clampedSettingsTarget))
        #expect(tick(.exercise, settingsTargetMgDl: settingsTargetMgDl) == .target("exercise", mgDl: exerciseTarget, settingsMgDl: clampedSettingsTarget, dosingMultiplier: 0.6))
        #expect(tick(.postExercise, settingsTargetMgDl: settingsTargetMgDl) == .dosingOnly("postExercise", settingsMgDl: clampedSettingsTarget, dosingMultiplier: 0.8))
    }

    /// None of the five is clipped or refused by the guardrails, at any
    /// settings target and for any duration its picker offers. Exercise at a
    /// settings target of 140 is the furthest any of them reaches: 190.
    @Test(arguments: TargetOverrideKind.allCases)
    func everyKindsEffectAndDurationsPassTheGuardrails(kind: TargetOverrideKind) {
        for settingsTargetMgDl in stride(from: 50.0, through: 200, by: 5) {
            let effect = kind.effect(settingsTargetMgDl: settingsTargetMgDl)
            for duration in kind.durations {
                #expect(OverrideGuardrails.violation(of: effect, duration: duration, settingsTargetMgDl: settingsTargetMgDl) == nil, "\(kind) at \(settingsTargetMgDl) for \(duration) seconds")
            }
        }
        #expect(tick(.exercise, settingsTargetMgDl: 140).mgDl == 190)
        #expect(tick(.exerciseSoon, settingsTargetMgDl: 140).mgDl == 190)
        #expect(tick(.mealSoon, settingsTargetMgDl: 80).mgDl == 75, "the lowest any of them reaches inside the settings picker's range")
    }

    @Test func theDefaultDurationOfEachKind() {
        #expect(TargetOverrideKind.mealSoon.defaultDuration == 60.minutesToSeconds())
        #expect(TargetOverrideKind.digestion.defaultDuration == 2.hoursToSeconds())
        #expect(TargetOverrideKind.exerciseSoon.defaultDuration == 2.hoursToSeconds())
        #expect(TargetOverrideKind.exercise.defaultDuration == 1.hoursToSeconds())
        #expect(TargetOverrideKind.postExercise.defaultDuration == 30.minutesToSeconds())
    }

    /// In minutes. Meal soon runs 30 minutes to 2 hours in 30 minute steps;
    /// digestion and exercise run 30 minutes to 3 hours in 30 minute steps;
    /// exercise soon keeps the picker it had, including the 4 hour maximum;
    /// post exercise stops at 90 minutes.
    @Test func theDurationChoicesOfEachKind() {
        func minutes(_ kind: TargetOverrideKind) -> [Double] {
            return kind.durations.map { $0 / 60 }
        }
        #expect(minutes(.mealSoon) == [30, 60, 90, 120])
        #expect(minutes(.digestion) == [30, 60, 90, 120, 150, 180])
        #expect(minutes(.exerciseSoon) == [30, 60, 90, 120, 180, 240])
        #expect(minutes(.exercise) == [30, 60, 90, 120, 150, 180])
        #expect(minutes(.postExercise) == [30, 60, 90])
    }

    @Test(arguments: TargetOverrideKind.allCases)
    func theDefaultIsOneOfTheChoicesAndTheyAreOfferedShortestFirst(kind: TargetOverrideKind) {
        #expect(kind.durations.contains(kind.defaultDuration))
        #expect(kind.durations == kind.durations.sorted())
        #expect(kind.durations.allSatisfy { $0 > 0 })
        #expect(Set(kind.durations).count == kind.durations.count, "no choice is offered twice")
    }

    // MARK: - Ending

    /// Every kind ends on the clock, at the expiry it was started with, and
    /// on nothing else. A manual bolus used to end meal soon. That rule is
    /// gone from the mechanism, and nothing in the status rule takes a dose.
    @Test(arguments: TargetOverrideKind.allCases)
    func everyKindEndsOnTheClock(kind: TargetOverrideKind) {
        let expiresAt = startedAt + kind.defaultDuration
        let override = TargetOverride(
            id: 1,
            policyIdentifier: kind.policyIdentifier,
            effect: kind.effect(settingsTargetMgDl: 90),
            startedAt: startedAt,
            expiresAt: expiresAt,
            settingsTargetMgDl: 90,
            endedAt: nil,
            endReason: nil
        )
        #expect(override.kind == kind)
        #expect(OverrideGuardrails.status(of: override, at: startedAt + 20.minutesToSeconds()) == .active)
        #expect(OverrideGuardrails.status(of: override, at: expiresAt - 1) == .active)
        #expect(OverrideGuardrails.status(of: override, at: expiresAt) == .ended(at: expiresAt, reason: .expired))
    }
}
