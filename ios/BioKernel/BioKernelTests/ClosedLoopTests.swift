//
//  ClosedLoopTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/16/23.
//

import Testing
import Foundation
import LoopKit
import OmniBLE

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

    // copied from the OmniBLE code
    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return OmniBLEPumpManager.onboardingSupportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    @Test func basalRateRounding() throws {
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.31) - 0.3) <= iobAccuracy)
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.3491) - 0.3) <= iobAccuracy)
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.351) - 0.35) <= iobAccuracy)
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
