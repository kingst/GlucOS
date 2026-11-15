//
//  TargetOverride.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//
//  Timed overrides, which the UI calls settings automations. The code is in
//  two halves (dev/backlog/override-mechanism.md).
//
//  The mechanism is the override manager, `TargetGlucoseService`, and the
//  types in the first half of this file. It holds at most one open override.
//  An override is an effect (a target offset, a dosing multiplier, or both)
//  and an expiry. The manager checks the effect against the absolute
//  guardrails in `OverrideGuardrails`, ends the override on the clock, and
//  does nothing else on its own. It knows no setting by name: the policy
//  identifier on a row is a label to it.
//
//  A policy is a named setting such as meal soon. It decides the effect and
//  the duration, and it calls `start` and `cancel`. Anything that moves from
//  one state to another, such as ending early or chaining into another
//  setting, belongs to a policy. The five settings the Settings automation
//  screen offers are `TargetOverrideKind`, in the second half of this file
//  (dev/backlog/more-settings-automation.md, dev/backlog/meal-soon.md,
//  dev/backlog/exercise.md).
//
//  The row type and the table keep the names they had when an override could
//  only move the target.
//
//  Nothing here does I/O. `OverrideGuardrails.status` is a function of a
//  stored row and the clock, so if the app dies at minute 30, the first
//  evaluation after expiry computes "expired" from the row, and nothing can
//  get stuck because there is no state to restore (meal-soon §3).
//

import Foundation

// MARK: - The mechanism: what an override does

/// What one override does while it is in effect: a target offset, a dosing
/// multiplier, or both. A nil value leaves that side alone.
///
/// The effect is stored on the override's row, so what a row does is a fact
/// of the row and not of whichever build reads it.
public struct OverrideEffect: Equatable, Sendable {
    /// Added to each tick's settings target, in mg/dL, after the settings
    /// target's own [70, 140] clamp. The sum is then clamped to
    /// `OverrideGuardrails.targetRangeMgDl`.
    let targetOffsetMgDl: Double?
    /// Scales the basal rate and insulin sensitivity the PID doses with, as
    /// a `DosingOverride`, after a clamp to
    /// `OverrideGuardrails.dosingMultiplierRange`.
    let dosingMultiplier: Double?
}

/// A temporary scaling of the basal rate and insulin sensitivity the PID doses
/// with:
///
///     effectiveBasalRate          = basalRate * basalRateMultiplier
///     effectiveInsulinSensitivity = insulinSensitivity * insulinSensitivityMultiplier
///
/// A `dosingMultiplier` above 1 means more insulin, below 1 means less. The
/// two multipliers are reciprocals, so basal rate times insulin sensitivity is
/// the same with or without the override.
///
/// It changes how much is dosed, and is not treated as a measured change in
/// how the person responds to insulin: the integrator input and the
/// biological invariant stay on the settings values.
///
/// The initializer refuses a multiplier that is not a finite number greater
/// than zero. A bad multiplier is therefore no dosing override at all, never
/// something to divide by, and nothing holding a `DosingOverride` has to check.
public struct DosingOverride: Equatable, Sendable {
    let dosingMultiplier: Double

    init?(dosingMultiplier: Double) {
        guard dosingMultiplier.isFinite, dosingMultiplier > 0 else { return nil }
        self.dosingMultiplier = dosingMultiplier
    }

    var basalRateMultiplier: Double { return dosingMultiplier }
    var insulinSensitivityMultiplier: Double { return 1 / dosingMultiplier }
}

/// What one tick doses with, and why: the target, and the dosing override that
/// came from the same open row.
public struct TargetGlucose: Equatable, Sendable {
    /// The target this tick doses toward.
    let mgDl: Double
    /// What this tick would have dosed toward with no override: the settings
    /// target after its [70, 140] clamp.
    let settingsMgDl: Double
    /// The policy identifier of the override in effect, or nil with none. A
    /// label that is recorded on the tick and never switched on.
    let overridePolicy: String?
    /// Whether that override moves the target. False with no override and
    /// for one that only scales dosing, and `mgDl` is then `settingsMgDl`.
    let overrideMovesTarget: Bool
    /// nil unless the override in effect scales the basal rate and insulin
    /// sensitivity.
    let dosingOverride: DosingOverride?

    /// Private to this file, so `OverrideGuardrails.resolve` is the only code
    /// that can build one and no caller can hand the pipeline a target or a
    /// multiplier that did not go through the guardrails.
    fileprivate init(mgDl: Double, settingsMgDl: Double, overridePolicy: String?, overrideMovesTarget: Bool, dosingOverride: DosingOverride?) {
        self.mgDl = mgDl
        self.settingsMgDl = settingsMgDl
        self.overridePolicy = overridePolicy
        self.overrideMovesTarget = overrideMovesTarget
        self.dosingOverride = dosingOverride
    }
}

// MARK: - The mechanism: the override row

public enum TargetOverrideEndReason: String, Codable, Sendable {
    case expired
    /// Written by builds from before the override manager ended on the clock
    /// alone. Kept so the rows they closed still decode. Nothing writes it.
    case manualBolus
    case cancelled
}

/// One `target_override` row, as a domain value.
///
/// A row that is open (`endedAt == nil`) *is* the live state; a row that is
/// closed is the log entry. There is no separate state file (meal-soon §5.1).
public struct TargetOverride: Equatable, Sendable {
    let id: Int64
    /// Which policy started it. Stored in the row's `kind` column. To the
    /// mechanism this is a label: it is stored, published and recorded, and
    /// never switched on, so a row whose identifier this build does not know
    /// still doses correctly.
    let policyIdentifier: String
    let effect: OverrideEffect
    let startedAt: Date
    /// Stored rather than derived from `startedAt`, so the duration is a fact of
    /// the row and not of whichever build reads it.
    let expiresAt: Date
    /// The user's settings target when the override began. A record, not the
    /// value in use: the offset is added to the *current* settings target on
    /// every tick.
    let settingsTargetMgDl: Double
    let endedAt: Date?
    let endReason: TargetOverrideEndReason?

    /// In effect at `at`: open, started, and not yet past its expiry. The
    /// views' own test, so a banner clears on the clock without waiting for a
    /// loop tick (meal-soon §7.2). The rule is `OverrideGuardrails.status`.
    func isActive(at: Date) -> Bool {
        return OverrideGuardrails.isInEffect(self, at: at)
    }

    /// `expiresAt - startedAt`, to the second. Rounded because both ends went
    /// through the store as epoch-second doubles, and the duration pickers
    /// compare this against their fixed choices.
    var duration: TimeInterval {
        return expiresAt.timeIntervalSince(startedAt).rounded()
    }
}

/// What `OverrideGuardrails.status` concludes about an override at an instant.
public enum TargetOverrideStatus: Equatable {
    /// `at` is before the row's `startedAt`. That is a loop that began before
    /// the tap, which is normal: a tick's time is fixed when it starts and
    /// the target is read later in it. It is also a clock that was set back.
    /// Either way the override is not in effect at `at`, and it is not over.
    case notStarted
    case active
    case ended(at: Date, reason: TargetOverrideEndReason)
}

// MARK: - The mechanism: guardrails

/// Why `TargetGlucoseService.start` refused an override.
enum OverrideGuardrailViolation: LocalizedError, Equatable {
    /// Neither a target offset nor a dosing multiplier.
    case noEffect
    /// The offset, the multiplier or the duration is not a finite number.
    case notFinite
    case durationOutOfRange
    case dosingMultiplierOutOfRange
    /// The offset lands outside the target range at the settings target of
    /// the moment it was started.
    case targetOutOfRange

    var errorDescription: String? {
        switch self {
        case .noEffect:
            return "it changes neither the target nor dosing"
        case .notFinite:
            return "one of its values is not a number"
        case .durationOutOfRange:
            return String(format: "the duration has to be more than zero and at most %g hours", OverrideGuardrails.maxDuration / 1.hoursToSeconds())
        case .dosingMultiplierOutOfRange:
            let range = OverrideGuardrails.dosingMultiplierRange
            return String(format: "the dosing multiplier has to be %g to %g", range.lowerBound, range.upperBound)
        case .targetOutOfRange:
            let range = OverrideGuardrails.targetRangeMgDl
            return String(format: "the target has to be %g to %g mg/dL", range.lowerBound, range.upperBound)
        }
    }
}

/// The absolute bounds on what any override can do, whichever policy started
/// it, and the one rule for what an open row means at an instant
/// (dev/backlog/override-mechanism.md, "Guardrails").
///
/// They are hard-coded, and they are minimum and maximum values for every
/// override, not per-setting ones. They are applied in two places:
///
///   * `violation` is what `start` refuses, so a policy with a wrong number
///     finds out at once and nothing is written.
///   * `resolve` clamps whatever the open row says on every tick. This is the
///     last word, and it covers a row that did not come through `start`: one
///     written by another build, by a test, or damaged.
///
/// What this bounds: no single start can put the target outside
/// `targetRangeMgDl`, or dosing outside `dosingMultiplierRange`, for more
/// than `maxDuration`. The max basal rate, the shutoff, the safety bound and
/// the biological invariant sit underneath and do not move. It does not bound
/// a policy that calls `start` again by itself.
enum OverrideGuardrails {
    /// The target the loop doses toward.
    static let targetRangeMgDl: ClosedRange<Double> = 70...200
    static let dosingMultiplierRange: ClosedRange<Double> = 0.5...1.5
    /// The longest one start can run.
    static let maxDuration: TimeInterval = 4.hoursToSeconds()

    // MARK: At start

    /// What is wrong with starting `effect` for `duration` at this settings
    /// target, or nil when it is inside the guardrails.
    static func violation(of effect: OverrideEffect, duration: TimeInterval, settingsTargetMgDl: Double) -> OverrideGuardrailViolation? {
        guard effect.targetOffsetMgDl != nil || effect.dosingMultiplier != nil else { return .noEffect }
        guard duration.isFinite,
              effect.targetOffsetMgDl?.isFinite ?? true,
              effect.dosingMultiplier?.isFinite ?? true
        else { return .notFinite }
        guard duration > 0, duration <= maxDuration else { return .durationOutOfRange }
        if let dosingMultiplier = effect.dosingMultiplier, !dosingMultiplierRange.contains(dosingMultiplier) {
            return .dosingMultiplierOutOfRange
        }
        if let targetOffsetMgDl = effect.targetOffsetMgDl,
           !targetRangeMgDl.contains(clampedSettingsTarget(settingsTargetMgDl) + targetOffsetMgDl) {
            return .targetOutOfRange
        }
        return nil
    }

    // MARK: On every tick

    /// When an open row stops being in effect, whatever it says: the earlier
    /// of its `expiresAt` and `maxDuration` after its `startedAt`.
    static func expiry(of override: TargetOverride) -> Date {
        return min(override.expiresAt, override.startedAt + maxDuration)
    }

    /// What `override` is at `at`. The clock is the only thing that ends an
    /// open row. `cancel` and a new `start` close the row directly, and those
    /// are calls a policy or the screen makes.
    ///
    /// Checked in this order:
    ///
    /// 1. A row with `endedAt` set is ended, with its stored reason.
    /// 2. `at` at or past `expiry(of:)` ends it at that expiry.
    /// 3. `at` before `startedAt` is not started.
    /// 4. Otherwise it is active.
    static func status(of override: TargetOverride, at: Date) -> TargetOverrideStatus {
        if let endedAt = override.endedAt {
            return .ended(at: endedAt, reason: override.endReason ?? .cancelled)
        }
        let expiry = Self.expiry(of: override)
        if at >= expiry {
            return .ended(at: expiry, reason: .expired)
        }
        if at < override.startedAt {
            return .notStarted
        }
        return .active
    }

    static func isInEffect(_ override: TargetOverride, at: Date) -> Bool {
        return status(of: override, at: at) == .active
    }

    /// What a tick at `at` doses with, given the open row and the settings
    /// target. The one place a `TargetGlucose` is built: the service, the
    /// Status section of the Settings automation screen and the test mock all
    /// call this, so the rule exists once.
    ///
    /// The settings target keeps its own [70, 140] clamp, applied before the
    /// offset. With no override, or one that is not in effect at `at`, the
    /// answer is that clamped settings target and no dosing override.
    /// Otherwise:
    ///
    ///   * The target is the clamped settings target plus the row's offset,
    ///     clamped into `targetRangeMgDl`. The settings target is this
    ///     tick's, so an override follows a change to it while it is on.
    ///   * The multiplier is clamped into `dosingMultiplierRange`.
    ///   * An offset that is not finite is no target override at all, and a
    ///     multiplier that is not a finite number above zero is no dosing
    ///     override at all. Neither can be clamped to something meaningful.
    static func resolve(override: TargetOverride?, at: Date, settingsTargetMgDl: Double) -> TargetGlucose {
        let settingsMgDl = clampedSettingsTarget(settingsTargetMgDl)
        guard let override, isInEffect(override, at: at) else {
            return TargetGlucose(mgDl: settingsMgDl, settingsMgDl: settingsMgDl, overridePolicy: nil, overrideMovesTarget: false, dosingOverride: nil)
        }

        var overrideMgDl: Double? = nil
        if let targetOffsetMgDl = override.effect.targetOffsetMgDl, targetOffsetMgDl.isFinite {
            overrideMgDl = (settingsMgDl + targetOffsetMgDl).clamp(low: targetRangeMgDl.lowerBound, high: targetRangeMgDl.upperBound)
        }

        var dosingOverride: DosingOverride? = nil
        if let dosingMultiplier = override.effect.dosingMultiplier, dosingMultiplier.isFinite, dosingMultiplier > 0 {
            dosingOverride = DosingOverride(dosingMultiplier: dosingMultiplier.clamp(low: dosingMultiplierRange.lowerBound, high: dosingMultiplierRange.upperBound))
        }

        return TargetGlucose(
            mgDl: overrideMgDl ?? settingsMgDl,
            settingsMgDl: settingsMgDl,
            overridePolicy: override.policyIdentifier,
            overrideMovesTarget: overrideMgDl != nil,
            dosingOverride: dosingOverride
        )
    }

    private static func clampedSettingsTarget(_ settingsTargetMgDl: Double) -> Double {
        return settingsTargetMgDl.clamp(low: LocalTargetGlucoseService.minTargetGlucose, high: LocalTargetGlucoseService.maxTargetGlucose)
    }
}

// MARK: - The policies: the five settings

/// The five settings the Settings automation screen offers, in the order it
/// lists them. Policy only: the mechanism never sees this type.
///
/// Adding a setting is one case here with its arms below (effect, default
/// duration, choices) and in `MainViewTargetOverrideView.swift` (title, banner
/// wording, colour). Nothing changes in the service, the store, the pipeline,
/// the recorded tick or the test mock.
///
/// The raw value is the policy identifier a row is stored under, so it is part
/// of the schema.
public enum TargetOverrideKind: String, Codable, Sendable, CaseIterable {
    case mealSoon
    case digestion
    case exerciseSoon
    case exercise
    case postExercise

    var policyIdentifier: String { return rawValue }

    /// This setting's numbers: what it does when started at this settings
    /// target.
    ///
    /// Meal soon lowers the target ahead of a meal and the two exercise
    /// settings raise it. Digestion and post exercise leave the target alone
    /// and scale dosing. Exercise does both.
    func effect(settingsTargetMgDl: Double) -> OverrideEffect {
        switch self {
        case .mealSoon:
            return OverrideEffect(targetOffsetMgDl: MealSoonPolicy.targetOffset(settingsTargetMgDl: settingsTargetMgDl), dosingMultiplier: nil)
        case .digestion:
            return OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 1.3)
        case .exerciseSoon:
            return OverrideEffect(targetOffsetMgDl: ExercisePolicy.raiseMgDl, dosingMultiplier: nil)
        case .exercise:
            return OverrideEffect(targetOffsetMgDl: ExercisePolicy.raiseMgDl, dosingMultiplier: 0.6)
        case .postExercise:
            return OverrideEffect(targetOffsetMgDl: nil, dosingMultiplier: 0.8)
        }
    }

    /// Whether this setting moves the target, which none of the five decides
    /// by the settings target. These are the settings the glucose chart keeps
    /// a legend entry for.
    var movesTarget: Bool {
        return effect(settingsTargetMgDl: LocalTargetGlucoseService.maxTargetGlucose).targetOffsetMgDl != nil
    }

    /// How long this kind runs when nothing else is picked. Nothing is
    /// remembered between starts: a duration picker shows this whenever its
    /// setting is off.
    var defaultDuration: TimeInterval {
        switch self {
        case .mealSoon: return MealSoonPolicy.duration
        case .digestion: return 2.hoursToSeconds()
        case .exerciseSoon: return 2.hoursToSeconds()
        case .exercise: return 1.hoursToSeconds()
        case .postExercise: return 30.minutesToSeconds()
        }
    }

    /// The durations this kind's picker offers, shortest first. They belong
    /// to the screen: `TargetGlucoseService.start` checks a duration against
    /// `OverrideGuardrails.maxDuration` and nothing else.
    var durations: [TimeInterval] {
        switch self {
        case .mealSoon:
            return [
                30.minutesToSeconds(),
                1.hoursToSeconds(),
                1.5.hoursToSeconds(),
                2.hoursToSeconds()
            ]
        case .digestion, .exercise:
            return [
                30.minutesToSeconds(),
                1.hoursToSeconds(),
                1.5.hoursToSeconds(),
                2.hoursToSeconds(),
                2.5.hoursToSeconds(),
                3.hoursToSeconds()
            ]
        case .exerciseSoon:
            return [
                30.minutesToSeconds(),
                1.hoursToSeconds(),
                1.5.hoursToSeconds(),
                2.hoursToSeconds(),
                3.hoursToSeconds(),
                4.hoursToSeconds()
            ]
        case .postExercise:
            return [
                30.minutesToSeconds(),
                1.hoursToSeconds(),
                1.5.hoursToSeconds()
            ]
        }
    }
}

extension TargetOverride {
    /// The setting this row's policy identifier names, or nil for a source
    /// that is not one of the five or that this build does not know. For the
    /// screens. The mechanism never reads it.
    var kind: TargetOverrideKind? {
        return TargetOverrideKind(rawValue: policyIdentifier)
    }
}

extension TargetGlucoseService {
    /// Start one of the five settings: its effect at the settings target of
    /// this moment, under its own identifier. A source that is not one of the
    /// five calls `start(policyIdentifier:effect:at:duration:settings:)` with
    /// its own identifier and effect.
    func start(_ kind: TargetOverrideKind, at: Date, duration: TimeInterval, settings: CodableSettings) async throws {
        try await start(
            policyIdentifier: kind.policyIdentifier,
            effect: kind.effect(settingsTargetMgDl: settings.targetGlucoseInMgDl),
            at: at,
            duration: duration,
            settings: settings
        )
    }
}

/// The meal-soon numbers (meal-soon §4.1).
enum MealSoonPolicy {
    static let dropMgDl = 15.0
    static let floorMgDl = 75.0
    /// How long meal soon runs unless another duration is picked. The choices
    /// are `TargetOverrideKind.mealSoon.durations`.
    static let duration: TimeInterval = 60.minutesToSeconds()

    /// Meal soon's target for a given settings target, before the [70, 140]
    /// clamp.
    static func target(settingsTargetMgDl: Double) -> Double {
        return max(settingsTargetMgDl - dropMgDl, floorMgDl)
    }

    /// The same rule as the offset meal soon starts with: the clamped target
    /// less the clamped settings target. That is -15 for a settings target of
    /// 90 or more and smaller below it, down to -5 at 80.
    ///
    /// The floor is applied here, once, when meal soon starts. If the
    /// settings target is changed while meal soon is on, the offset carries
    /// over and the floor is not worked out again. Started at 80 and changed
    /// to 120, the target is 115 where this rule gives 105. Started at 90
    /// and changed to 80, the sum is 65 and the guardrail's 70 is the floor,
    /// where this rule gives 75.
    static func targetOffset(settingsTargetMgDl: Double) -> Double {
        let low = LocalTargetGlucoseService.minTargetGlucose
        let high = LocalTargetGlucoseService.maxTargetGlucose
        return target(settingsTargetMgDl: settingsTargetMgDl).clamp(low: low, high: high) - settingsTargetMgDl.clamp(low: low, high: high)
    }
}

/// The target rule exercise soon and exercise share (dev/backlog/exercise.md
/// §2). Their durations differ and are on `TargetOverrideKind`.
enum ExercisePolicy {
    /// The offset both exercise settings start with.
    static let raiseMgDl = 50.0

    /// The target for a given settings target.
    ///
    /// The [70, 140] clamp applies to the settings target *before* the raise
    /// and not after it: clamping afterwards would collapse "+50" into "140"
    /// for any settings target of 90 or more. With the settings picker's
    /// 80...140 range the override lands in 130...190, inside
    /// `OverrideGuardrails.targetRangeMgDl`.
    static func target(settingsTargetMgDl: Double) -> Double {
        let base = settingsTargetMgDl.clamp(low: LocalTargetGlucoseService.minTargetGlucose, high: LocalTargetGlucoseService.maxTargetGlucose)
        return base + raiseMgDl
    }
}
