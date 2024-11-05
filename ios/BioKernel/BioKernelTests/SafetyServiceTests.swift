//
//  SafetyServiceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 1/21/24.
//

import XCTest
import LoopKit

@testable import BioKernel

// tempBasal tests still needed
//  - historical ml is out of range but clamping stays in range (maybe put in separate function to simplify testing?)
final class SafetyServiceTests: XCTestCase {

    let insulinAccuracy = 0.0001
    
    @MainActor override func setUpWithError() throws {
        Dependency.useMockConstructors = true
        let settings = MockSettingsStorage()
        Dependency.mock { settings as SettingsStorage }
        Dependency.mock { MockStoredObject.self as StoredObject.Type }
        Dependency.mock { MockReplayLogger() as EventLogger }
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }

    func testSafetyStateBasics() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let safetyState = SafetyState(at: startDate, duration: 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: 1.2, safetyTempBasalUnitsPerHour: 1.2, machineLearningTempBasalUnitsPerHour: 1.2, programmedMicroBolus: 0.0, safetyMicroBolus: 0.0, machineLearningMicroBolus: 0.0, biologicalInvariantViolation: false)
        
        // look at a time before our command ran
        let beforeUnits = safetyState.deltaUnitsDeliveredByMachineLearning(from: startDate - 5.minutesToSeconds(), to: startDate)
        
        XCTAssertEqual(beforeUnits, 0.0, accuracy: insulinAccuracy)
        
        // the system used the safety temp basal, so ml insulin should be 0
        let unitsFromSafetyTempBasal = safetyState.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 5.minutesToSeconds())
        
        XCTAssertEqual(unitsFromSafetyTempBasal, 0.0, accuracy: insulinAccuracy)
        
        let safetyState2 = SafetyState(at: startDate, duration: 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: 1.2, safetyTempBasalUnitsPerHour: 1.2, machineLearningTempBasalUnitsPerHour: 2.4, programmedMicroBolus: 0.0, safetyMicroBolus: 0.0, machineLearningMicroBolus: 0.0, biologicalInvariantViolation: false)
        
        let unitsFromProgrammed = safetyState2.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 5.minutesToSeconds())
        
        XCTAssertEqual(unitsFromProgrammed, 0.0, accuracy: insulinAccuracy)
    }
    
    func testSafetyStateCalculation() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let safetyStateEqual = SafetyState(at: startDate, duration: 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: 1.2, safetyTempBasalUnitsPerHour: 0, machineLearningTempBasalUnitsPerHour: 1.2, programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
        
        let mlInsulin = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 5.minutesToSeconds())
        XCTAssertEqual(mlInsulin, 0.1, accuracy: insulinAccuracy)
        
        // make sure that it cuts it off at duration
        let mlInsulin2 = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 60.minutesToSeconds())
        XCTAssertEqual(mlInsulin2, 0.6, accuracy: insulinAccuracy)

        // make sure that we can start in the middle
        let mlInsulin3 = safetyStateEqual.deltaUnitsDeliveredByMachineLearning(from: startDate + 25.minutesToSeconds(), to: startDate + 60.minutesToSeconds())
        XCTAssertEqual(mlInsulin3, 0.1, accuracy: insulinAccuracy)
        
        // check when the programmed value is in between phys and ml
        let safetyStateNotEqual = SafetyState(at: startDate, duration: 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: 1.2, safetyTempBasalUnitsPerHour: 0, machineLearningTempBasalUnitsPerHour: 2.4, programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
        
        let mlInsulin4 = safetyStateNotEqual.deltaUnitsDeliveredByMachineLearning(from: startDate, to: startDate + 5.minutesToSeconds())
        XCTAssertEqual(mlInsulin4, 0.1, accuracy: insulinAccuracy)
    }
    
    // for this test we will deliver two ML doses that provide an excess of
    // one unit of insulin each. Then on the third the system should instead
    // use the safety insulin value since we've exausted our ML insulin
    func testExtraInsulinClamp() async {
        let safetyService = LocalSafetyService.forUnitTests()
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        // our first dose that will run for 30 minutes
        await safetyService.updateAfterProgrammingPump(at: startDate, programmedTempBasalUnitsPerHour: 3.0, safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds(), programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
        
        let firstTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())
        
        XCTAssertEqual(firstTempBasal.tempBasal, 3.0, accuracy: insulinAccuracy)
        
        await safetyService.updateAfterProgrammingPump(at: startDate + 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: firstTempBasal.tempBasal, safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds(), programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
        
        // at this point we have already delivered 2 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())
        
        XCTAssertEqual(secondTempBasal.tempBasal, 1.0, accuracy: insulinAccuracy)
    }
    
    func testBasalAndBolus() async throws {
        let safetyService = LocalSafetyService.forUnitTests()
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        // our first dose is a temp basal
        await safetyService.updateAfterProgrammingPump(at: startDate, programmedTempBasalUnitsPerHour: 1.2, safetyTempBasalUnitsPerHour: 0, machineLearningTempBasalUnitsPerHour: 1.2, duration: 30.minutesToSeconds(), programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
        
        // add a micro bolus after 5 minutes
        await safetyService.updateAfterProgrammingPump(at: startDate + 5.minutesToSeconds(), programmedTempBasalUnitsPerHour: 0, safetyTempBasalUnitsPerHour: 0, machineLearningTempBasalUnitsPerHour: 0, duration: 30.minutesToSeconds(), programmedMicroBolus: 2.9, safetyMicroBolus: 0, machineLearningMicroBolus: 2.9, biologicalInvariantViolation: false)
        
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), safetyTempBasalUnitsPerHour: 1.0, machineLearningTempBasalUnitsPerHour: 3.0, duration: 30.minutesToSeconds())
        
        XCTAssertEqual(secondTempBasal.tempBasal, 1.0, accuracy: insulinAccuracy)
    }
    
    func testLessInsulinClamp() async {
        let safetyService = LocalSafetyService.forUnitTests()
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        // our first dose that will run for 30 minutes
        await safetyService.updateAfterProgrammingPump(at: startDate, programmedTempBasalUnitsPerHour: 0, safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0, duration: 30.minutesToSeconds(), programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
        
        let firstTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0.0, duration: 30.minutesToSeconds())
        
        XCTAssertEqual(firstTempBasal.tempBasal, 0.0, accuracy: insulinAccuracy)
        
        await safetyService.updateAfterProgrammingPump(at: startDate + 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: 0, safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0, duration: 30.minutesToSeconds(), programmedMicroBolus: 0, safetyMicroBolus: 0, machineLearningMicroBolus: 0, biologicalInvariantViolation: false)
                
        // at this point we have a deficit of 3 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0.0, duration: 30.minutesToSeconds())
        
        XCTAssertEqual(secondTempBasal.tempBasal, 3.0, accuracy: insulinAccuracy)
    }
    /*
    func testLessThenExtra() async {
        // ML sets tempBasal to 0
        let insulinStorage = MockInsulinStorageConstantAutomaticTempBasal(automaticTempBasal: 0)
        Dependency.mock { insulinStorage as InsulinStorage }
        
        let safetyService = LocalSafetyService.forUnitTests()
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        // our first dose that will run for 30 minutes
        await safetyService.updateAfterSettingTempBasal(at: startDate, programmedTempBasalUnitsPerHour: 0, safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0)
        
        let firstTempBasal = await safetyService.tempBasal(at: startDate + 30.minutesToSeconds(), safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0.0)
        
        XCTAssertEqual(firstTempBasal.tempBasal, 0.0, accuracy: insulinAccuracy)
        
        await safetyService.updateAfterSettingTempBasal(at: startDate + 30.minutesToSeconds(), programmedTempBasalUnitsPerHour: firstTempBasal.tempBasal, safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0.0)
        
        // at this point we have a deficit of 3 units from ML, which is
        // our cap so the system should fall back to the safety tempBasal
        let secondTempBasal = await safetyService.tempBasal(at: startDate + 60.minutesToSeconds(), safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0.0)
        
        XCTAssertEqual(secondTempBasal.tempBasal, 3.0, accuracy: insulinAccuracy)
        
        await safetyService.updateAfterSettingTempBasal(at: startDate + 60.minutesToSeconds(), programmedTempBasalUnitsPerHour: 3.0, safetyTempBasalUnitsPerHour: 3.0, machineLearningTempBasalUnitsPerHour: 0.0)

        // we now have a deficit of 3 units so we can deliver 5 for
        // a temp basal of 10 running for 30 minutes
        let thirdTempBasal = await safetyService.tempBasal(at: startDate + 90.minutesToSeconds(), safetyTempBasalUnitsPerHour: 0.0, machineLearningTempBasalUnitsPerHour: 10.0)
        
        XCTAssertEqual(thirdTempBasal.tempBasal, 10.0, accuracy: insulinAccuracy)
    }
    */
}
