//
//  ClosedLoopSafetyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/30/24.
//

import Testing
import Foundation
import LoopKit

@testable import BioKernel
import HealthKit

@MainActor
struct ClosedLoopSafetyTests {
    let iobAccuracy = 0.00000000001

    private func makeService(
        settings: MockSettingsStorage,
        glucoseStorage: GlucoseStorage = MockGlucoseStorage(),
        insulinStorage: InsulinStorage = MockInsulinStorage()
    ) -> LocalClosedLoopService {
        return makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage
        )
    }

    // MARK: - Max Basal Safety Tests

    @Test func maxBasalSafetyLimits() async throws {
        let settings = MockSettingsStorage()
        let closedLoop = makeService(settings: settings)
        let maxBasal = 2.0
        settings.update(maxBasalRateUnitsPerHour: maxBasal)

        // Test exactly at max basal
        let exactMaxBasal = await closedLoop.applyGuardrails(
            glucoseInMgDl: 180,
            predictedGlucoseInMgDl: 200,
            newBasalRateRaw: maxBasal,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        #expect(abs(exactMaxBasal - maxBasal) <= iobAccuracy)

        // Test slightly above max basal
        let slightlyAboveMax = await closedLoop.applyGuardrails(
            glucoseInMgDl: 180,
            predictedGlucoseInMgDl: 200,
            newBasalRateRaw: maxBasal + 0.1,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        #expect(abs(slightlyAboveMax - maxBasal) <= iobAccuracy)

        // Test far above max basal
        let farAboveMax = await closedLoop.applyGuardrails(
            glucoseInMgDl: 180,
            predictedGlucoseInMgDl: 200,
            newBasalRateRaw: maxBasal * 2,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )
        #expect(abs(farAboveMax - maxBasal) <= iobAccuracy)
    }

    // MARK: - Stale Data Tests
    @Test func staleCGMData() async throws {
        let settings = MockSettingsStorage()
        let freshnessInterval = 10.minutesToSeconds()
        settings.update(freshnessIntervalInSeconds: freshnessInterval)

        let glucoseDate = Date()
        let staleCGMDate = glucoseDate.addingTimeInterval(-freshnessInterval - 1)

        // Mock glucose storage with stale data
        let mockGlucoseStorage = MockGlucoseStorage()
        await mockGlucoseStorage.addGlucoseReading(quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100), date: staleCGMDate)
        let closedLoop = makeService(settings: settings, glucoseStorage: mockGlucoseStorage)

        // Attempt to loop with stale data
        let metadata = CgmPumpMetadata(cgmStartedAt: nil, cgmExpiresAt: nil, pumpStartedAt: nil, pumpExpiresAt: nil, pumpResevoirPercentRemaining: nil)
        let loopResult: Bool = await closedLoop.loop(at: glucoseDate, pumpManager: nil, cgmPumpMetadata: metadata)
        #expect(!loopResult, "Loop should not complete with stale CGM data")

        // Verify result indicates stale data
        let result = await closedLoop.latestClosedLoopResult()
        #expect(result?.outcome.skipReason == .glucoseReadingStale)
    }

    // MARK: - Recovery Tests
    @Test func recoveryFromSafetyViolations() async throws {
        let settings = MockSettingsStorage()
        let closedLoop = makeService(settings: settings)
        settings.update(useBiologicalInvariant: true)

        // First create a biological invariant violation
        var dose = await closedLoop.determineDose(
            settings: settings.snapshot(),
            physiologicalTempBasal: 1.0,
            mlTempBasal: 2.0,
            safetyTempBasal: 1.5,
            microBolusPhysiological: 0.2,
            microBolusSafety: 0.25,
            biologicalInvariant: -45 // This should trigger a violation
        )

        // Verify system stops insulin delivery during violation
        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        // Now test recovery when biological invariant returns to normal
        dose = await closedLoop.determineDose(
            settings: settings.snapshot(),
            physiologicalTempBasal: 1.0,
            mlTempBasal: 2.0,
            safetyTempBasal: 1.5,
            microBolusPhysiological: 0.2,
            microBolusSafety: 0.25,
            biologicalInvariant: -20 // Back to safe range
        )

        // Verify insulin delivery resumes
        #expect(dose.tempBasal > 0.0)
    }

    // MARK: - Property-Based Tests

    @Test func insulinCalculationsProperties() async throws {
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
                #expect(iob >= 0.0, "IOB should never be negative")

                // Property 2: IOB should never exceed total programmed insulin
                let maxPossibleInsulin = dose.programmedUnits
                #expect(iob <= maxPossibleInsulin, "IOB should not exceed total programmed insulin")

                // Property 3: IOB should be monotonically decreasing after delivery
                if timeOffset > duration {
                    let previousTime = checkTime.addingTimeInterval(-30.minutesToSeconds())
                    let previousIob = dose.insulinOnBoard(at: previousTime)
                    #expect(previousIob >= iob, "IOB should decrease monotonically after delivery")
                }
            }
        }
    }

    @Test func negativeBasalRateClampedToZero() async throws {
        let settings = MockSettingsStorage()
        let closedLoop = makeService(settings: settings)

        let result = await closedLoop.applyGuardrails(
            glucoseInMgDl: 120,
            predictedGlucoseInMgDl: 130,
            newBasalRateRaw: -0.5,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )

        #expect(abs(result - 0.0) <= iobAccuracy, "Negative basal rate should be clamped to zero")
    }

    @Test func shutOffBasalRateWhenCurrentGlucoseBelowThreshold() async throws {
        let settings = MockSettingsStorage()
        let closedLoop = makeService(settings: settings)
        settings.update(shutOffGlucoseInMgDl: 80.0)

        let result = await closedLoop.applyGuardrails(
            glucoseInMgDl: 75.0, // Below threshold
            predictedGlucoseInMgDl: 85.0, // Above threshold
            newBasalRateRaw: 1.0,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )

        #expect(abs(result - 0.0) <= iobAccuracy, "Basal rate should be zero when current glucose is below shutoff threshold")
    }

    @Test func shutOffBasalRateWhenPredictedGlucoseBelowThreshold() async throws {
        let settings = MockSettingsStorage()
        let closedLoop = makeService(settings: settings)
        settings.update(shutOffGlucoseInMgDl: 80.0)

        let result = await closedLoop.applyGuardrails(
            glucoseInMgDl: 85.0, // Above threshold
            predictedGlucoseInMgDl: 75.0, // Below threshold
            newBasalRateRaw: 1.0,
            settings: settings.snapshot(),
            roundToSupportedBasalRate: { $0 }
        )

        #expect(abs(result - 0.0) <= iobAccuracy, "Basal rate should be zero when predicted glucose is below shutoff threshold")
    }

    // MARK: - Tests for bugs we've found
    @Test func determineDoseActualTempBasalMatchesSelectedTempBasal() async throws {
        let settings = MockSettingsStorage()
        let closedLoop = makeService(settings: settings)
        settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        let dose = await closedLoop.determineDose(
            settings: settings.snapshot(),
            physiologicalTempBasal: 1.5, // This should be selected since ML is off
            mlTempBasal: 2.0,
            safetyTempBasal: 2.0,
            microBolusPhysiological: 0.0,
            microBolusSafety: 0.0,
            biologicalInvariant: -20
        )

        // Verify that the actual temp basal matches what was selected
        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy, "Selected temp basal should be physiological when ML is off")
        guard case .tempBasal(let selectedUnits) = dose else {
            Issue.record("Expected dose to be a temp basal decision")
            return
        }
        #expect(abs(selectedUnits - 1.5) <= iobAccuracy, "DosingDecision temp basal should match selected value")
    }
}
