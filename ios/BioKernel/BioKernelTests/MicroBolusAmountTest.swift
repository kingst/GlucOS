//
//  MicroBolusAmountTest.swift
//  BioKernelTests
//
//  Created by Sam King on 12/31/24.
//

import XCTest
import LoopKit
@testable import BioKernel

final class MicroBolusTests: XCTestCase {
    let insulinAccuracy = 0.00000000001
    var closedLoop: LocalClosedLoopService!
    var settings: MockSettingsStorage!
    
    @MainActor override func setUpWithError() throws {
        Dependency.useMockConstructors = true
        settings = MockSettingsStorage()
        
        Dependency.mock { self.settings as SettingsStorage }
        Dependency.mock { MockStoredObject.self as StoredObject.Type }
        Dependency.mock { MockReplayLogger() as EventLogger }
        Dependency.mock { MockWatchComms() as WatchComms }
        Dependency.mock { MockDeviceDataManager() as DeviceDataManager }
        
        closedLoop = LocalClosedLoopService()
        
        // Set default test values
        settings.update(
            targetGlucoseInMgDl: 100,
            maxBasalRateUnitsPerHour: 3.0,
            microBolusDoseFactor: 0.3
        )
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }
    
    @MainActor func testNoMicroBolusWithinTimeWindow() async throws {
        // Setup: Set last micro bolus to 2 minutes ago
        let at = Date()
        await closedLoop.setLastMicroBolusForTesting(date: at.addingTimeInterval(-2 * 60))
        
        let amount = await closedLoop.microBolusAmount(
            tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            basalRate: 1.0,
            predictedGlucoseInMgDl: 160,
            at: at
        )
        
        XCTAssertNil(amount, "Should not issue micro bolus within 4.2 minutes of previous")
    }
    
    @MainActor func testAllowMicroBolusAfterTimeWindow() async throws {
        // Setup: Set last micro bolus to 5 minutes ago
        let at = Date()
        await closedLoop.setLastMicroBolusForTesting(date: at.addingTimeInterval(-5 * 60))
        
        let amount = await closedLoop.microBolusAmount(
            tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            basalRate: 1.0,
            predictedGlucoseInMgDl: 160,
            at: at
        )
        
        XCTAssertNotNil(amount, "Should allow micro bolus after 4.2 minutes")
        XCTAssertGreaterThan(amount ?? 0, 0)
    }
    
    @MainActor func testNoMicroBolusWhenGlucoseCloseToTarget() async throws {
        let amount = await closedLoop.microBolusAmount(
            tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 115, // Only 15 mg/dL above target
            targetGlucoseInMgDl: 100,
            basalRate: 1.0,
            predictedGlucoseInMgDl: 120,
            at: Date()
        )
        
        XCTAssertNil(amount, "Should not issue micro bolus when glucose is less than 20 mg/dL above target")
    }
    
    @MainActor func testNoMicroBolusWhenGlucoseFalling() async throws {
        let amount = await closedLoop.microBolusAmount(
            tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            basalRate: 1.0,
            predictedGlucoseInMgDl: 145, // Predicted < current - 2
            at: Date()
        )
        
        XCTAssertNil(amount, "Should not issue micro bolus when glucose is predicted to fall")
    }
    
    @MainActor func testNoMicroBolusWhenInsulinAmountNegative() async throws {
        let amount = await closedLoop.microBolusAmount(
            tempBasal: 0.5, // Less than basal rate
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            basalRate: 1.0,
            predictedGlucoseInMgDl: 160,
            at: Date()
        )
        
        XCTAssertNil(amount, "Should not issue micro bolus when insulin amount would be negative")
    }
    
    @MainActor func testMicroBolusAmountClampedToMax() async throws {
        settings.update(maxBasalRateUnitsPerHour: 2.0)
        
        let amount = await closedLoop.microBolusAmount(
            tempBasal: 5.0, // Much higher than max
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            basalRate: 1.0,
            predictedGlucoseInMgDl: 160,
            at: Date()
        )
        
        XCTAssertNotNil(amount)
        XCTAssertLessThanOrEqual(amount ?? 0, 1.0, "Micro bolus should be clamped to max (2.0 U/hr * 0.5 hr)")
    }
}

// Helper extension for settings updates
extension MockSettingsStorage {
    func update(
        targetGlucoseInMgDl: Double? = nil,
        maxBasalRateUnitsPerHour: Double? = nil,
        microBolusDoseFactor: Double? = nil
    ) {
        if let target = targetGlucoseInMgDl {
            self.targetGlucoseInMgDl = target
        }
        if let maxBasal = maxBasalRateUnitsPerHour {
            self.maxBasalRateUnitsPerHour = maxBasal
        }
        if let factor = microBolusDoseFactor {
            self.microBolusDoseFactor = factor
        }
    }
}
