//
//  LoopFunctionTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/31/24.
//

import Testing
import Foundation
import LoopKit
import HealthKit
import MockKit
import G7SensorKit
@testable import BioKernel

@MainActor
struct LoopFunctionTests {
    let tempBasalAccuracy = 0.00000000001

    var closedLoop: LocalClosedLoopService
    let settings: MockSettingsStorage
    let glucoseStorage: MockGlucoseStorage
    let insulinStorage: MockInsulinStorage
    let deviceManager: MockDeviceDataManager
    let pumpManager: MockPumpManager
    let pumpManagerDelegate: MockPumpManagerDelegate
    let now = Date.f("2024-01-15 10:30:00 +0000")

    init() {
        let settings = MockSettingsStorage()
        let glucoseStorage = MockGlucoseStorage()
        let insulinStorage = MockInsulinStorage()
        let deviceManager = MockDeviceDataManager()
        let pumpManager = MockPumpManager()
        let pumpManagerDelegate = MockPumpManagerDelegate()
        deviceManager.mockPumpManager = pumpManager
        pumpManager.pumpManagerDelegate = pumpManagerDelegate

        let closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage
        )

        self.settings = settings
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.deviceManager = deviceManager
        self.pumpManager = pumpManager
        self.pumpManagerDelegate = pumpManagerDelegate
        self.closedLoop = closedLoop
    }

    // MARK: - Basic Loop State Tests

    @Test func loopWithClosedLoopDisabled() async throws {
        // Setup
        settings.closedLoopEnabled = false

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false when closed loop is disabled")
        let lastResult = await closedLoop.latestClosedLoopResult()
        #expect(lastResult?.outcome.skipReason == .openLoop, "Should skip with openLoop when closed loop is disabled")
    }

    @Test func loopWithStaleGlucoseData() async throws {
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
        #expect(!result, "Loop should return false with stale glucose data")
        let lastResult = await closedLoop.latestClosedLoopResult()
        #expect(lastResult?.outcome.skipReason == .glucoseReadingStale, "Should skip with glucoseReadingStale")
    }

    @Test func loopWithStalePumpData() async throws {
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
        #expect(!result, "Loop should return false with stale pump data")
        let lastResult = await closedLoop.latestClosedLoopResult()
        #expect(lastResult?.outcome.skipReason == .pumpReadingStale, "Should skip with pumpReadingStale")
    }

    @Test func loopWithNoPumpManager() async throws {
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
        #expect(!result, "Loop should return false with no pump manager")
        let lastResult = await closedLoop.latestClosedLoopResult()
        #expect(lastResult?.outcome.skipReason == .noPumpManager, "Should skip with noPumpManager")
    }

    // MARK: - Successful Loop Tests
    @Test func successfulLoopWithTempBasal() async throws {
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
        #expect(result, "Loop should return true for successful temp basal")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .dosed(let snapshot) = lastResult?.outcome else {
            Issue.record("Outcome should be .dosed for successful temp basal")
            return
        }
        guard case .tempBasal = snapshot.decision else {
            Issue.record("Decision should be .tempBasal")
            return
        }
    }

    @Test func successfulLoopWithMicroBolus() async throws {
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
        #expect(result, "Loop should return true for successful micro bolus")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .dosed(let snapshot) = lastResult?.outcome else {
            Issue.record("Outcome should be .dosed for successful micro bolus")
            return
        }
        guard case .microBolus = snapshot.decision else {
            Issue.record("Decision should be .microBolus")
            return
        }
    }

    @Test func loopWithPumpError() async throws {
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
        #expect(!result, "Loop should return false when pump returns error")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .pumpError = lastResult?.outcome else {
            Issue.record("Outcome should be .pumpError")
            return
        }
    }

    // MARK: - Microbolus tests
    @Test mutating func loopWithMicrobolusSuccess() async throws {
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
            Issue.record("Loop should complete successfully with microbolus")
            return
        }
        guard case .microBolus(let units) = snapshot.decision else {
            Issue.record("Decision should be .microBolus")
            return
        }

        // Verify microbolus was set
        #expect(units > 0)
    }

    @Test mutating func loopWithMicrobolusError() async throws {
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
        #expect(!result, "Loop should return false when pump returns error during micro bolus")
        let lastResult = await closedLoop.latestClosedLoopResult()
        guard case .pumpError(let snapshot) = lastResult?.outcome else {
            Issue.record("Outcome should be .pumpError")
            return
        }
        guard case .microBolus(let units) = snapshot.decision else {
            Issue.record("Decision should be .microBolus even though delivery failed")
            return
        }
        #expect(units > 0, "Micro bolus amount should be greater than 0")
    }
}
