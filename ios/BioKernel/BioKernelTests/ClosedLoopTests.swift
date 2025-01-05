//
//  ClosedLoopTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/16/23.
//

import XCTest
import LoopKit
import OmniBLE

@testable import BioKernel

final class ClosedLoopTests: XCTestCase {
    let iobAccuracy = 0.00000000001
    
    @MainActor override func setUpWithError() throws {
        Dependency.useMockConstructors = true
        Dependency.mock { MockInsulinStorage() as InsulinStorage }
        Dependency.mock { MockReplayLogger() as EventLogger}
        Dependency.mock { MockWatchComms() as WatchComms }
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }

    func testBaselineIoB() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let endDate = startDate + 6.hoursToSeconds()
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: endDate, value: 0.4, unit: .unitsPerHour, insulinType: .humalog, isMutable: false)
        
        let iob = dose.insulinOnBoard(at: endDate)
        // From the Python unit tests
        XCTAssertEqual(iob, 0.8589151141064484, accuracy: iobAccuracy)
    }
    
    // copied from the OmniBLE code
    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return OmniBLEPumpManager.onboardingSupportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }
    
    func testBasalRateRounding() throws {
        XCTAssertEqual(roundToSupportedBasalRate(unitsPerHour: 0.31), 0.3, accuracy: iobAccuracy)
        XCTAssertEqual(roundToSupportedBasalRate(unitsPerHour: 0.3491), 0.3, accuracy: iobAccuracy)
        XCTAssertEqual(roundToSupportedBasalRate(unitsPerHour: 0.351), 0.35, accuracy: iobAccuracy)
    }
    
    func testDoseLogic() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        let dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
    }
    
    func testDoseLogicUseMachineLearning() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: true, useBiologicalInvariant: false)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        let dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.5, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
    }
    
    func testDoseLogicUseMachineLearningMicroBolus() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: true, useBiologicalInvariant: false)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        let dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.25, accuracy: iobAccuracy)
    }
    
    func testDoseLogicUseMicroBolus() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        var dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.2, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.02, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
    }
    
    func testDoseLogicDisableMicroBolusFromExercise() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        let dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: true, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
    }
    
    
    func testDoseLogicUseBiologicalInvariant() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: true)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        var dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
    }
    
    func testDoseLogicUseMicroBolusBiologicalInvariant() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: true)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        var dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.2, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.2, accuracy: iobAccuracy)
    }
    
    func testDoseLogicUseMachineLearningBiologicalInvariant() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: true, useBiologicalInvariant: true)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        var dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.5, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 1.5, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
    }
    
    func testDoseLogicUseAll() async {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: true, useBiologicalInvariant: true)
        
        // this is just for logging
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)

        var dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.25, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        dose = await closedLoop.determineDose(settings: settings.snapshot(), physiologicalTempBasal: 1.0, mlTempBasal: 2.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil, isExercising: false, machineLearningInsulinLastThreeHours: safetyTempBasalResult.machineLearningInsulinLastThreeHours)
        
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.25, accuracy: iobAccuracy)
    }
    
}
