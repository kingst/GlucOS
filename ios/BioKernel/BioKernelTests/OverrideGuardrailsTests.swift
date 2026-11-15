//
//  OverrideGuardrailsTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/15/26.
//
//  `OverrideGuardrails`, which is pure: the absolute bounds on what any
//  override can do, what `start` refuses, what an open row is at an instant,
//  and what a tick doses with given the open row. See
//  dev/backlog/override-mechanism.md, "Guardrails" and "Ending is on the
//  clock".
//
//  This is the mechanism, so nothing here names one of the five settings.
//  Every row is built by hand under a made-up policy identifier, including
//  the ones `start` would have refused: `resolve` is the last word for a row
//  that did not come through `start`. The five settings' own numbers are in
//  `SettingsAutomationPolicyTests`.
//

import Testing
import Foundation
@testable import BioKernel

struct OverrideGuardrailsTests {

    let startedAt = Date.f("2026-11-15 12:00:00 +0000")
    let policy = "test-policy"

    // MARK: - Fixtures

    private func override(
        targetOffsetMgDl: Double? = nil,
        dosingMultiplier: Double? = nil,
        duration: TimeInterval = 1.hoursToSeconds(),
        endedAt: Date? = nil,
        endReason: TargetOverrideEndReason? = nil
    ) -> TargetOverride {
        return TargetOverride(
            id: 1,
            policyIdentifier: policy,
            effect: OverrideEffect(targetOffsetMgDl: targetOffsetMgDl, dosingMultiplier: dosingMultiplier),
            startedAt: startedAt,
            expiresAt: startedAt + duration,
            settingsTargetMgDl: 90,
            endedAt: endedAt,
            endReason: endReason
        )
    }

    /// What a tick one minute into `override` doses with.
    private func resolved(_ override: TargetOverride?, settingsTargetMgDl: Double = 90) -> TargetGlucoseFields {
        return OverrideGuardrails.resolve(override: override, at: startedAt + 1.minutesToSeconds(), settingsTargetMgDl: settingsTargetMgDl).fields
    }

    // MARK: - The numbers

    /// Written out, so a change to a guardrail is a change to a test.
    @Test func theGuardrailsAreAbsoluteAndHardCoded() {
        #expect(OverrideGuardrails.targetRangeMgDl == 70...200)
        #expect(OverrideGuardrails.dosingMultiplierRange == 0.5...1.5)
        #expect(OverrideGuardrails.maxDuration == 4.hoursToSeconds())
    }

    // MARK: - resolve: no override

    /// The settings target keeps its own [70, 140] clamp.
    @Test(arguments: [(60.0, 70.0), (70, 70), (90, 90), (140, 140), (200, 140)])
    func withNoOverrideTheAnswerIsTheClampedSettingsTarget(settingsTargetMgDl: Double, expected: Double) {
        #expect(resolved(nil, settingsTargetMgDl: settingsTargetMgDl) == .settings(expected))
    }

    // MARK: - resolve: inside the guardrails

    @Test func theOffsetIsAddedToTheSettingsTarget() {
        #expect(resolved(override(targetOffsetMgDl: -15)) == .target(policy, mgDl: 75, settingsMgDl: 90))
        #expect(resolved(override(targetOffsetMgDl: 50)) == .target(policy, mgDl: 140, settingsMgDl: 90))
        // An offset of zero is still a target override: the row says it sets
        // the target, and where it lands is the settings target.
        #expect(resolved(override(targetOffsetMgDl: 0)) == .target(policy, mgDl: 90, settingsMgDl: 90))
    }

    /// The offset is added to this tick's settings target, after that
    /// target's own clamp. So an override follows a change to the settings
    /// target while it is on, and the settings clamp runs before the offset
    /// and not after it.
    @Test func theOffsetFollowsTheCurrentSettingsTargetAfterItsClamp() {
        let raised = override(targetOffsetMgDl: 50)
        #expect(resolved(raised, settingsTargetMgDl: 120) == .target(policy, mgDl: 170, settingsMgDl: 120))
        #expect(resolved(raised, settingsTargetMgDl: 200) == .target(policy, mgDl: 190, settingsMgDl: 140), "clamped down to 140, then +50")
        #expect(resolved(raised, settingsTargetMgDl: 60) == .target(policy, mgDl: 120, settingsMgDl: 70), "clamped up to 70, then +50")
    }

    @Test func aMultiplierIsADosingOverrideAndLeavesTheTargetAlone() {
        #expect(resolved(override(dosingMultiplier: 1.3)) == .dosingOnly(policy, settingsMgDl: 90, dosingMultiplier: 1.3))
        #expect(resolved(override(dosingMultiplier: 0.6), settingsTargetMgDl: 200) == .dosingOnly(policy, settingsMgDl: 140, dosingMultiplier: 0.6))
    }

    @Test func anEffectCanCarryBoth() {
        #expect(resolved(override(targetOffsetMgDl: 50, dosingMultiplier: 0.6)) == .target(policy, mgDl: 140, settingsMgDl: 90, dosingMultiplier: 0.6))
    }

    // MARK: - resolve: the clamps

    /// For a row that did not come through `start`.
    @Test func aTargetOutsideItsRangeIsClampedIntoIt() {
        #expect(resolved(override(targetOffsetMgDl: 100), settingsTargetMgDl: 140) == .target(policy, mgDl: 200, settingsMgDl: 140), "240 before the clamp")
        #expect(resolved(override(targetOffsetMgDl: 1000)) == .target(policy, mgDl: 200, settingsMgDl: 90))
        #expect(resolved(override(targetOffsetMgDl: -60)) == .target(policy, mgDl: 70, settingsMgDl: 90), "30 before the clamp")
        // The ends of the range are inside it.
        #expect(resolved(override(targetOffsetMgDl: 60), settingsTargetMgDl: 140) == .target(policy, mgDl: 200, settingsMgDl: 140))
        #expect(resolved(override(targetOffsetMgDl: -20)) == .target(policy, mgDl: 70, settingsMgDl: 90))
    }

    @Test(arguments: [(3.0, 1.5), (1.51, 1.5), (1.5, 1.5), (1.0, 1.0), (0.5, 0.5), (0.49, 0.5), (0.01, 0.5)])
    func aMultiplierOutsideItsRangeIsClampedIntoIt(dosingMultiplier: Double, expected: Double) {
        #expect(resolved(override(dosingMultiplier: dosingMultiplier)) == .dosingOnly(policy, settingsMgDl: 90, dosingMultiplier: expected))
    }

    /// Not something to clamp, and never something to divide by. The override
    /// is still in effect and still named on the tick. It just does not scale
    /// dosing.
    @Test(arguments: [0, -0.5, Double.infinity, -Double.infinity, Double.nan])
    func aMultiplierThatIsNotAFiniteNumberAboveZeroIsNoDosingOverride(dosingMultiplier: Double) {
        #expect(resolved(override(dosingMultiplier: dosingMultiplier)) == .dosingOnly(policy, settingsMgDl: 90, dosingMultiplier: nil))
        // The target side of the same row is untouched by it.
        #expect(resolved(override(targetOffsetMgDl: 50, dosingMultiplier: dosingMultiplier)) == .target(policy, mgDl: 140, settingsMgDl: 90))
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan])
    func anOffsetThatIsNotFiniteIsNoTargetOverride(targetOffsetMgDl: Double) {
        #expect(resolved(override(targetOffsetMgDl: targetOffsetMgDl)) == .dosingOnly(policy, settingsMgDl: 90, dosingMultiplier: nil))
        #expect(resolved(override(targetOffsetMgDl: targetOffsetMgDl, dosingMultiplier: 0.8)) == .dosingOnly(policy, settingsMgDl: 90, dosingMultiplier: 0.8))
    }

    /// An effect with neither side, which `start` refuses, does nothing.
    @Test func aRowWithNoEffectDosesLikeTheSettings() {
        #expect(resolved(override()) == .dosingOnly(policy, settingsMgDl: 90, dosingMultiplier: nil))
    }

    // MARK: - status: the clock

    @Test func activeFromStartedAtUpToItsExpiry() {
        let open = override(targetOffsetMgDl: -15)
        let expiresAt = startedAt + 1.hoursToSeconds()
        #expect(OverrideGuardrails.status(of: open, at: startedAt) == .active, "the start instant is inside")
        #expect(OverrideGuardrails.status(of: open, at: expiresAt - 1) == .active)
        #expect(OverrideGuardrails.status(of: open, at: expiresAt) == .ended(at: expiresAt, reason: .expired), "the expiry instant is outside")
        #expect(OverrideGuardrails.status(of: open, at: expiresAt + 10.hoursToSeconds()) == .ended(at: expiresAt, reason: .expired), "ended when it stopped applying, not when we noticed")
    }

    /// A row whose `expiresAt` is past the maximum duration ends at the
    /// maximum. No row is in effect for longer than that, whatever it says.
    @Test func aRowThatRunsPastTheMaximumDurationEndsAtTheMaximum() {
        let long = override(targetOffsetMgDl: 50, dosingMultiplier: 0.6, duration: 10.hoursToSeconds())
        let maximum = startedAt + 4.hoursToSeconds()
        #expect(OverrideGuardrails.expiry(of: long) == maximum)
        #expect(OverrideGuardrails.status(of: long, at: maximum - 1) == .active)
        #expect(OverrideGuardrails.status(of: long, at: maximum) == .ended(at: maximum, reason: .expired))
        #expect(OverrideGuardrails.resolve(override: long, at: maximum - 1, settingsTargetMgDl: 90).fields == .target(policy, mgDl: 140, settingsMgDl: 90, dosingMultiplier: 0.6))
        #expect(OverrideGuardrails.resolve(override: long, at: maximum, settingsTargetMgDl: 90).fields == .settings(90))

        // A row inside the maximum keeps its own expiry.
        let short = override(targetOffsetMgDl: 50, duration: 4.hoursToSeconds())
        #expect(OverrideGuardrails.expiry(of: short) == short.expiresAt)
    }

    /// A tick whose time is before `startedAt`: a loop that began before the
    /// tap, or a clock that was set back. It gets the settings target, and
    /// the row is not over. Without the test against `startedAt` a clock set
    /// back an hour would keep the override on for an extra hour.
    @Test func aTimeBeforeStartedAtIsNotStartedAndResolvesToTheSettingsTarget() {
        let open = override(targetOffsetMgDl: -15, dosingMultiplier: 1.3)
        for before in [startedAt - 1, startedAt - 1.hoursToSeconds(), startedAt - 30.0.daysToSeconds()] {
            #expect(OverrideGuardrails.status(of: open, at: before) == .notStarted)
            #expect(OverrideGuardrails.isInEffect(open, at: before) == false)
            #expect(OverrideGuardrails.resolve(override: open, at: before, settingsTargetMgDl: 90).fields == .settings(90))
        }
    }

    /// A damaged row that expires before it starts is over once its expiry
    /// has passed, and is never in effect.
    @Test func aRowThatExpiresBeforeItStartsIsNeverInEffect() {
        let backwards = override(targetOffsetMgDl: -15, duration: -1.hoursToSeconds())
        let expiresAt = startedAt - 1.hoursToSeconds()
        #expect(OverrideGuardrails.status(of: backwards, at: expiresAt - 1) == .notStarted)
        #expect(OverrideGuardrails.status(of: backwards, at: expiresAt) == .ended(at: expiresAt, reason: .expired))
        #expect(OverrideGuardrails.status(of: backwards, at: startedAt + 1) == .ended(at: expiresAt, reason: .expired))
    }

    // MARK: - status: a closed row

    /// `cancel` and a new `start` close the row directly, and the stored
    /// reason wins over anything the clock would otherwise say. `manualBolus`
    /// is a reason only older builds wrote, and a row they closed with it
    /// still reads back.
    @Test(arguments: [TargetOverrideEndReason.cancelled, .expired, .manualBolus])
    func aClosedRowReturnsItsStoredReason(reason: TargetOverrideEndReason) {
        let endedAt = startedAt + 5.minutesToSeconds()
        let closed = override(targetOffsetMgDl: -15, endedAt: endedAt, endReason: reason)
        for at in [startedAt - 1, startedAt + 1.minutesToSeconds(), startedAt + 5.hoursToSeconds()] {
            #expect(OverrideGuardrails.status(of: closed, at: at) == .ended(at: endedAt, reason: reason))
        }
        #expect(resolved(closed) == .settings(90), "a closed row is a log entry and is never in effect")
    }

    @Test func isActiveIsOpenStartedAndBeforeExpiry() {
        let expiresAt = startedAt + 1.hoursToSeconds()
        #expect(override().isActive(at: startedAt))
        #expect(override().isActive(at: expiresAt - 1))
        #expect(!override().isActive(at: expiresAt))
        #expect(!override().isActive(at: startedAt - 1))
        #expect(!override(endedAt: startedAt + 1, endReason: .cancelled).isActive(at: startedAt + 2))
    }

    /// The policy identifier is a label. One nobody has heard of resolves
    /// like any other and comes back on the answer unchanged.
    @Test func anUnknownPolicyIdentifierDosesLikeAnyOther() {
        let unknown = TargetOverride(
            id: 7,
            policyIdentifier: "com.example.some-future-source",
            effect: OverrideEffect(targetOffsetMgDl: 20, dosingMultiplier: 0.9),
            startedAt: startedAt,
            expiresAt: startedAt + 30.minutesToSeconds(),
            settingsTargetMgDl: 90,
            endedAt: nil,
            endReason: nil
        )
        #expect(unknown.kind == nil)
        #expect(resolved(unknown) == .target("com.example.some-future-source", mgDl: 110, settingsMgDl: 90, dosingMultiplier: 0.9))
    }

    // MARK: - duration

    @Test func durationIsExpiresMinusStartedToTheSecond() {
        #expect(override(duration: 2.hoursToSeconds()).duration == 2.hoursToSeconds())
        #expect(override(duration: 2.hoursToSeconds() + 0.4).duration == 2.hoursToSeconds(), "rounded, so a store round trip still matches a picker choice")
    }

    // MARK: - violation: what start refuses

    private func violation(targetOffsetMgDl: Double? = nil, dosingMultiplier: Double? = nil, duration: TimeInterval = 1.hoursToSeconds(), settingsTargetMgDl: Double = 90) -> OverrideGuardrailViolation? {
        return OverrideGuardrails.violation(
            of: OverrideEffect(targetOffsetMgDl: targetOffsetMgDl, dosingMultiplier: dosingMultiplier),
            duration: duration,
            settingsTargetMgDl: settingsTargetMgDl
        )
    }

    @Test func anEffectInsideTheGuardrailsIsAccepted() {
        #expect(violation(targetOffsetMgDl: -15) == nil)
        #expect(violation(dosingMultiplier: 1.3) == nil)
        #expect(violation(targetOffsetMgDl: 50, dosingMultiplier: 0.6) == nil)
        #expect(violation(targetOffsetMgDl: 0) == nil)
    }

    @Test func anEffectWithNeitherSideIsRefused() {
        #expect(violation() == .noEffect)
    }

    @Test(arguments: [Double.infinity, -Double.infinity, Double.nan])
    func aValueThatIsNotFiniteIsRefused(value: Double) {
        #expect(violation(targetOffsetMgDl: value) == .notFinite)
        #expect(violation(dosingMultiplier: value) == .notFinite)
        #expect(violation(targetOffsetMgDl: -15, dosingMultiplier: value) == .notFinite)
        #expect(violation(targetOffsetMgDl: -15, duration: value) == .notFinite)
    }

    /// Above zero, at most four hours. Zero or less would open a row that is
    /// already over.
    @Test func aDurationOutsideItsRangeIsRefused() {
        #expect(violation(targetOffsetMgDl: -15, duration: 0) == .durationOutOfRange)
        #expect(violation(targetOffsetMgDl: -15, duration: -1) == .durationOutOfRange)
        #expect(violation(targetOffsetMgDl: -15, duration: 4.hoursToSeconds() + 1) == .durationOutOfRange)
        #expect(violation(targetOffsetMgDl: -15, duration: 4.hoursToSeconds()) == nil, "the maximum itself is allowed")
        #expect(violation(targetOffsetMgDl: -15, duration: 1) == nil)
    }

    @Test func aMultiplierOutsideItsRangeIsRefused() {
        #expect(violation(dosingMultiplier: 1.51) == .dosingMultiplierOutOfRange)
        #expect(violation(dosingMultiplier: 0.49) == .dosingMultiplierOutOfRange)
        #expect(violation(dosingMultiplier: 0) == .dosingMultiplierOutOfRange)
        #expect(violation(dosingMultiplier: -1) == .dosingMultiplierOutOfRange)
        #expect(violation(dosingMultiplier: 1.5) == nil)
        #expect(violation(dosingMultiplier: 0.5) == nil)
    }

    /// The target is checked where it lands at the settings target of the
    /// moment, after that target's own clamp.
    @Test func aTargetThatLandsOutsideItsRangeIsRefused() {
        #expect(violation(targetOffsetMgDl: 61, settingsTargetMgDl: 140) == .targetOutOfRange, "201")
        #expect(violation(targetOffsetMgDl: 60, settingsTargetMgDl: 140) == nil, "200")
        #expect(violation(targetOffsetMgDl: -21, settingsTargetMgDl: 90) == .targetOutOfRange, "69")
        #expect(violation(targetOffsetMgDl: -20, settingsTargetMgDl: 90) == nil, "70")
        // The same offset is inside at one settings target and outside at
        // another.
        #expect(violation(targetOffsetMgDl: 100, settingsTargetMgDl: 90) == nil, "190")
        #expect(violation(targetOffsetMgDl: 100, settingsTargetMgDl: 120) == .targetOutOfRange, "220")
        // A settings target past its own clamp counts as the clamped value.
        #expect(violation(targetOffsetMgDl: 60, settingsTargetMgDl: 500) == nil, "140 + 60")
        #expect(violation(targetOffsetMgDl: -1, settingsTargetMgDl: 10) == .targetOutOfRange, "70 - 1")
    }

    @Test func everyViolationSaysWhatIsWrong() {
        let violations: [OverrideGuardrailViolation] = [.noEffect, .notFinite, .durationOutOfRange, .dosingMultiplierOutOfRange, .targetOutOfRange]
        let descriptions = violations.compactMap { $0.errorDescription }
        #expect(descriptions.count == violations.count)
        #expect(Set(descriptions).count == violations.count)
        #expect(OverrideGuardrailViolation.durationOutOfRange.errorDescription == "the duration has to be more than zero and at most 4 hours")
        #expect(OverrideGuardrailViolation.dosingMultiplierOutOfRange.errorDescription == "the dosing multiplier has to be 0.5 to 1.5")
        #expect(OverrideGuardrailViolation.targetOutOfRange.errorDescription == "the target has to be 70 to 200 mg/dL")
    }
}
