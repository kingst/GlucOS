//
//  TargetGlucoseService.swift
//  BioKernel
//
//  Created by Sam King on 12/29/24.
//
//  Answers "what target, and why" for the dosing pipeline.
//
//  This used to be a pass-through that existed as the future hook for lowering
//  the target before a meal. The meal-soon override is that hook — see
//  dev/backlog/meal-soon.md — so nothing new is threaded through the pipeline:
//  it still reads the target once per tick, and the PID error, the ML
//  dynamic-ISF scaling and the micro-bolus gate all follow whatever this
//  returns.
//
//  The override is a pure function of a stored row and the clock, evaluated on
//  every call (§3). There is no in-memory state to restore, so nothing can get
//  stuck: if the app dies at minute 30, the first evaluation after minute 60
//  computes "expired" from the row. The end is also derived from the pump's own
//  bolus report rather than signalled by the bolus views (§4.2), so it covers
//  every entry point including ones that do not exist yet.
//

import Foundation

public protocol TargetGlucoseService {
    /// The target the pipeline doses toward at `at`, and where it came from.
    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose

    /// Open a meal-soon override at `at`. Supersedes an open one, which is
    /// closed as `.cancelled` in the same transaction.
    func startMealSoon(at: Date, settings: CodableSettings) async throws

    /// Close the open override, if any, as `.cancelled`.
    func cancelMealSoon(at: Date) async

    /// The live override at `at`, or nil. Reads the store, applies
    /// `MealSoonPolicy.status`, writes the end if it observed one, and publishes
    /// the answer to `AppObservableState.mealSoon`.
    func activeMealSoon(at: Date) async -> TargetOverride?
}

enum TargetGlucoseServiceError: LocalizedError {
    /// The loop record store did not open, so there is nowhere to keep the
    /// override. The pipeline keeps dosing toward the settings target.
    case noRecordStore

    var errorDescription: String? {
        switch self {
        case .noRecordStore: return "the loop record store is unavailable"
        }
    }
}

actor LocalTargetGlucoseService: TargetGlucoseService {
    /// The settings target is clamped to this range, and the override's target
    /// is clamped to it *after* the drop (§4.1). With the settings picker's
    /// 80...140 range the override lands in 75...125.
    static let maxTargetGlucose = 140.0
    static let minTargetGlucose = 70.0

    /// nil when the store could not be opened. Every read then lands on the
    /// settings target, which is the higher one.
    private let recordStore: LoopRecordStore?
    private let insulinStorage: InsulinStorage
    private let observableState: AppObservableState
    private let log = DiagnosticLog(category: "TargetGlucoseService")

    /// No I/O here, for the same watchdog reason `LoopRunner.init` does none.
    /// `observableState.mealSoon` is hydrated lazily by the first
    /// `activeMealSoon` call, which the views make on appear and the loop makes
    /// on its first tick.
    init(recordStore: LoopRecordStore?, insulinStorage: InsulinStorage, observableState: AppObservableState) {
        self.recordStore = recordStore
        self.insulinStorage = insulinStorage
        self.observableState = observableState
    }

    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose {
        let settingsTarget = settings.targetGlucoseInMgDl
        guard await activeMealSoon(at: at) != nil else {
            return TargetGlucose(mgDl: Self.clamp(settingsTarget), source: .settings)
        }
        // Computed from the *current* settings target on every tick, not frozen
        // at start: if the user changes their target mid-override the override
        // follows it.
        return TargetGlucose(mgDl: Self.clamp(MealSoonPolicy.target(settingsTargetMgDl: settingsTarget)), source: .mealSoon)
    }

    func startMealSoon(at: Date, settings: CodableSettings) async throws {
        guard let recordStore else { throw TargetGlucoseServiceError.noRecordStore }
        let override = try await recordStore.startTargetOverride(
            kind: .mealSoon,
            at: at,
            expiresAt: at + MealSoonPolicy.duration,
            settingsTargetMgDl: settings.targetGlucoseInMgDl
        )
        log.default("meal soon started at %{public}@, expires %{public}@", "\(at)", "\(override.expiresAt)")
        await publish(override)
    }

    func cancelMealSoon(at: Date) async {
        guard let recordStore else {
            await publish(nil)
            return
        }
        do {
            if let open = try await recordStore.openTargetOverride() {
                try await recordStore.endTargetOverride(id: open.id, at: at, reason: .cancelled, bolusSyncIdentifier: nil)
                log.default("meal soon cancelled at %{public}@", "\(at)")
            }
        } catch {
            log.error("could not cancel the meal soon override: %{public}@", String(describing: error))
        }
        // Whatever the store says now is what gets published, so a failed
        // cancel leaves the switch on rather than lying about it.
        _ = await activeMealSoon(at: at)
    }

    func activeMealSoon(at: Date) async -> TargetOverride? {
        guard let recordStore else {
            await publish(nil)
            return nil
        }

        let open: TargetOverride?
        do {
            open = try await recordStore.openTargetOverride()
        } catch {
            // Fails toward the settings target, which is the higher one.
            log.error("could not read the open target override; using the settings target: %{public}@", String(describing: error))
            await publish(nil)
            return nil
        }
        guard let open else {
            await publish(nil)
            return nil
        }

        // The pump's own report of what was bolused inside the window. The query
        // tests overlap and filters only on `deleted_at`, so an in-progress
        // bolus is visible the moment the pod acknowledges it; the rule owns the
        // `startDate >= startedAt` test that excludes a bolus which began before
        // the override and is still delivering.
        //
        // A read failure returns `[]`, which would hide a manual bolus and let
        // the override run to expiry. Acceptable: the same failure makes
        // `lastPumpSync` nil, and the loop skips rather than doses.
        let doses = await insulinStorage
            .pumpEvents(from: open.startedAt, to: min(at, open.expiresAt))
            .compactMap { $0.dose }

        switch MealSoonPolicy.status(of: open, at: at, doses: doses) {
        case .active:
            await publish(open)
            return open
        case .ended(let endedAt, let reason, let bolusSyncIdentifier):
            do {
                try await recordStore.endTargetOverride(id: open.id, at: endedAt, reason: reason, bolusSyncIdentifier: bolusSyncIdentifier)
                log.default("meal soon ended at %{public}@: %{public}@", "\(endedAt)", reason.rawValue)
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
        await MainActor.run { [observableState] in observableState.mealSoon = override }
    }
}
