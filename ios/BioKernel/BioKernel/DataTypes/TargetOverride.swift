//
//  TargetOverride.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//
//  Timed target overrides: the domain value for one `target_override` row, the
//  answer `TargetGlucoseService` gives the pipeline, and the pure rules that
//  decide what an override's target is and whether it is still in effect.
//
//  Two kinds so far. "Meal soon" lowers the target ahead of a meal
//  (dev/backlog/meal-soon.md); "exercise" raises it for a workout
//  (dev/backlog/exercise.md). Only one can be open at a time: starting either
//  closes whatever is open, so the later setting wins.
//
//  Nothing here does I/O. `TargetOverridePolicy.status` is a function of a
//  stored row, the clock, and the doses the pump reported — so if the app dies
//  at minute 30, the first evaluation after expiry computes "expired" from the
//  row, and nothing can get stuck because there is no state to restore
//  (meal-soon §3).
//

import Foundation
import LoopKit

// MARK: - What the pipeline reads

/// Where a tick's target came from. Recorded on every `loop_result` row
/// (meal-soon §6), so "the 12:10 tick dosed toward 75 with source `mealSoon`"
/// is a fact in the store rather than a claim reconstructed from the override
/// table.
public enum TargetGlucoseSource: String, Codable, Sendable {
    case settings
    case mealSoon
    case exercise

    /// The override this source came from, or nil for the settings target.
    var overrideKind: TargetOverrideKind? {
        switch self {
        case .settings: return nil
        case .mealSoon: return .mealSoon
        case .exercise: return .exercise
        }
    }
}

/// The target the pipeline doses toward, and why.
public struct TargetGlucose: Codable, Equatable, Sendable {
    let mgDl: Double
    let source: TargetGlucoseSource
}

// MARK: - The override row

public enum TargetOverrideKind: String, Codable, Sendable {
    case mealSoon
    case exercise

    /// Whether a manual bolus inside the window ends the override. Meal soon is
    /// over once the meal is bolused; a snack bolus during a long workout should
    /// not drop the raised target (exercise, decision 4).
    var endsOnManualBolus: Bool {
        switch self {
        case .mealSoon: return true
        case .exercise: return false
        }
    }
}

public enum TargetOverrideEndReason: String, Codable, Sendable {
    case expired
    case manualBolus
    case cancelled
}

/// One `target_override` row, as a domain value.
///
/// A row that is open (`endedAt == nil`) *is* the live state; a row that is
/// closed is the log entry. There is no separate state file (meal-soon §5.1).
public struct TargetOverride: Equatable, Sendable {
    let id: Int64
    let kind: TargetOverrideKind
    let startedAt: Date
    /// Stored rather than derived from `startedAt`, so the duration is a fact of
    /// the row and not of whichever build reads it.
    let expiresAt: Date
    /// The user's settings target when the override began. A record, not the
    /// value in use: the override tracks the *current* settings target on every
    /// tick (meal-soon §4.1).
    let settingsTargetMgDl: Double
    let endedAt: Date?
    let endReason: TargetOverrideEndReason?
    /// Non-nil iff `endReason == .manualBolus`: the dose that ended it.
    let endBolusSyncIdentifier: String?

    /// Open and not yet past its expiry at `at`. The view's own test, so the
    /// banner clears on the clock without waiting for a loop tick (meal-soon
    /// §7.2).
    func isActive(at: Date) -> Bool {
        return endedAt == nil && at < expiresAt
    }

    /// `expiresAt - startedAt`, to the second. Rounded because both ends went
    /// through the store as epoch-second doubles, and the exercise duration
    /// picker compares this against its fixed choices.
    var duration: TimeInterval {
        return expiresAt.timeIntervalSince(startedAt).rounded()
    }
}

/// What `TargetOverridePolicy.status` concludes about an override at an instant.
public enum TargetOverrideStatus: Equatable {
    case active
    case ended(at: Date, reason: TargetOverrideEndReason, bolusSyncIdentifier: String?)
}

// MARK: - The rules

/// Whether an override of either kind is still in effect (meal-soon §4.1).
enum TargetOverridePolicy {
    /// What `override` is at `at`, given the doses the pump reported that
    /// overlap `[startedAt, min(at, expiresAt))`.
    ///
    /// Checked in this order:
    ///
    /// 1. A row with `endedAt` set is ended, with its stored reason. Cancelling
    ///    from the UI closes the row directly, so this is how the rule sees a
    ///    cancel.
    /// 2. For a kind that `endsOnManualBolus`, the **earliest** manual bolus
    ///    that started inside the window ends it at that bolus's `startDate`.
    ///    Earliest, so the logged end is when the override actually stopped
    ///    applying, not when we noticed. Exercise skips this step: `doses` is
    ///    ignored for it.
    /// 3. `at >= expiresAt` ends it at `expiresAt`.
    /// 4. Otherwise it is active.
    ///
    /// Two details the rule owns because the store's window query does not
    /// (meal-soon §4.2): the query tests *overlap*, so a bolus that began before
    /// `startedAt` and is still delivering comes back — the `startDate >=
    /// startedAt` test here is what excludes it. And a bolus whose `automatic`
    /// is nil counts as manual: ending early means a higher target and less
    /// insulin, which is the safe side of an unknown.
    static func status(of override: TargetOverride, at: Date, doses: [DoseEntry]) -> TargetOverrideStatus {
        if let endedAt = override.endedAt, let reason = override.endReason {
            return .ended(at: endedAt, reason: reason, bolusSyncIdentifier: override.endBolusSyncIdentifier)
        }

        if override.kind.endsOnManualBolus {
            let windowEnd = min(at, override.expiresAt)
            let manualBolus = doses
                .filter { $0.type == .bolus && $0.automatic != true }
                .filter { $0.startDate >= override.startedAt && $0.startDate < windowEnd }
                .min { $0.startDate < $1.startDate }
            if let manualBolus {
                return .ended(at: manualBolus.startDate, reason: .manualBolus, bolusSyncIdentifier: manualBolus.syncIdentifier)
            }
        }

        if at >= override.expiresAt {
            return .ended(at: override.expiresAt, reason: .expired, bolusSyncIdentifier: nil)
        }

        return .active
    }
}

/// The meal-soon numbers (meal-soon §4.1).
enum MealSoonPolicy {
    static let dropMgDl = 15.0
    static let floorMgDl = 75.0
    static let duration: TimeInterval = 60.minutesToSeconds()

    /// The override's target for a given settings target. The service's [70, 140]
    /// clamp applies *after* this and stays the last word.
    static func target(settingsTargetMgDl: Double) -> Double {
        return max(settingsTargetMgDl - dropMgDl, floorMgDl)
    }
}

/// The exercise numbers (dev/backlog/exercise.md §2).
enum ExercisePolicy {
    static let raiseMgDl = 50.0
    static let defaultDuration: TimeInterval = 2.hoursToSeconds()
    /// What the duration picker offers. Nothing is remembered between starts:
    /// the picker shows `defaultDuration` every time exercise is off.
    static let durations: [TimeInterval] = [
        30.minutesToSeconds(),
        1.hoursToSeconds(),
        1.5.hoursToSeconds(),
        2.hoursToSeconds(),
        3.hoursToSeconds(),
        4.hoursToSeconds()
    ]

    /// The override's target for a given settings target.
    ///
    /// Unlike meal soon, the service's [70, 140] clamp applies to the settings
    /// target *before* the raise and not after it: clamping afterwards would
    /// collapse "+50" into "140" for any settings target of 90 or more. With the
    /// settings picker's 80...140 range the override lands in 130...190. The
    /// service does not clamp this again.
    static func target(settingsTargetMgDl: Double) -> Double {
        let base = settingsTargetMgDl.clamp(low: LocalTargetGlucoseService.minTargetGlucose, high: LocalTargetGlucoseService.maxTargetGlucose)
        return base + raiseMgDl
    }
}
