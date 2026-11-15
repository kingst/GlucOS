//
//  TargetGlucoseService.swift
//  BioKernel
//
//  Created by Sam King on 12/29/24.
//
//  The override manager: answers "what target, and why" for the dosing
//  pipeline, and whether a dosing override is on.
//
//  This is the mechanism half of dev/backlog/override-mechanism.md. It holds
//  at most one open override, which is a row in the loop record store: an
//  effect (a target offset, a dosing multiplier, or both) and an expiry. It
//  checks the effect against `OverrideGuardrails` when the override starts,
//  clamps to them again on every tick, ends the override on the clock, and
//  does nothing else on its own. It knows no setting by name. Meal soon,
//  exercise and the rest are policies (`TargetOverrideKind`) that decide an
//  effect and a duration and call `start` and `cancelOverride`, and anything
//  that ends an override early or chains into another belongs to a policy.
//
//  The pipeline asks once per tick: the PID error, the ML dynamic-ISF scaling
//  and the micro-bolus gate all follow the target this returns, and the PID
//  doses with the basal rate and insulin sensitivity the dosing override
//  scales. Both come from the one read of the open row, so a tick never pairs
//  one override's target with another's multiplier.
//
//  An override is a pure function of a stored row and the clock, evaluated on
//  every call (meal-soon §3). There is no in-memory state to restore, so nothing
//  can get stuck: if the app dies at minute 30, the first evaluation after
//  expiry computes "expired" from the row.
//
//  Starting an override closes whatever is open as `.cancelled`, so the later
//  one wins. Nothing chains: every start is a call to `start`.
//

import Foundation

public protocol TargetGlucoseService {
    /// What the pipeline doses with at `at`: the target, and the dosing
    /// override if one is on, both inside `OverrideGuardrails`. No store, a
    /// failing read, no open row, or an open row that is not in effect at
    /// `at` all give the settings target and no dosing override.
    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose

    /// Open an override with `effect` at `at` that expires at `at + duration`.
    /// Throws an `OverrideGuardrailViolation` and writes nothing when the
    /// effect or the duration is outside `OverrideGuardrails`.
    ///
    /// `policyIdentifier` says who started it. It is stored, published and
    /// recorded on each tick, and nothing here acts on it.
    ///
    /// Supersedes an open override from any policy, which is closed as
    /// `.cancelled` in the same transaction. That is also how a duration is
    /// changed mid-run: a fresh row from now with the new duration.
    func start(policyIdentifier: String, effect: OverrideEffect, at: Date, duration: TimeInterval, settings: CodableSettings) async throws

    /// Close the open override, if any, as `.cancelled`. Throws when the
    /// store could not do it. Either way what the store says afterwards is
    /// published, so after a failed cancel the override still shows as on.
    func cancelOverride(at: Date) async throws

    /// The override in effect at `at`, or nil. Reads the store, applies
    /// `OverrideGuardrails.status`, writes the end if the clock has ended it,
    /// and publishes the answer to `AppObservableState.targetOverride`.
    ///
    /// An open row that has not started at `at` is nil here, and nothing is
    /// written or published for it.
    func activeOverride(at: Date) async -> TargetOverride?
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
    /// The settings target is clamped to this range before an override's
    /// offset is added. The sum is then clamped to
    /// `OverrideGuardrails.targetRangeMgDl`, which is wider: with the
    /// settings picker's 80...140 range meal soon lands in 75...125 and the
    /// exercise settings in 130...190.
    static let maxTargetGlucose = 140.0
    static let minTargetGlucose = 70.0

    /// nil when the store could not be opened. Every read then lands on the
    /// settings target.
    private let recordStore: LoopRecordStore?
    private let observableState: AppObservableState
    private let log = DiagnosticLog(category: "TargetGlucoseService")

    /// Counts starts and cancels: once when one begins and once when its
    /// write has returned.
    ///
    /// This actor is re-entrant, so while an evaluation is suspended on the
    /// store a `start` or a `cancelOverride` can run to completion and
    /// publish. The row the evaluation read is then out of date, and
    /// publishing it, or the nil that follows from ending it, would leave the
    /// screens showing something the store does not hold. An evaluation that
    /// finds this changed after a suspension discards what it read and starts
    /// over.
    private var changeCount = 0

    /// No I/O here, for the same watchdog reason `LoopRunner.init` does none.
    /// `observableState.targetOverride` is hydrated lazily by the first
    /// `activeOverride` call, which the views make on appear and the loop makes
    /// on its first tick.
    init(recordStore: LoopRecordStore?, observableState: AppObservableState) {
        self.recordStore = recordStore
        self.observableState = observableState
    }

    func targetGlucose(at: Date, settings: CodableSettings) async -> TargetGlucose {
        // The one read of the open row. The target and the dosing override
        // both come from it, through the one rule that can build the answer.
        let open = await activeOverride(at: at)
        return OverrideGuardrails.resolve(override: open, at: at, settingsTargetMgDl: settings.targetGlucoseInMgDl)
    }

    func start(policyIdentifier: String, effect: OverrideEffect, at: Date, duration: TimeInterval, settings: CodableSettings) async throws {
        if let violation = OverrideGuardrails.violation(of: effect, duration: duration, settingsTargetMgDl: settings.targetGlucoseInMgDl) {
            log.error("refused to start %{public}@: %{public}@", policyIdentifier, String(describing: violation))
            throw violation
        }
        guard let recordStore else { throw TargetGlucoseServiceError.noRecordStore }

        changeCount += 1
        let override: TargetOverride
        do {
            override = try await recordStore.startTargetOverride(
                policyIdentifier: policyIdentifier,
                effect: effect,
                at: at,
                expiresAt: at + duration,
                settingsTargetMgDl: settings.targetGlucoseInMgDl
            )
        } catch {
            changeCount += 1
            throw error
        }
        changeCount += 1
        log.default("%{public}@ started at %{public}@, expires %{public}@", policyIdentifier, "\(at)", "\(override.expiresAt)")
        await publish(override)
    }

    func cancelOverride(at: Date) async throws {
        guard let recordStore else {
            await publish(nil)
            return
        }

        changeCount += 1
        var failure: Error? = nil
        do {
            if let open = try await recordStore.openTargetOverride() {
                try await recordStore.endTargetOverride(id: open.id, at: at, reason: .cancelled)
                log.default("%{public}@ cancelled at %{public}@", open.policyIdentifier, "\(at)")
            }
        } catch {
            log.error("could not cancel the target override: %{public}@", String(describing: error))
            failure = error
        }
        changeCount += 1

        // Whatever the store says now is what gets published, so a failed
        // cancel leaves the switch on rather than lying about it.
        _ = await activeOverride(at: at)
        if let failure { throw failure }
    }

    func activeOverride(at: Date) async -> TargetOverride? {
        guard let recordStore else {
            await publish(nil)
            return nil
        }

        // Each pass reads the open row and acts on it. A pass that finds a
        // start or a cancel landed while it was suspended is holding a row
        // that may have been superseded, so it stops there, with nothing
        // published, and the next pass reads again.
        while true {
            let changeCountAtRead = changeCount

            let open: TargetOverride?
            do {
                open = try await recordStore.openTargetOverride()
            } catch {
                guard changeCount == changeCountAtRead else { continue }
                // Fails toward the settings target and no dosing override.
                log.error("could not read the open target override; using the settings target: %{public}@", String(describing: error))
                await publish(nil)
                return nil
            }
            guard changeCount == changeCountAtRead else { continue }

            guard let open else {
                await publish(nil)
                return nil
            }

            switch OverrideGuardrails.status(of: open, at: at) {
            case .active:
                await publish(open)
                return open
            case .notStarted:
                // `at` is before the row began: a loop whose tick time was
                // fixed before the tap, or a clock that was set back. The
                // override is not in effect at `at` and it is not over, so
                // nothing is written and nothing is published.
                return nil
            case .ended(let endedAt, let reason):
                do {
                    try await recordStore.endTargetOverride(id: open.id, at: endedAt, reason: reason)
                    log.default("%{public}@ ended at %{public}@: %{public}@", open.policyIdentifier, "\(endedAt)", reason.rawValue)
                } catch {
                    // Log-only. The rule still evaluates to ended on the next
                    // call from the row and the clock, so nothing else
                    // depends on this write landing.
                    log.error("could not record the end of a target override: %{public}@", String(describing: error))
                }
                guard changeCount == changeCountAtRead else { continue }
                await publish(nil)
                return nil
            }
        }
    }

    private func publish(_ override: TargetOverride?) async {
        await MainActor.run { [observableState] in observableState.targetOverride = override }
    }
}
