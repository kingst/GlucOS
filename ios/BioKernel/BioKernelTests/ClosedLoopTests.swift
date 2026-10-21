//
//  ClosedLoopTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/16/23.
//

import Testing
import Foundation
import LoopKit
import OmnipodKit
import MockKit
import HealthKit

@testable import BioKernel

@MainActor
struct ClosedLoopTests {
    let iobAccuracy = 0.00000000001

    @Test func baselineIoB() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let endDate = startDate + 6.hoursToSeconds()
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: endDate, value: 0.4, unit: .unitsPerHour, insulinType: .humalog, isMutable: false)

        let iob = dose.insulinOnBoard(at: endDate)
        // From the Python unit tests
        #expect(abs(iob - 0.8589151141064484) <= iobAccuracy)
    }

    // copied from the OmnipodKit code
    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return OmniPumpManager.onboardingSupportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    @Test func basalRateRounding() throws {
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.31) - 0.3) <= iobAccuracy)
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.3491) - 0.3) <= iobAccuracy)
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.351) - 0.35) <= iobAccuracy)
    }

    // We reimplement OmnipodKit's internal ReservoirLevel.percentage, so pin it to the values that
    // implementation produces. A drift here silently changes what the app reports as remaining.
    @Test func reservoirPercentRemaining() throws {
        let percentRemaining = LocalDeviceDataManager.reservoirPercentRemaining(unitsRemaining:)

        // At or below the 50U threshold the pod reports an exact reading, scaled against 100U.
        #expect(abs(percentRemaining(0) - 0) <= iobAccuracy)
        #expect(abs(percentRemaining(10) - 0.1) <= iobAccuracy)
        #expect(abs(percentRemaining(50) - 0.5) <= iobAccuracy)

        // Above it the pod only reports "more than 50", which counts as full.
        #expect(abs(percentRemaining(50.1) - 1) <= iobAccuracy)
        #expect(abs(percentRemaining(200) - 1) <= iobAccuracy)

        #expect(abs(percentRemaining(-1) - 0) <= iobAccuracy)
    }

    @Test func doseLogic() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        let dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseMachineLearning() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: true, useBiologicalInvariant: false)

        let dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseMachineLearningMicroBolus() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: true, useBiologicalInvariant: false)

        let dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.25) <= iobAccuracy)
    }

    @Test func doseLogicUseMicroBolus() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.2) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.02, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseBiologicalInvariant() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseMicroBolusBiologicalInvariant() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.2) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.2) <= iobAccuracy)
    }

    @Test func doseLogicUseMachineLearningBiologicalInvariant() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: true, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseAll() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: true, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.25) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.25) <= iobAccuracy)
    }

    // MARK: - Meal soon (dev/backlog/meal-soon.md §10)

    /// The override reaches the pipeline through its one target read, so a stub
    /// reporting `.mealSoon` is enough to check the whole path: the PID error
    /// shifts by the drop, the outputs carry the source, and the stored row
    /// carries both columns.
    @Test func aMealSoonTargetShiftsThePidErrorAndIsRecorded() async throws {
        let now = Date.f("2026-10-20 12:00:00 +0000")
        let pumpManager = MockPumpManager()
        let pumpManagerDelegate = MockPumpManagerDelegate()
        pumpManager.pumpManagerDelegate = pumpManagerDelegate
        let deviceManager = MockDeviceDataManager()
        deviceManager.mockPumpManager = pumpManager

        // A fresh runner per source, so each PID starts from the same state and
        // the only difference between the two runs is the target.
        func run(source: TargetGlucoseSource) async throws -> (outputs: PipelineOutputs, recorded: LoopRecordSnapshot) {
            let settings = MockSettingsStorage()
            let glucoseStorage = MockGlucoseStorage()
            let insulinStorage = MockInsulinStorage()
            await glucoseStorage.addGlucoseReading(quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150), date: now)
            insulinStorage.mockLastPumpSync = now
            let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
            let runner = makeClosedLoopService(
                settings: settings,
                glucoseStorage: glucoseStorage,
                insulinStorage: insulinStorage,
                targetGlucoseService: MockTargetGlucose(source: source),
                recordStore: store
            )

            // `runLoop` returns the in-memory result; `loop` is what makes a
            // tick durable.
            let run = await runner.runLoop(at: now, pumpManager: pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())
            let outputs = try #require(run.result.outcome.snapshot?.outputs)
            #expect(await runner.loop(at: now, pumpManager: pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata()))
            let recorded = try #require(try await store.latestRecord()?.outcome.snapshot)
            return (outputs, recorded)
        }

        let settingsRun = try await run(source: .settings)
        let mealSoonRun = try await run(source: .mealSoon)

        #expect(settingsRun.outputs.targetSource == .settings)
        #expect(settingsRun.outputs.targetGlucoseInMgDl == 90)
        #expect(mealSoonRun.outputs.targetSource == .mealSoon)
        #expect(mealSoonRun.outputs.targetGlucoseInMgDl == 75)

        // error = filtered glucose − target, so a lower target is a larger error.
        let shift = mealSoonRun.outputs.pidTempBasalResult.error - settingsRun.outputs.pidTempBasalResult.error
        #expect(abs(shift - MealSoonPolicy.dropMgDl) <= iobAccuracy)

        #expect(settingsRun.recorded.targetGlucoseInMgDl == 90)
        #expect(settingsRun.recorded.targetSource == .settings)
        #expect(mealSoonRun.recorded.targetGlucoseInMgDl == 75)
        #expect(mealSoonRun.recorded.targetSource == .mealSoon)
    }

    @Test func legacyInsulinSensitivityKeyDecodes() async throws {
        // Pre-rename on-disk format used the misspelled key.
        // After the rename, existing files must still decode without resetting user settings.
        let json = """
        {
            "created": "2025-01-01T00:00:00Z",
            "pumpBasalRateUnitsPerHour": 0.3,
            "insulinSensitivityInMgDlPerUnit": 45,
            "maxBasalRateUnitsPerHour": 2,
            "maxBolusUnits": 5,
            "shutOffGlucoseInMgDl": 85,
            "targetGlucoseInMgDl": 90,
            "freshnessIntervalInSeconds": 600,
            "correctionDurationInSeconds": 1800,
            "closedLoopEnabled": true,
            "useMachineLearningClosedLoop": false,
            "learnedBasalRatesUnitsPerHour": {},
            "learnedInsulinSensivityInMgDlPerUnit": { "midnightToFour": 42 }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(CodableSettings.self, from: json)

        // The legacy schedule should land on the renamed property.
        #expect(settings.learnedInsulinSensitivityInMgDlPerUnit.midnightToFour == 42)
    }
}
