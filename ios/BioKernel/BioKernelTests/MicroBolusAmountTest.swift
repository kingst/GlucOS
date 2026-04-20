//
//  MicroBolusAmountTest.swift
//  BioKernelTests
//
//  Created by Sam King on 12/31/24.
//

import Testing
import Foundation
import LoopKit
import MockKit
@testable import BioKernel

@MainActor
struct MicroBolusTests {
    let insulinAccuracy = 0.00000000001
    let closedLoop: LocalClosedLoopService
    let settings: MockSettingsStorage
    let pumpManager: MockPumpManager

    init() {
        let settings = MockSettingsStorage()
        let pumpManager = MockPumpManager()

        let closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )

        // Set default test values
        settings.update(
            targetGlucoseInMgDl: 100,
            maxBasalRateUnitsPerHour: 3.0,
            microBolusDoseFactor: 0.3
        )

        self.settings = settings
        self.pumpManager = pumpManager
        self.closedLoop = closedLoop
    }

    @Test func noMicroBolusWithinTimeWindow() async throws {
        // Setup: Set last micro bolus to 2 minutes ago
        let at = Date()
        await closedLoop.setLastMicroBolusForTesting(date: at.addingTimeInterval(-2 * 60))

        let amount = await closedLoop.microBolusAmount(
            pumpManager: pumpManager, tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            at: at
        )

        #expect(amount == nil, "Should not issue micro bolus within 4.2 minutes of previous")
    }

    @Test func allowMicroBolusAfterTimeWindow() async throws {
        // Setup: Set last micro bolus to 5 minutes ago
        let at = Date()
        await closedLoop.setLastMicroBolusForTesting(date: at.addingTimeInterval(-5 * 60))

        let amount = await closedLoop.microBolusAmount(
            pumpManager: pumpManager,
            tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            at: at
        )

        let value = try #require(amount, "Should allow micro bolus after 4.2 minutes")
        #expect(value > 0)
    }

    @Test func noMicroBolusWhenGlucoseCloseToTarget() async throws {
        let amount = await closedLoop.microBolusAmount(
            pumpManager: pumpManager,
            tempBasal: 2.0,
            settings: settings.snapshot(),
            glucoseInMgDl: 115, // Only 15 mg/dL above target
            targetGlucoseInMgDl: 100,
            at: Date()
        )

        #expect(amount == nil, "Should not issue micro bolus when glucose is less than 20 mg/dL above target")
    }

    @Test func noMicroBolusWhenInsulinAmountNegative() async throws {
        let amount = await closedLoop.microBolusAmount(
            pumpManager: pumpManager,
            tempBasal: -0.5,
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            at: Date()
        )

        #expect(amount == nil, "Should not issue micro bolus when insulin amount would be negative")
    }

    @Test func microBolusAmountClampedToMax() async throws {
        settings.update(maxBasalRateUnitsPerHour: 2.0)

        let amount = await closedLoop.microBolusAmount(
            pumpManager: pumpManager,
            tempBasal: 5.0, // Much higher than max
            settings: settings.snapshot(),
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            at: Date()
        )

        let value = try #require(amount)
        #expect(value <= 1.0, "Micro bolus should be clamped to max (2.0 U/hr * 0.5 hr)")
    }

    @Test func microBolusAmountClampedToInsulin() async throws {
        // Set a dose factor > 1.0 to test clamping against total insulin
        settings.update(maxBasalRateUnitsPerHour: 10)
        settings.update(microBolusDoseFactor: 1.2)
        let snapshot = settings.snapshot()
        let correctionDurationHours = snapshot.correctionDurationInSeconds / 3600.0
        let tempBasal = 5.0
        let insulin = tempBasal * correctionDurationHours // 2.5

        let amount = await closedLoop.microBolusAmount(
            pumpManager: pumpManager,
            tempBasal: tempBasal,
            settings: snapshot,
            glucoseInMgDl: 150,
            targetGlucoseInMgDl: 100,
            at: Date()
        )

        let value = try #require(amount)
        // With doseFactor=1.2, amount would be 1.2 * 2.5 = 3.0.
        // It should be clamped to insulin, which is 2.5.
        #expect(abs(value - insulin) <= insulinAccuracy, "Micro bolus should be clamped to the total insulin amount")
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
