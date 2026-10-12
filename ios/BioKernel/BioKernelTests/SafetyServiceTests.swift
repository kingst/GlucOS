//
//  SafetyServiceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 1/21/24.
//
//  Two halves.
//
//  The first is `SafetyState`'s arithmetic, which is pure and did not change.
//  The second is `LocalSafetyService.tempBasal`, which used to read an in-memory
//  array loaded from `safety_states.json` and now queries the loop record store.
//  Those tests kept their assertions and changed how the ledger gets written:
//  through `LoopRecordStore.record`, alongside the loop result, in one
//  transaction — because `SafetyService.record` no longer exists.
//
//  New at the bottom: the fail-closed tests. They are the ones that matter.
//  `historicalMlInsulin` is *subtracted* from the ML deviation budget, so an
//  empty ledger reads as "no ML insulin has been delivered" and grants the
//  maximum deviation. Any read that cannot be answered must therefore return the
//  reactive-safe temp basal, never an empty tally. That is the subject
//  `SafetyStateCodableTests` was circling when it worried about "the silent
//  failure mode where post-restart decoding falls back to [] and the 3-hour ML
//  budget tally invisibly resets"; it is tested directly here instead of through
//  a JSON shape that is no longer persisted.
//

import Testing
import Foundation
import LoopKit

@testable import BioKernel

struct SafetyServiceTests {

    let insulinAccuracy = 0.0001

    // MARK: - Ledger helpers

    /// A real store over an in-memory database, plus the service reading it.
    ///
    /// `createdAt` is what `safety_history_complete_since` is seeded to, so a
    /// test that wants the completeness guard out of the way puts it well before
    /// the window it queries.
    private func makeLedger(createdAt: Date) throws -> (store: GRDBLoopRecordStore, service: LocalSafetyService) {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: createdAt)
        return (store, LocalSafetyService(recordStore: store))
    }

    /// Writes one tick the way `LoopRunner.loop` does: the loop result and the
    /// ledger entry it earned, together.
    private func record(
        _ store: GRDBLoopRecordStore,
        at: Date,
        decision: DosingDecision,
        candidates: DoseCandidates,
        duration: TimeInterval
    ) async throws {
        let tick = LoopRecordFixtures.dosedWithLedger(
            at: at,
            decision: decision,
            candidates: candidates,
            duration: duration
        )
        try await store.record(tick.record, safetyState: tick.safetyState, at: at)
    }

    // MARK: - SafetyState arithmetic (pure, unchanged)

    @Test func safetyStateBasics() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let safetyState = SafetyState(at: startDate, duration: 30.minutesToSeconds(), kind: .tempBasal(programmed: 1.2, physiological: 1.2))

        // look at a time before our command ran
        let beforeUnits = safetyState.deltaUnitsDeliveredByMachineLearning(from: startDate - 5.minutesToSeconds(), to: startDate)

        #expect(abs(beforeUnits - 0.0) <= insulinAccuracy)

        // the system used the safety temp basal, so ml insulin should be 0
        let unitsFromSafetyTempBasal = safetyState.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 5.minutesToSeconds())

        #expect(abs(unitsFromSafetyTempBasal - 0.0) <= insulinAccuracy)
    }

    @Test func safetyStateCalculation() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let safetyStateEqual = SafetyState(at: startDate, duration: 30.minutesToSeconds(), kind: .tempBasal(programmed: 1.2, physiological: 0))

        let mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 5.minutesToSeconds())
        #expect(abs(mlInsulin - 0.1) <= insulinAccuracy)

        // make sure that it cuts it off at duration
        let mlInsulin2 = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 60.minutesToSeconds())
        #expect(abs(mlInsulin2 - 0.6) <= insulinAccuracy)

        // make sure that we can start in the middle
        let mlInsulin3 = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate + 25.minutesToSeconds(), to: startDate + 60.minutesToSeconds())
        #expect(abs(mlInsulin3 - 0.1) <= insulinAccuracy)
    }

    @Test func safetyStateTempBasal() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let safetyStateEqual = SafetyState(at: startDate, duration: 30.minutesToSeconds(), kind: .tempBasal(programmed: 1.2, physiological: 0))

        var mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate + 30.minutesToSeconds(), to: startDate + 60.minutesToSeconds())
        #expect(abs(mlInsulin - 0.0) <= insulinAccuracy)

        mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate - 30.minutesToSeconds(), to: startDate)
        #expect(abs(mlInsulin - 0.0) <= insulinAccuracy)
    }

    @Test func safetyStateMicroBolus() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let safetyStateEqual = SafetyState(at: startDate, duration: 1.minutesToSeconds(), kind: .microBolus(programmed: 2.0, physiological: 0))

        // checks to make sure that we're accounting for a micro bolus
        var mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 30.minutesToSeconds())
        #expect(abs(mlInsulin - 2.0) <= insulinAccuracy)

        // check before
        mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate - 30.minutesToSeconds(), to: startDate)
        #expect(abs(mlInsulin - 0.0) <= insulinAccuracy)

        // check after
        mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate + 30.minutesToSeconds(), to: startDate + 60.minutesToSeconds())
        #expect(abs(mlInsulin - 0.0) <= insulinAccuracy)
    }

    @Test func suspendedKindAccumulatesNoMlInsulin() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let suspended = SafetyState(at: startDate, duration: 30.minutesToSeconds(), kind: .suspended)
        let mlInsulin = suspended.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 30.minutesToSeconds())
        #expect(abs(mlInsulin - 0.0) <= insulinAccuracy)
    }

    // MARK: - The budget, against a real ledger

    // for this test we will deliver two ML doses that provide an excess of
    // one unit of insulin each. Then on the third the system should instead
    // use the safety insulin value since we've exausted our ML insulin
    @Test func extraInsulinClamp() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let (store, safetyService) = try makeLedger(createdAt: startDate - 24.hoursToSeconds())
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)

        let candidates = DoseCandidates(physiologicalTempBasal: 1.0, mlTempBasal: 3.0, physiologicalMicroBolus: 0, mlMicroBolus: 0)

        // our first dose that will run for 30 minutes
        try await record(store, at: startDate, decision: .tempBasal(unitsPerHour: 3.0), candidates: candidates, duration: 30.minutesToSeconds())

        let firstTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(firstTempBasal.tempBasal - 3.0) <= insulinAccuracy)

        try await record(store, at: startDate + 30.minutesToSeconds(), decision: .tempBasal(unitsPerHour: firstTempBasal.tempBasal), candidates: candidates, duration: 30.minutesToSeconds())

        // at this point we have already delivered 2 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(secondTempBasal.tempBasal - 1.0) <= insulinAccuracy)
    }

    @Test func basalAndBolus() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let (store, safetyService) = try makeLedger(createdAt: startDate - 24.hoursToSeconds())
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)

        let basalCandidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 1.2, physiologicalMicroBolus: 0, mlMicroBolus: 0)
        let bolusCandidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 0, physiologicalMicroBolus: 0, mlMicroBolus: 2.9)

        // our first dose is a temp basal
        try await record(store, at: startDate, decision: .tempBasal(unitsPerHour: 1.2), candidates: basalCandidates, duration: 30.minutesToSeconds())

        // add a micro bolus after 5 minutes
        try await record(store, at: startDate + 5.minutesToSeconds(), decision: .microBolus(units: 2.9), candidates: bolusCandidates, duration: 30.minutesToSeconds())

        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(secondTempBasal.tempBasal - 1.0) <= insulinAccuracy)
    }

    // `SafetyState(at:decision:candidates:duration:)` projects each decision form
    // onto the matching Kind case, dropping the unused form's candidates. This was
    // previously a "zero out unused branch fields" pattern; making Kind enum-shaped
    // removes the hazard structurally — cases that don't apply simply don't exist
    // on this state.
    //
    // It used to be `LocalSafetyService.record`'s first half, which meant testing
    // it required a service, a file, and an accessor onto the service's private
    // array. It is a pure mapping now, so this reads it directly.
    @Test func initProjectsDecisionOntoMatchingKind() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let duration = 30.minutesToSeconds()

        let candidates = DoseCandidates(
            physiologicalTempBasal: 0.95,
            mlTempBasal: 1.3,
            physiologicalMicroBolus: 0.2,
            mlMicroBolus: 0.3
        )

        let states = [
            SafetyState(at: startDate, decision: .tempBasal(unitsPerHour: 1.5), candidates: candidates, duration: duration),
            SafetyState(at: startDate + 5.minutesToSeconds(), decision: .microBolus(units: 0.3), candidates: candidates, duration: duration),
            SafetyState(at: startDate + 10.minutesToSeconds(), decision: .suspendForBiologicalInvariant(mgDlPerHour: -50), candidates: candidates, duration: duration)
        ]

        guard case .tempBasal(let basalProgrammed, let basalPhysiological) = states[0].kind else {
            Issue.record("Expected .tempBasal kind for tempBasal decision; got \(states[0].kind)")
            return
        }
        #expect(basalProgrammed == 1.5)
        #expect(basalPhysiological == 0.95)

        guard case .microBolus(let bolusProgrammed, let bolusPhysiological) = states[1].kind else {
            Issue.record("Expected .microBolus kind for microBolus decision; got \(states[1].kind)")
            return
        }
        #expect(bolusProgrammed == 0.3)
        #expect(bolusPhysiological == 0.2)

        guard case .suspended = states[2].kind else {
            Issue.record("Expected .suspended kind for suspend decision; got \(states[2].kind)")
            return
        }
    }

    @Test func lessInsulinClamp() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let (store, safetyService) = try makeLedger(createdAt: startDate - 24.hoursToSeconds())
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)

        let firstTempBasal = await safetyService.tempBasal(at: startDate, settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 4.0, machineLearningTempBasalUnitsPerHour: 0.0, duration: 30.minutesToSeconds())

        #expect(abs(firstTempBasal.tempBasal - 0.0) <= insulinAccuracy)

        // programmed=0 against physiological=4.0 → -2.0 U delivered (deficit) over 30 min
        let candidates = DoseCandidates(physiologicalTempBasal: 4.0, mlTempBasal: 0.0, physiologicalMicroBolus: 0, mlMicroBolus: 0)
        try await record(store, at: startDate, decision: .tempBasal(unitsPerHour: 0), candidates: candidates, duration: 30.minutesToSeconds())

        // at this point we have a deficit of 2 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 4.0, machineLearningTempBasalUnitsPerHour: 0.0, duration: 30.minutesToSeconds())

        #expect(abs(secondTempBasal.tempBasal - 4.0) <= insulinAccuracy)
    }

    // A `.suspended` tick must contribute 0 to the historical ML insulin tally,
    // even when the candidates passed alongside it are non-trivial. Otherwise a
    // biological-invariant suspension would spuriously fill the budget and clamp
    // legitimate ML deviations on the next tick.
    @Test func suspendedTickContributesZeroToMlBudget() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let (store, safetyService) = try makeLedger(createdAt: startDate - 24.hoursToSeconds())
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)

        // Non-trivial candidates: a buggy `.suspended` path could read these and
        // accumulate phantom delta. Correct behavior ignores them entirely.
        let candidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 3.0, physiologicalMicroBolus: 0, mlMicroBolus: 0.5)

        try await record(store, at: startDate, decision: .suspendForBiologicalInvariant(mgDlPerHour: -50), candidates: candidates, duration: 30.minutesToSeconds())

        // With historicalMlInsulin=0, requesting ml=3.0 vs safety=1.0 over 30 min
        // (delta = 1.0 U) sits well inside the 2.0 U / 3-hour budget — should pass through unchanged.
        let result = await safetyService.tempBasal(at: startDate + 5.minutesToSeconds(), settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(result.tempBasal - 3.0) <= insulinAccuracy)
    }

    // Mirrors `extraInsulinClamp` but isolated to the microBolus path. Two boluses
    // each 1 U over physiological exhaust the 2 U / 3-hour cap; the next ML temp
    // basal request must clamp back to safety.
    @Test func microBolusOnlyExhaustsMlBudgetThenClamps() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let (store, safetyService) = try makeLedger(createdAt: startDate - 24.hoursToSeconds())
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)

        let candidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 0, physiologicalMicroBolus: 0.1, mlMicroBolus: 1.1)

        // Two micro-boluses, each 1.0 U over physiological → 2.0 U total ML credit consumed
        try await record(store, at: startDate, decision: .microBolus(units: 1.1), candidates: candidates, duration: 30.minutesToSeconds())
        try await record(store, at: startDate + 5.minutesToSeconds(), decision: .microBolus(units: 1.1), candidates: candidates, duration: 30.minutesToSeconds())

        // ML wants 3.0, safety wants 1.0. Budget exhausted, so the upper clamp
        // forces deltaUnits → 0 and the result lands at safety.
        let result = await safetyService.tempBasal(at: startDate + 10.minutesToSeconds(), settings: settings.snapshot(), reactiveSafeTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(result.tempBasal - 1.0) <= insulinAccuracy)
    }

    // MARK: - Failing closed
    //
    // Every one of these asks the same question three ways: when the ledger
    // cannot be read, does the service grant the full ML budget (wrong, and the
    // direction the old `(try? storage.read()) ?? []` failed in) or refuse it?
    //
    // The tell is the same in each: ML wants 3.0 U/hr against a reactive-safe
    // 1.0 U/hr. On an empty-but-trusted ledger that deviation is affordable and
    // passes through at 3.0. Refusing the budget pins the answer to 1.0.

    private func mlDeviationRequest(_ safetyService: LocalSafetyService, at: Date, settings: CodableSettings) async -> SafetyTempBasal {
        return await safetyService.tempBasal(
            at: at,
            settings: settings,
            reactiveSafeTempBasalUnitsPerHour: 1.0,
            machineLearningTempBasalUnitsPerHour: 3.0,
            duration: 30.minutesToSeconds()
        )
    }

    @Test func noStoreRefusesTheMlBudget() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let safetyService = LocalSafetyService(recordStore: nil)

        let result = await mlDeviationRequest(safetyService, at: startDate, settings: settings.snapshot())

        #expect(abs(result.tempBasal - 1.0) <= insulinAccuracy, "an unopenable store must not grant ML deviation authority")
        #expect(result.machineLearningInsulinLastThreeHours == 0)
    }

    @Test func aFailedLedgerReadRefusesTheMlBudget() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let safetyService = LocalSafetyService(recordStore: MockLoopRecordStore(failReads: true))

        let result = await mlDeviationRequest(safetyService, at: startDate, settings: settings.snapshot())

        #expect(abs(result.tempBasal - 1.0) <= insulinAccuracy, "a failed ledger read must not read as an empty ledger")
        #expect(result.machineLearningInsulinLastThreeHours == 0)
    }

    // The cutover case, and the permanent one. A store created five minutes ago
    // cannot say what was delivered three hours ago, so it must not imply that
    // nothing was. Also covers a reinstall and a restore from a backup that
    // predates the database.
    @Test func aWindowOlderThanTheStoreRefusesTheMlBudget() async throws {
        let created = Date.f("2018-07-15 03:34:29 +0000")
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let (_, safetyService) = try makeLedger(createdAt: created)

        let result = await mlDeviationRequest(safetyService, at: created + 5.minutesToSeconds(), settings: settings.snapshot())

        #expect(abs(result.tempBasal - 1.0) <= insulinAccuracy, "a window reaching before the store existed must not grant the budget")
        #expect(result.machineLearningInsulinLastThreeHours == 0)
    }

    // ...and it heals on its own. Once the store has existed for the whole window
    // the tally reads, the guard stops firing and never fires again.
    //
    // The window the query actually reads is `[at - timeHorizon - duration, at)`,
    // so the healing point is `timeHorizon + duration` after creation rather than
    // `timeHorizon` — a temp basal that began before the horizon can still have
    // been running inside it, which is why the query reaches back that far.
    @Test func theLedgerHealsOnceItCoversTheWindow() async throws {
        let created = Date.f("2018-07-15 03:34:29 +0000")
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let (_, safetyService) = try makeLedger(createdAt: created)

        let healed = created + LoopRecordStorePolicy.safetyTimeHorizon + 30.minutesToSeconds()

        let justBefore = await mlDeviationRequest(safetyService, at: healed - 1, settings: settings.snapshot())
        #expect(abs(justBefore.tempBasal - 1.0) <= insulinAccuracy, "still incomplete one second early")

        let after = await mlDeviationRequest(safetyService, at: healed, settings: settings.snapshot())
        #expect(abs(after.tempBasal - 3.0) <= insulinAccuracy, "an empty ledger the store can vouch for is a real zero tally")
    }
}
