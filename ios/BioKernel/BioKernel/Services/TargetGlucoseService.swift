//
//  TargetGlucoseService.swift
//  BioKernel
//
//  Created by Sam King on 12/29/24.
//
//  Answers "what target, and why" for the dosing pipeline.
//
//  This used to be a pass-through that existed as the future hook for lowering
//  the target before a meal. The timed overrides — meal soon
//  (dev/backlog/meal-soon.md) and exercise (dev/backlog/exercise.md) — are that
//  hook, so nothing new is threaded through the pipeline: it still reads the
//  target once per tick, and the PID error, the ML dynamic-ISF scaling and the
//  micro-bolus gate all follow whatever this returns.
//
//  An override is a pure function of a stored row and the clock, evaluated on
//  every call (meal-soon §3). There is no in-memory state to restore, so nothing
//  can get stuck: if the app dies at minute 30, the first evaluation after
//  expiry computes "expired" from the row. Meal soon also ends on the pump's own
//  bolus report rather than a signal from the bolus views (meal-soon §4.2), so
//  it covers every entry point including ones that do not exist yet.
//
//  At most one override is open at a time. Starting either kind closes whatever
//  is open as `.cancelled`, so the later setting wins.
//

import Foundation
import LoopKit

public protocol TargetGlucoseService {
    /// The target the pipeline doses toward at `at`, and where it came from.
    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose

    /// Open a meal-soon override at `at`. Supersedes an open override of either
    /// kind, which is closed as `.cancelled` in the same transaction.
    func startMealSoon(at: Date, settings: CodableSettings) async throws

    /// Open an exercise override at `at` that expires at `at + duration`.
    /// Supersedes an open override of either kind, which is closed as
    /// `.cancelled` in the same transaction. That is also how the duration is
    /// changed mid-run: a fresh row from now with the new duration.
    func startExercise(at: Date, duration: TimeInterval, settings: CodableSettings) async throws

    /// Close the open override, if any, as `.cancelled`.
    func cancelOverride(at: Date) async

    /// The live override at `at`, or nil. Reads the store, applies
    /// `TargetOverridePolicy.status`, writes the end if it observed one, and
    /// publishes the answer to `AppObservableState.targetOverride`.
    func activeOverride(at: Date) async -> TargetOverride?
}

enum TargetGlucoseServiceError: LocalizedError {
    /// The loop record store did not open, so there is nowhere to keep the
    /// override. The pipeline keeps dosing toward the settings target.
    case noRecordStore
    /// A zero or negative exercise duration would open a row that is already
    /// expired. The UI only offers fixed positive choices; this is the guard
    /// for every other caller.
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .noRecordStore: return "the loop record store is unavailable"
        case .invalidDuration: return "the duration must be longer than zero"
        }
    }
}

actor LocalTargetGlucoseService: TargetGlucoseService {
    /// The settings target is clamped to this range. Meal soon's target is
    /// clamped to it *after* the drop (meal-soon §4.1), so it lands in 75...125
    /// for the settings picker's 80...140 range; exercise clamps the settings
    /// target *before* the raise (`ExercisePolicy.target`) and is not clamped
    /// again, so it lands in 130...190.
    static let maxTargetGlucose = 140.0
    static let minTargetGlucose = 70.0

    /// nil when the store could not be opened. Every read then lands on the
    /// settings target.
    private let recordStore: LoopRecordStore?
    private let insulinStorage: InsulinStorage
    private let observableState: AppObservableState
    private let log = DiagnosticLog(category: "TargetGlucoseService")

    /// No I/O here, for the same watchdog reason `LoopRunner.init` does none.
    /// `observableState.targetOverride` is hydrated lazily by the first
    /// `activeOverride` call, which the views make on appear and the loop makes
    /// on its first tick.
    init(recordStore: LoopRecordStore?, insulinStorage: InsulinStorage, observableState: AppObservableState) {
        self.recordStore = recordStore
        self.insulinStorage = insulinStorage
        self.observableState = observableState
    }

    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose {
        let settingsTarget = settings.targetGlucoseInMgDl
        guard let open = await activeOverride(at: at) else {
            return TargetGlucose(mgDl: Self.clamp(settingsTarget), source: .settings)
        }
        // Computed from the *current* settings target on every tick, not frozen
        // at start: if the user changes their target mid-override the override
        // follows it.
        switch open.kind {
        case .mealSoon:
            return TargetGlucose(mgDl: Self.clamp(MealSoonPolicy.target(settingsTargetMgDl: settingsTarget)), source: .mealSoon)
        case .exercise:
            // `ExercisePolicy.target` clamps the settings target itself, before
            // the raise. Clamping again here would cap it at 140.
            return TargetGlucose(mgDl: ExercisePolicy.target(settingsTargetMgDl: settingsTarget), source: .exercise)
        }
    }

    func startMealSoon(at: Date, settings: CodableSettings) async throws {
        try await start(kind: .mealSoon, at: at, expiresAt: at + MealSoonPolicy.duration, settings: settings)
    }

    func startExercise(at: Date, duration: TimeInterval, settings: CodableSettings) async throws {
        guard duration > 0 else { throw TargetGlucoseServiceError.invalidDuration }
        try await start(kind: .exercise, at: at, expiresAt: at + duration, settings: settings)
    }

    private func start(kind: TargetOverrideKind, at: Date, expiresAt: Date, settings: CodableSettings) async throws {
        guard let recordStore else { throw TargetGlucoseServiceError.noRecordStore }
        let override = try await recordStore.startTargetOverride(
            kind: kind,
            at: at,
            expiresAt: expiresAt,
            settingsTargetMgDl: settings.targetGlucoseInMgDl
        )
        log.default("%{public}@ started at %{public}@, expires %{public}@", kind.rawValue, "\(at)", "\(override.expiresAt)")
        await publish(override)
    }

    func cancelOverride(at: Date) async {
        guard let recordStore else {
            await publish(nil)
            return
        }
        do {
            if let open = try await recordStore.openTargetOverride() {
                try await recordStore.endTargetOverride(id: open.id, at: at, reason: .cancelled, bolusSyncIdentifier: nil)
                log.default("%{public}@ cancelled at %{public}@", open.kind.rawValue, "\(at)")
            }
        } catch {
            log.error("could not cancel the target override: %{public}@", String(describing: error))
        }
        // Whatever the store says now is what gets published, so a failed
        // cancel leaves the switch on rather than lying about it.
        _ = await activeOverride(at: at)
    }

    func activeOverride(at: Date) async -> TargetOverride? {
        guard let recordStore else {
            await publish(nil)
            return nil
        }

        let open: TargetOverride?
        do {
            open = try await recordStore.openTargetOverride()
        } catch {
            // Fails toward the settings target.
            log.error("could not read the open target override; using the settings target: %{public}@", String(describing: error))
            await publish(nil)
            return nil
        }
        guard let open else {
            await publish(nil)
            return nil
        }

        let doses: [DoseEntry]
        if open.kind.endsOnManualBolus {
            // The pump's own report of what was bolused inside the window. The
            // query tests overlap and filters only on `deleted_at`, so an
            // in-progress bolus is visible the moment the pod acknowledges it;
            // the rule owns the `startDate >= startedAt` test that excludes a
            // bolus which began before the override and is still delivering.
            //
            // A read failure returns `[]`, which would hide a manual bolus and
            // let the override run to expiry. Acceptable: the same failure
            // makes `lastPumpSync` nil, and the loop skips rather than doses.
            doses = await insulinStorage
                .pumpEvents(from: open.startedAt, to: min(at, open.expiresAt))
                .compactMap { $0.dose }
        } else {
            // Exercise ends only on the clock or a cancel, so there is nothing
            // to ask the pump about.
            doses = []
        }

        switch TargetOverridePolicy.status(of: open, at: at, doses: doses) {
        case .active:
            await publish(open)
            return open
        case .ended(let endedAt, let reason, let bolusSyncIdentifier):
            do {
                try await recordStore.endTargetOverride(id: open.id, at: endedAt, reason: reason, bolusSyncIdentifier: bolusSyncIdentifier)
                log.default("%{public}@ ended at %{public}@: %{public}@", open.kind.rawValue, "\(endedAt)", reason.rawValue)
            } catch {
                // Log-only. The rule still evaluates to ended on the next call
                // from `started_at` and the pump events, so nothing else depends
                // on this write landing.
                log.error("could not record the end of a target override: %{public}@", String(describing: error))
            }
            await publish(nil)
            return nil
        }
    }

    private static func clamp(_ mgDl: Double) -> Double {
        return mgDl.clamp(low: minTargetGlucose, high: maxTargetGlucose)
    }

    private func publish(_ override: TargetOverride?) async {
        await MainActor.run { [observableState] in observableState.targetOverride = override }
    }
}
