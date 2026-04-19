//
//  LoopFunctionTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/31/24.
//

import XCTest
import LoopKit
import HealthKit
import MockKit
import G7SensorKit
@testable import BioKernel

final class LoopFunctionTests: XCTestCase {
    let tempBasalAccuracy = 0.00000000001
    
    var closedLoop: LocalClosedLoopService!
    var settings: MockSettingsStorage!
    var glucoseStorage: MockGlucoseStorage!
    var insulinStorage: MockInsulinStorage!
    var deviceManager: MockDeviceDataManager!
    var pumpManager: MockPumpManager!
    var pumpManagerDelegate: MockPumpManagerDelegate!
    let now = Date.f("2024-01-15 10:30:00 +0000")
    
    @MainActor override func setUpWithError() throws {
        // Initialize mocks
        settings = MockSettingsStorage()
        glucoseStorage = MockGlucoseStorage()
        insulinStorage = MockInsulinStorage()
        deviceManager = MockDeviceDataManager()
        pumpManager = MockPumpManager()
        pumpManagerDelegate = MockPumpManagerDelegate()
        deviceManager.mockPumpManager = pumpManager
        pumpManager.pumpManagerDelegate = pumpManagerDelegate

        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage
        )
    }
    
    // MARK: - Basic Loop State Tests
    
    @MainActor func testLoopWithClosedLoopDisabled() async throws {
        // Setup
        settings.closedLoopEnabled = false
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertFalse(result, "Loop should return false when closed loop is disabled")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.outcome.skipReason, .openLoop, "Should skip with openLoop when closed loop is disabled")
    }
    
    @MainActor func testLoopWithStaleGlucoseData() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60 // 10 minutes
        
        // Add stale glucose reading (15 minutes old)
        let staleGlucoseDate = now.addingTimeInterval(-15 * 60)
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            date: staleGlucoseDate
        )
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertFalse(result, "Loop should return false with stale glucose data")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.outcome.skipReason, .glucoseReadingStale, "Should skip with glucoseReadingStale")
    }
    
    @MainActor func testLoopWithStalePumpData() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60 // 10 minutes
        
        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            date: now.addingTimeInterval(-5 * 60)
        )
        
        // Set stale pump sync time
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-15 * 60)
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertFalse(result, "Loop should return false with stale pump data")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.outcome.skipReason, .pumpReadingStale, "Should skip with pumpReadingStale")
    }
    
    @MainActor func testLoopWithNoPumpManager() async throws {
        // Setup
        settings.closedLoopEnabled = true
        deviceManager.pumpManager = nil
        
        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            date: now.addingTimeInterval(-5 * 60)
        )
        
        // Add fresh pump reading
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertFalse(result, "Loop should return false with no pump manager")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.outcome.skipReason, .noPumpManager, "Should skip with noPumpManager")
    }
    
    // MARK: - Successful Loop Tests
    @MainActor func testSuccessfulLoopWithTempBasal() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = false
        
        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )
        
        // Set fresh pump sync
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertTrue(result, "Loop should return true for successful temp basal")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .dosed(let snapshot) = lastResult?.outcome else {
            return XCTFail("Outcome should be .dosed for successful temp basal")
        }
        guard case .tempBasal = snapshot.decision else {
            return XCTFail("Decision should be .tempBasal")
        }
    }
    
    @MainActor func testSuccessfulLoopWithMicroBolus() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = true
        settings.targetGlucoseInMgDl = 100
        
        // Add fresh glucose reading significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180),
            date: now.addingTimeInterval(-5 * 60)
        )
        
        // Set fresh pump sync
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertTrue(result, "Loop should return true for successful micro bolus")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .dosed(let snapshot) = lastResult?.outcome else {
            return XCTFail("Outcome should be .dosed for successful micro bolus")
        }
        guard case .microBolus = snapshot.decision else {
            return XCTFail("Decision should be .microBolus")
        }
    }
    
    @MainActor func testLoopWithPumpError() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        
        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )
        
        // Set fresh pump sync
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)
        
        pumpManager.state.pumpErrorDetected = true
        
        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertFalse(result, "Loop should return false when pump returns error")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .pumpError = lastResult?.outcome else {
            return XCTFail("Outcome should be .pumpError")
        }
    }
    
    // MARK: - Microbolus tests
    @MainActor func testLoopWithMicrobolusSuccess() async throws {
        // Configure settings for microbolus
        settings.update(maxBasalRateUnitsPerHour: 2.0)
        settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)
        
        // Clear any previous micro bolus timestamp
        await closedLoop.setLastMicroBolusForTesting(date: nil)
        
        // Mock physiological models to return rising glucose prediction
        let mockPhysiological = MockPhysiologicalModels()
        mockPhysiological.mockPredictGlucose = 185  // Rising glucose
        mockPhysiological.mockTempBasalResult = 2.0
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: mockPhysiological
        )
        
        // Mock current data - significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180), // 80 mg/dl above target
            date: now
        )
        insulinStorage.mockLastPumpSync = now
        
        // Execute loop
        let loopResult: ClosedLoopResult = await closedLoop.runLoop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())
        guard case .dosed(let snapshot) = loopResult.outcome else {
            return XCTFail("Loop should complete successfully with microbolus")
        }
        guard case .microBolus(let units) = snapshot.decision else {
            return XCTFail("Decision should be .microBolus")
        }

        // Verify microbolus was set
        XCTAssertGreaterThan(units, 0)
    }
    
    @MainActor func testLoopWithMicrobolusError() async throws {
        // Configure settings for microbolus
        settings.update(maxBasalRateUnitsPerHour: 2.0)
        settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)
        
        // Clear any previous micro bolus timestamp
        await closedLoop.setLastMicroBolusForTesting(date: nil)
        
        // Mock physiological models to return rising glucose prediction
        let mockPhysiological = MockPhysiologicalModels()
        mockPhysiological.mockPredictGlucose = 185  // Rising glucose
        mockPhysiological.mockTempBasalResult = 2.0
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: mockPhysiological
        )
        
        // Mock current data - significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180), // 80 mg/dl above target
            date: now
        )
        insulinStorage.mockLastPumpSync = now
        
        // Configure pump to return an error for bolus delivery
        pumpManager.state.bolusEnactmentShouldError = true
        
        // Execute loop
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        XCTAssertFalse(result, "Loop should return false when pump returns error during micro bolus")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .pumpError(let snapshot) = lastResult?.outcome else {
            return XCTFail("Outcome should be .pumpError")
        }
        guard case .microBolus(let units) = snapshot.decision else {
            return XCTFail("Decision should be .microBolus even though delivery failed")
        }
        XCTAssertGreaterThan(units, 0, "Micro bolus amount should be greater than 0")
    }
}
