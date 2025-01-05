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
        Dependency.useMockConstructors = true
        
        // Initialize mocks
        settings = MockSettingsStorage()
        glucoseStorage = MockGlucoseStorage()
        insulinStorage = MockInsulinStorage()
        deviceManager = MockDeviceDataManager()
        pumpManager = MockPumpManager()
        pumpManagerDelegate = MockPumpManagerDelegate()
        deviceManager.mockPumpManager = pumpManager
        pumpManager.pumpManagerDelegate = pumpManagerDelegate
        
        // Register dependencies
        Dependency.mock { self.settings as SettingsStorage }
        Dependency.mock { self.glucoseStorage as GlucoseStorage }
        Dependency.mock { self.insulinStorage as InsulinStorage }
        Dependency.mock { self.deviceManager as DeviceDataManager }
        Dependency.mock { MockStoredObject.self as StoredObject.Type }
        Dependency.mock { MockReplayLogger() as EventLogger }
        Dependency.mock { MockPhysiologicalModels() as PhysiologicalModels }
        Dependency.mock { MockTargetGlucose() as TargetGlucoseService }
        Dependency.mock { MockWorkoutStatusService() as WorkoutStatusService }
        Dependency.mock { MockMachineLearning() as MachineLearning }
        Dependency.mock { MockSafetyService() as SafetyService }
        Dependency.mock { MockG7DebugLogger() as G7DebugLogger }
        
        closedLoop = LocalClosedLoopService()
    }
    
    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }
    
    // MARK: - Basic Loop State Tests
    
    @MainActor func testLoopWithClosedLoopDisabled() async throws {
        // Setup
        settings.closedLoopEnabled = false
        
        // Test
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertFalse(result, "Loop should return false when closed loop is disabled")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .openLoop, "Action should be openLoop when closed loop is disabled")
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
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertFalse(result, "Loop should return false with stale glucose data")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .glucoseReadingStale, "Action should be glucoseReadingStale")
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
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertFalse(result, "Loop should return false with stale pump data")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .pumpReadingStale, "Action should be pumpReadingStale")
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
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertFalse(result, "Loop should return false with no pump manager")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .noPumpManager, "Action should be noPumpManager")
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
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertTrue(result, "Loop should return true for successful temp basal")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .setTempBasal, "Action should be setTempBasal")
        XCTAssertNotNil(lastResult?.tempBasal, "Temp basal should be set")
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
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertTrue(result, "Loop should return true for successful micro bolus")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .setTempBasal, "Action should be setTempBasal")
        XCTAssertNotNil(lastResult?.microBolusAmount, "Micro bolus amount should be set")
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
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertFalse(result, "Loop should return false when pump returns error")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .pumpError, "Action should be pumpError")
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
        Dependency.mock { mockPhysiological as PhysiologicalModels }
        
        // Mock current data - significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180), // 80 mg/dl above target
            date: now
        )
        insulinStorage.mockLastPumpSync = now
        
        // Execute loop
        let loopResult: ClosedLoopResult = await closedLoop.loop(at: now)
        XCTAssertEqual(loopResult.action, .setTempBasal, "Loop should complete successfully with microbolus")
        
        // Verify microbolus was set
        XCTAssertNotNil(loopResult.microBolusAmount)
        XCTAssertGreaterThan(loopResult.microBolusAmount ?? 0, 0)
        
        // Verify temp basal was zero (since we delivered microbolus)
        XCTAssertEqual(loopResult.tempBasal ?? 0, 0.0, accuracy: tempBasalAccuracy)
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
        Dependency.mock { mockPhysiological as PhysiologicalModels }
        
        // Mock current data - significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180), // 80 mg/dl above target
            date: now
        )
        insulinStorage.mockLastPumpSync = now
        
        // Configure pump to return an error for bolus delivery
        pumpManager.state.bolusEnactmentShouldError = true
        
        // Execute loop
        let result: Bool = await closedLoop.loop(at: now)
        
        // Verify
        XCTAssertFalse(result, "Loop should return false when pump returns error during micro bolus")
        let lastResult = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(lastResult?.action, .pumpError, "Action should be pumpError")
        XCTAssertNotNil(lastResult?.microBolusAmount, "Micro bolus amount should be set even though delivery failed")
        XCTAssertGreaterThan(lastResult?.microBolusAmount ?? 0, 0, "Micro bolus amount should be greater than 0")
        XCTAssertEqual(lastResult?.tempBasal ?? 0, 0.0, accuracy: tempBasalAccuracy, "Temp basal should be 0 since micro bolus was attempted")
    }
}
