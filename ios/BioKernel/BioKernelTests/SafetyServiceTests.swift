//
//  SafetyServiceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 1/21/24.
//

import Testing
import Foundation
import LoopKit

@testable import BioKernel

// tempBasal tests still needed
//  - historical ml is out of range but clamping stays in range (maybe put in separate function to simplify testing?)
struct SafetyServiceTests {

    let insulinAccuracy = 0.0001

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

    // for this test we will deliver two ML doses that provide an excess of
    // one unit of insulin each. Then on the third the system should instead
    // use the safety insulin value since we've exausted our ML insulin
    @Test func extraInsulinClamp() async {
        let safetyService = LocalSafetyService(storedObjectFactory: MockStoredObject.self)
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        let candidates = DoseCandidates(physiologicalTempBasal: 1.0, mlTempBasal: 3.0, physiologicalMicroBolus: 0, mlMicroBolus: 0)

        // our first dose that will run for 30 minutes
        await safetyService.record(at: startDate, decision: .tempBasal(unitsPerHour: 3.0), candidates: candidates, duration: 30.minutesToSeconds())

        let firstTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(firstTempBasal.tempBasal - 3.0) <= insulinAccuracy)

        await safetyService.record(at: startDate + 30.minutesToSeconds(), decision: .tempBasal(unitsPerHour: firstTempBasal.tempBasal), candidates: candidates, duration: 30.minutesToSeconds())

        // at this point we have already delivered 2 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(secondTempBasal.tempBasal - 1.0) <= insulinAccuracy)
    }

    @Test func basalAndBolus() async throws {
        let safetyService = LocalSafetyService(storedObjectFactory: MockStoredObject.self)
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        let basalCandidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 1.2, physiologicalMicroBolus: 0, mlMicroBolus: 0)
        let bolusCandidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 0, physiologicalMicroBolus: 0, mlMicroBolus: 2.9)

        // our first dose is a temp basal
        await safetyService.record(at: startDate, decision: .tempBasal(unitsPerHour: 1.2), candidates: basalCandidates, duration: 30.minutesToSeconds())

        // add a micro bolus after 5 minutes
        await safetyService.record(at: startDate + 5.minutesToSeconds(), decision: .microBolus(units: 2.9), candidates: bolusCandidates, duration: 30.minutesToSeconds())

        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(secondTempBasal.tempBasal - 1.0) <= insulinAccuracy)
    }

    // `record(decision:candidates:...)` projects each decision form onto the matching
    // SafetyState.Kind case, dropping the unused form's candidates. This was previously
    // a "zero out unused branch fields" pattern; making Kind enum-shaped removes the
    // hazard structurally — cases that don't apply simply don't exist on this state.
    @Test func recordProjectsDecisionOntoMatchingKind() async throws {
        let safetyService = LocalSafetyService(storedObjectFactory: MockStoredObject.self)
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let duration = 30.minutesToSeconds()

        let candidates = DoseCandidates(
            physiologicalTempBasal: 0.95,
            mlTempBasal: 1.3,
            physiologicalMicroBolus: 0.2,
            mlMicroBolus: 0.3
        )

        await safetyService.record(at: startDate, decision: .tempBasal(unitsPerHour: 1.5), candidates: candidates, duration: duration)
        await safetyService.record(at: startDate + 5.minutesToSeconds(), decision: .microBolus(units: 0.3), candidates: candidates, duration: duration)
        await safetyService.record(at: startDate + 10.minutesToSeconds(), decision: .suspendForBiologicalInvariant(mgDlPerHour: -50), candidates: candidates, duration: duration)

        let states = await safetyService.safetyStates
        #expect(states.count == 3)

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

    @Test func lessInsulinClamp() async {
        let safetyService = LocalSafetyService(storedObjectFactory: MockStoredObject.self)
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        let firstTempBasal = await safetyService.tempBasal(at: startDate, settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 4.0, machineLearningTempBasalUnitsPerHour: 0.0, duration: 30.minutesToSeconds())

        #expect(abs(firstTempBasal.tempBasal - 0.0) <= insulinAccuracy)

        // programmed=0 against physiological=4.0 → -2.0 U delivered (deficit) over 30 min
        let candidates = DoseCandidates(physiologicalTempBasal: 4.0, mlTempBasal: 0.0, physiologicalMicroBolus: 0, mlMicroBolus: 0)
        await safetyService.record(at: startDate, decision: .tempBasal(unitsPerHour: 0), candidates: candidates, duration: 30.minutesToSeconds())

        // at this point we have a deficit of 2 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 4.0, machineLearningTempBasalUnitsPerHour: 0.0, duration: 30.minutesToSeconds())

        #expect(abs(secondTempBasal.tempBasal - 4.0) <= insulinAccuracy)
    }

    // A `.suspended` tick must contribute 0 to the historical ML insulin tally,
    // even when the candidates passed alongside it are non-trivial. Otherwise a
    // biological-invariant suspension would spuriously fill the budget and clamp
    // legitimate ML deviations on the next tick.
    @Test func suspendedTickContributesZeroToMlBudget() async {
        let safetyService = LocalSafetyService(storedObjectFactory: MockStoredObject.self)
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        // Non-trivial candidates: a buggy `.suspended` path could read these and
        // accumulate phantom delta. Correct behavior ignores them entirely.
        let candidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 3.0, physiologicalMicroBolus: 0, mlMicroBolus: 0.5)

        await safetyService.record(at: startDate, decision: .suspendForBiologicalInvariant(mgDlPerHour: -50), candidates: candidates, duration: 30.minutesToSeconds())

        // With historicalMlInsulin=0, requesting ml=3.0 vs safety=1.0 over 30 min
        // (delta = 1.0 U) sits well inside the 2.0 U / 3-hour budget — should pass through unchanged.
        let result = await safetyService.tempBasal(at: startDate + 5.minutesToSeconds(), settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(result.tempBasal - 3.0) <= insulinAccuracy)
    }

    // Mirrors `extraInsulinClamp` but isolated to the microBolus path. Two boluses
    // each 1 U over physiological exhaust the 2 U / 3-hour cap; the next ML temp
    // basal request must clamp back to safety.
    @Test func microBolusOnlyExhaustsMlBudgetThenClamps() async {
        let safetyService = LocalSafetyService(storedObjectFactory: MockStoredObject.self)
        let settings = await MockSettingsStorage()
        await settings.update(pumpBasalRateUnitsPerHour: 2.0 / 3)
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        let candidates = DoseCandidates(physiologicalTempBasal: 0, mlTempBasal: 0, physiologicalMicroBolus: 0.1, mlMicroBolus: 1.1)

        // Two micro-boluses, each 1.0 U over physiological → 2.0 U total ML credit consumed
        await safetyService.record(at: startDate, decision: .microBolus(units: 1.1), candidates: candidates, duration: 30.minutesToSeconds())
        await safetyService.record(at: startDate + 5.minutesToSeconds(), decision: .microBolus(units: 1.1), candidates: candidates, duration: 30.minutesToSeconds())

        // ML wants 3.0, safety wants 1.0. Budget exhausted, so the upper clamp
        // forces deltaUnits → 0 and the result lands at safety.
        let result = await safetyService.tempBasal(at: startDate + 10.minutesToSeconds(), settings: settings.snapshot(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())

        #expect(abs(result.tempBasal - 1.0) <= insulinAccuracy)
    }
}
