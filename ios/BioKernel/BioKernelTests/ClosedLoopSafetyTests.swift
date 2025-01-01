//
//  ClosedLoopSafetyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/30/24.
//

import XCTest
import LoopKit

@testable import BioKernel
import HealthKit

final class ClosedLoopSafetyTests: XCTestCase {
    let iobAccuracy = 0.00000000001
    
    @MainActor override func setUpWithError() throws {
        Dependency.useMockConstructors = true
        Dependency.mock { MockSettingsStorage() as SettingsStorage }
        Dependency.mock { MockStoredObject.self as StoredObject.Type }
        Dependency.mock { MockReplayLogger() as EventLogger }
        Dependency.mock { MockWatchComms() as WatchComms }
        Dependency.mock { MockGlucoseStorage() as GlucoseStorage }
        Dependency.mock { MockDeviceDataManager() as DeviceDataManager }
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }
    
    // MARK: - Max Basal Safety Tests
    
    func testMaxBasalSafetyLimits() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        let maxBasal = 2.0
        await settings.update(maxBasalRateUnitsPerHour: maxBasal)
        
        // Test exactly at max basal
        let exactMaxBasal = await closedLoop.applyGuardrails(
            glucoseInMgDl: 180,
            predictedGlucoseInMgDl: 200,
            newBasalRateRaw: maxBasal,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        XCTAssertEqual(exactMaxBasal, maxBasal, accuracy: iobAccuracy)
        
        // Test slightly above max basal
        let slightlyAboveMax = await closedLoop.applyGuardrails(
            glucoseInMgDl: 180,
            predictedGlucoseInMgDl: 200,
            newBasalRateRaw: maxBasal + 0.1,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        XCTAssertEqual(slightlyAboveMax, maxBasal, accuracy: iobAccuracy)
        
        // Test far above max basal
        let farAboveMax = await closedLoop.applyGuardrails(
            glucoseInMgDl: 180,
            predictedGlucoseInMgDl: 200,
            newBasalRateRaw: maxBasal * 2,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        XCTAssertEqual(farAboveMax, maxBasal, accuracy: iobAccuracy)
    }
    
    // MARK: - Stale Data Tests
    func testStaleCGMData() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        let freshnessInterval = 10.minutesToSeconds()
        await settings.update(freshnessIntervalInSeconds: freshnessInterval)
        
        let glucoseDate = Date()
        let staleCGMDate = glucoseDate.addingTimeInterval(-freshnessInterval - 1)
        
        // Mock glucose storage with stale data
        let mockGlucoseStorage = MockGlucoseStorage()
        await mockGlucoseStorage.addGlucoseReading(quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100), date: staleCGMDate)
        Dependency.mock { mockGlucoseStorage as GlucoseStorage }
        
        // Attempt to loop with stale data
        let loopResult: Bool = await closedLoop.loop(at: glucoseDate)
        XCTAssertFalse(loopResult, "Loop should not complete with stale CGM data")
        
        // Verify result indicates stale data
        let result = await closedLoop.latestClosedLoopResult()
        XCTAssertEqual(result?.action, .glucoseReadingStale)
    }
    
    // MARK: - Recovery Tests
    func testRecoveryFromSafetyViolations() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        await settings.update(useBiologicalInvariant: true)
        
        // First create a biological invariant violation
        let safetyTempBasalResult = SafetyTempBasal(tempBasal: 1.0, machineLearningInsulinLastThreeHours: 0.0)
        var dose = await closedLoop.determineDose(
            settings: settings.snapshot(),
            safetyTempBasalResult: safetyTempBasalResult,
            physiologicalTempBasal: 1.0,
            mlTempBasal: 2.0,
            safetyTempBasal: 1.5,
            microBolusPhysiological: 0.2,
            microBolusSafety: 0.25,
            biologicalInvariant: -45, // This should trigger a violation
            isExercising: false
        )
        
        // Verify system stops insulin delivery during violation
        XCTAssertEqual(dose.tempBasal, 0.0, accuracy: iobAccuracy)
        XCTAssertEqual(dose.microBolus, 0.0, accuracy: iobAccuracy)
        
        // Now test recovery when biological invariant returns to normal
        dose = await closedLoop.determineDose(
            settings: settings.snapshot(),
            safetyTempBasalResult: safetyTempBasalResult,
            physiologicalTempBasal: 1.0,
            mlTempBasal: 2.0,
            safetyTempBasal: 1.5,
            microBolusPhysiological: 0.2,
            microBolusSafety: 0.25,
            biologicalInvariant: -20, // Back to safe range
            isExercising: false
        )
        
        // Verify insulin delivery resumes
        XCTAssertGreaterThan(dose.tempBasal, 0.0)
    }
    
    // MARK: - Property-Based Tests
    
    func testInsulinCalculationsProperties() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let testDurations = [30, 60, 90, 120, 150, 180] // minutes
        
        for duration in testDurations {
            let dose = DoseEntry(
                type: .tempBasal,
                startDate: startDate,
                endDate: startDate + Double(duration).minutesToSeconds(),
                value: 1.0,
                unit: .unitsPerHour,
                insulinType: .humalog,
                isMutable: false
            )
            
            // Test at various points after the dose
            for timeOffset in stride(from: 0, through: 360, by: 30) {
                let checkTime = startDate.addingTimeInterval(Double(timeOffset).minutesToSeconds())
                let iob = dose.insulinOnBoard(at: checkTime)
                
                // Property 1: IOB should never be negative
                XCTAssertGreaterThanOrEqual(iob, 0.0, "IOB should never be negative")
                
                // Property 2: IOB should never exceed total programmed insulin
                let maxPossibleInsulin = dose.programmedUnits
                XCTAssertLessThanOrEqual(iob, maxPossibleInsulin, "IOB should not exceed total programmed insulin")
                
                // Property 3: IOB should be monotonically decreasing after delivery
                if timeOffset > duration {
                    let previousTime = checkTime.addingTimeInterval(-30.minutesToSeconds())
                    let previousIob = dose.insulinOnBoard(at: previousTime)
                    XCTAssertGreaterThanOrEqual(previousIob, iob, "IOB should decrease monotonically after delivery")
                }
            }
        }
    }
    
    // MARK: - Timing Requirements Tests
    
    func testClosedLoopTimingRequirements() async throws {
        let closedLoop = LocalClosedLoopService()
        let startTime = Date()
        
        // Measure time for a complete loop cycle
        let loopStartTime = DispatchTime.now()
        let _: Bool = await closedLoop.loop(at: startTime)
        let loopEndTime = DispatchTime.now()
        
        let loopDuration = Double(loopEndTime.uptimeNanoseconds - loopStartTime.uptimeNanoseconds) / 1_000_000_000.0
        
        // Loop should complete within 5 seconds (adjust this threshold based on your requirements)
        XCTAssertLessThanOrEqual(loopDuration, 5.0, "Loop cycle took too long to complete")
    }
    
    @MainActor func testNegativeBasalRateClampedToZero() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = MockSettingsStorage()
        
        let result = await closedLoop.applyGuardrails(
            glucoseInMgDl: 120,
            predictedGlucoseInMgDl: 130,
            newBasalRateRaw: -0.5,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        
        XCTAssertEqual(result, 0.0, accuracy: iobAccuracy, "Negative basal rate should be clamped to zero")
    }

    @MainActor func testShutOffBasalRateWhenCurrentGlucoseBelowThreshold() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = MockSettingsStorage()
        settings.update(shutOffGlucoseInMgDl: 80.0)
        
        let result = await closedLoop.applyGuardrails(
            glucoseInMgDl: 75.0, // Below threshold
            predictedGlucoseInMgDl: 85.0, // Above threshold
            newBasalRateRaw: 1.0,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        
        XCTAssertEqual(result, 0.0, accuracy: iobAccuracy, "Basal rate should be zero when current glucose is below shutoff threshold")
    }

    @MainActor func testShutOffBasalRateWhenPredictedGlucoseBelowThreshold() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = MockSettingsStorage()
        settings.update(shutOffGlucoseInMgDl: 80.0)
        
        let result = await closedLoop.applyGuardrails(
            glucoseInMgDl: 85.0, // Above threshold
            predictedGlucoseInMgDl: 75.0, // Below threshold
            newBasalRateRaw: 1.0,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        
        XCTAssertEqual(result, 0.0, accuracy: iobAccuracy, "Basal rate should be zero when predicted glucose is below shutoff threshold")
    }
    
    // MARK: - Adverse Conditions Tests
    // We should have some adverse conditions tests but let's be more
    // thoughtful about it first. This test shows an example of what one
    // might look like
    /*
    func testAdverseConditions() async throws {
        let closedLoop = LocalClosedLoopService()
        let settings = await MockSettingsStorage()
        
        // Test with erratic CGM data
        let erraticGlucoseData = [
            (Date(), 120.0),
            (Date().addingTimeInterval(-5.minutesToSeconds()), 180.0),
            (Date().addingTimeInterval(-10.minutesToSeconds()), 90.0),
            (Date().addingTimeInterval(-15.minutesToSeconds()), 200.0)
        ]
        
        let mockGlucoseStorage = MockGlucoseStorage()
        for (date, value) in erraticGlucoseData {
            await mockGlucoseStorage.addGlucoseReading(
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value),
                date: date
            )
        }
        Dependency.mock { mockGlucoseStorage as GlucoseStorage }
        Dependency.mock { MockInsulinStorage() as InsulinStorage }
        
        // Verify system responds appropriately to erratic data
        let result: Bool = await closedLoop.loop(at: Date())
        
        // System should still complete the loop but likely with conservative insulin delivery
        let latestResult = await closedLoop.latestClosedLoopResult()
        XCTAssertNotNil(latestResult)
    }
     */
}
