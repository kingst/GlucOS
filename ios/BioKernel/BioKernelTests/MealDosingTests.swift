//
//  MealDosingTests.swift
//  BioKernelTests
//
//  The dosing arithmetic and the run-to-run rules from
//  dev/meal-announcements-from-ai-apps.md.
//
//  All of it is pure, so these tests state the doc's rules as numbers: the
//  cold-start dose, the increment, the two events that move a dose, which one
//  wins when both fire, and what truncates the window.
//

import Testing
import Foundation
import HealthKit
import LoopKit
@testable import BioKernel

struct MealDosingTests {

    let now = Date.f("2026-03-14 12:00:00 +0000")

    /// A flat CGM trace: one reading every five minutes at a fixed level.
    func flat(from: Date, to: Date, mgDl: Double) -> [NewGlucoseSample] {
        return series(from: from, to: to) { _ in mgDl }
    }

    /// A trace whose level is a function of minutes since `from`.
    func series(from: Date, to: Date, mgDl: (Double) -> Double) -> [NewGlucoseSample] {
        var readings: [NewGlucoseSample] = []
        var at = from
        while at <= to {
            let minutes = at.timeIntervalSince(from) / 60
            readings.append(GlucoseFixtures.reading(
                id: "r-\(Int(minutes))",
                at: at,
                mgDl: mgDl(minutes)
            ))
            at = at + 5.0.minutesToSeconds()
        }
        return readings
    }

    // MARK: - Dosing basics

    @Test func aMealWeHaveNeverSeenGetsThreeHoursOfPeakBasal() throws {
        // The doc's worked example: 0.6 U/h peak basal → 1.8 U.
        #expect(MealDosing.coldStartDose(peakBasalRateUnitsPerHour: 0.6) == 1.8)
        #expect(MealDosing.coldStartDose(peakBasalRateUnitsPerHour: 2.0) == 6.0)
    }

    // MARK: - Which basal rate the cold start reads

    /// The peak of the learned schedule wins, and the safety guardrail is
    /// nowhere in it.
    ///
    /// `coldStartDose` takes a bare `Double`, so nothing in its signature can
    /// stop a caller passing `maxBasalRateUnitsPerHour` — the guardrail
    /// `SafetyService` clamps against. These tests are the guard, because the
    /// mistake is invisible at the call site and several-fold in the dose.
    @Test func theColdStartDoseComesFromTheLearnedScheduleNotTheGuardrail() throws {
        let settings = Self.settings(
            pumpBasalRateUnitsPerHour: 0.3,
            maxBasalRateUnitsPerHour: 2.0,          // the guardrail
            learnedBasalRates: [0.4, 0.55, 0.6, 0.5, 0.45, 0.35]
        )

        #expect(settings.maxBasalRate() == 0.6)
        // 3h * 0.6 = 1.8, not 3h * 2.0 = 6.0.
        #expect(MealDosing.coldStartDose(peakBasalRateUnitsPerHour: settings.maxBasalRate()) == 1.8)
    }

    @Test func withNoLearnedScheduleTheColdStartDoseFallsBackToThePumpBasalRate() throws {
        // What a fresh install looks like: nothing learned yet, and the pump
        // basal rate is the backup the person set themselves.
        let settings = Self.settings(
            pumpBasalRateUnitsPerHour: 0.3,
            maxBasalRateUnitsPerHour: 2.0,
            learnedBasalRates: nil
        )

        #expect(settings.maxBasalRate() == 0.3)
        #expect(MealDosing.coldStartDose(peakBasalRateUnitsPerHour: settings.maxBasalRate()) == 0.9)
    }

    @Test func aPartlyLearnedScheduleUsesTheSlotsItHas() throws {
        // The schedule fills in a slot at a time, so most of it is nil for a
        // while. A missing slot is not a rate of zero.
        let settings = Self.settings(
            pumpBasalRateUnitsPerHour: 0.3,
            maxBasalRateUnitsPerHour: 2.0,
            learnedBasalRates: [nil, nil, 0.5, nil, nil, nil]
        )

        #expect(settings.maxBasalRate() == 0.5)
        #expect(MealDosing.coldStartDose(peakBasalRateUnitsPerHour: settings.maxBasalRate()) == 1.5)
    }

    @Test func theGuardrailNeverRaisesTheColdStartDose() throws {
        // The whole point, stated once more as a range: whatever the guardrail
        // is set to, it must not move the dose.
        for guardrail in [1.0, 2.0, 10.0, 30.0] {
            let settings = Self.settings(
                pumpBasalRateUnitsPerHour: 0.3,
                maxBasalRateUnitsPerHour: guardrail,
                learnedBasalRates: [0.4, 0.55, 0.6, 0.5, 0.45, 0.35]
            )
            #expect(MealDosing.coldStartDose(peakBasalRateUnitsPerHour: settings.maxBasalRate()) == 1.8)
        }
    }

    /// Settings with just the three basal numbers that matter here; everything
    /// else is the shipped default.
    static func settings(
        pumpBasalRateUnitsPerHour: Double,
        maxBasalRateUnitsPerHour: Double,
        learnedBasalRates: [Double?]?
    ) -> CodableSettings {
        let schedule: LearnedSettingsSchedule = {
            guard let rates = learnedBasalRates else { return .empty() }
            return LearnedSettingsSchedule(
                midnightToFour: rates[0],
                fourToEight: rates[1],
                eightToTwelve: rates[2],
                twelveToSixteen: rates[3],
                sixteenToTwenty: rates[4],
                twentyToTwentyFour: rates[5]
            )
        }()
        let defaults = CodableSettings.defaults()
        return CodableSettings(
            created: defaults.created,
            pumpBasalRateUnitsPerHour: pumpBasalRateUnitsPerHour,
            insulinSensitivityInMgDlPerUnit: defaults.insulinSensitivityInMgDlPerUnit,
            maxBasalRateUnitsPerHour: maxBasalRateUnitsPerHour,
            maxBolusUnits: defaults.maxBolusUnits,
            shutOffGlucoseInMgDl: defaults.shutOffGlucoseInMgDl,
            targetGlucoseInMgDl: defaults.targetGlucoseInMgDl,
            closedLoopEnabled: defaults.closedLoopEnabled,
            useMachineLearningClosedLoop: defaults.useMachineLearningClosedLoop,
            useMicroBolus: defaults.isMicroBolusEnabled(),
            microBolusDoseFactor: defaults.getMicroBolusDoseFactor(),
            learnedBasalRateUnitsPerHour: schedule,
            learnedInsulinSensitivityInMgDlPerUnit: .empty(),
            bolusAmountForLess: defaults.getBolusAmountForLess(),
            bolusAmountForUsual: defaults.getBolusAmountForUsual(),
            bolusAmountForMore: defaults.getBolusAmountForMore(),
            pidIntegratorGain: defaults.getPidIntegratorGain(),
            pidDerivativeGain: defaults.getPidDerivativeGain(),
            useBiologicalInvariant: defaults.isBiologicalInvariantEnabled(),
            machineLearningGain: defaults.getMachineLearningGain()
        )
    }

    @Test func theAdjustmentIsTheInsulinThatMovesGlucose25() throws {
        // 25 / 50 = 0.50 U for someone one unit moves 50 mg/dL.
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: 50) == 0.50)
        // 25 / 45 = 0.5555…, which snaps to 0.55.
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: 45) == 0.55)
        // The more sensitive the person, the smaller the step: 25 / 100 = 0.25.
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: 100) == 0.25)
        // 25 / 20 = 1.25 for someone insulin-resistant enough to need it.
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: 20) == 1.25)
    }

    @Test func aSensitivityWeCannotDivideByTakesTheFloor() throws {
        // Not a number the settings screen can produce — its picker starts at
        // 10 — but `adjustment` takes a bare Double, and a step of infinity or
        // of nothing are both worse than the smallest dose the pump can give.
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: 0) == 0.05)
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: -45) == 0.05)
        // And a sensitivity high enough to round the step away: 25 / 5000 is
        // 0.005 U, under the increment, so the increment wins. Without the
        // floor this dose could never move.
        #expect(MealDosing.adjustment(insulinSensitivityMgDlPerUnit: 5000) == 0.05)
    }

    @Test func theStepDoesNotScaleWithTheDose() throws {
        // The old rule was 10% of the dose, which made a 6 U dinner move six
        // times as far as a 1 U snack for the same 40 mg/dL miss. One
        // sensitivity, one step, whatever is on the plate.
        let small = MealDosing.tiers(usual: 1.0, insulinSensitivityMgDlPerUnit: 50)
        let large = MealDosing.tiers(usual: 6.0, insulinSensitivityMgDlPerUnit: 50)

        #expect(small.step == 0.50)
        #expect(large.step == 0.50)
        #expect(small.more - small.usual == large.more - large.usual)
    }

    @Test func lessAndMoreSitOneStepEitherSide() throws {
        let tiers = MealDosing.tiers(usual: 1.8, insulinSensitivityMgDlPerUnit: 50)

        #expect(tiers.usual == 1.8)
        #expect(tiers.less == 1.3)
        #expect(tiers.more == 2.3)
        #expect(tiers.step == 0.5)
        #expect(tiers.units(for: .less) == tiers.less)
        #expect(tiers.units(for: .usual) == tiers.usual)
        #expect(tiers.units(for: .more) == tiers.more)
    }

    @Test func lessNeverGoesNegative() throws {
        // A 0.05 U usual would put `less` below zero, which is not a dose.
        let tiers = MealDosing.tiers(usual: 0.05, insulinSensitivityMgDlPerUnit: 50)

        #expect(tiers.less == 0)
        #expect(tiers.usual == 0.05)
        #expect(tiers.more == 0.55)
    }

    @Test func everyAmountLandsOnTheIncrement() throws {
        // A max basal rate that doesn't divide evenly (3h * 0.43 = 1.29) and a
        // sensitivity that doesn't either (25 / 45 = 0.5555…).
        let tiers = MealDosing.tiers(
            usual: MealDosing.coldStartDose(peakBasalRateUnitsPerHour: 0.43),
            insulinSensitivityMgDlPerUnit: 45
        )

        for amount in [tiers.less, tiers.usual, tiers.more, tiers.step] {
            let steps = amount / MealDosingPolicy.minimumDoseIncrement
            #expect(steps.roughlyEqual(to: steps.rounded()), "\(amount) is not a multiple of the increment")
        }
    }

    // MARK: - Run-to-run adaptations

    @Test func aFirstTimeMealHasNoReference() throws {
        let recommendation = MealDosing.recommendation(
            reference: nil,
            peakBasalRateUnitsPerHour: 0.6,
            insulinSensitivityMgDlPerUnit: 50
        )

        #expect(recommendation.usual == 1.8)
        #expect(recommendation.reference == nil)
        // Even with no history, the tiers are a sensitivity apart.
        #expect(recommendation.less == 1.3)
        #expect(recommendation.more == 2.3)
    }

    @Test func aPredictedLowDosesLess() throws {
        let recommendation = MealDosing.recommendation(
            reference: (startTime: now, doseUnits: 3.0, outcome: .predictedLow(at: now + 3600)),
            peakBasalRateUnitsPerHour: 0.6,
            insulinSensitivityMgDlPerUnit: 50
        )

        // 25 / 50 = 0.50 off last time's 3.0.
        #expect(recommendation.usual == 2.5)
        #expect(recommendation.reference?.doseUnits == 3.0)
    }

    @Test func anExcursionDosesMore() throws {
        let recommendation = MealDosing.recommendation(
            reference: (startTime: now, doseUnits: 3.0, outcome: .roseTooHigh(at: now + 3600)),
            peakBasalRateUnitsPerHour: 0.6,
            insulinSensitivityMgDlPerUnit: 50
        )

        #expect(recommendation.usual == 3.5)
    }

    @Test func anAdjustmentLandsWhereTappingTheTierWouldHave() throws {
        // The doc's reason for one step doing both jobs: "dose more" has to
        // put the number where the user would have put it themselves.
        let reference = (startTime: now, doseUnits: 3.0, outcome: MealOutcome.roseTooHigh(at: now + 3600))
        let adapted = MealDosing.recommendation(
            reference: reference,
            peakBasalRateUnitsPerHour: 0.6,
            insulinSensitivityMgDlPerUnit: 45
        )
        let lastTimesTiers = MealDosing.tiers(usual: 3.0, insulinSensitivityMgDlPerUnit: 45)

        #expect(adapted.usual == lastTimesTiers.more)
    }

    @Test func aMealThatHeldKeepsItsDose() throws {
        for outcome in [MealOutcome.onTarget, MealOutcome.unknown] {
            let recommendation = MealDosing.recommendation(
                reference: (startTime: now, doseUnits: 3.0, outcome: outcome),
                peakBasalRateUnitsPerHour: 0.6,
                insulinSensitivityMgDlPerUnit: 50
            )
            #expect(recommendation.usual == 3.0)
        }
    }

    @Test func adjustmentsStepOffTheLastDose() throws {
        // Five repeats that each read "dose more". Each step is off *last
        // time's* dose, which is what walks the meal to the right number; a
        // step off a fixed baseline would sit at 2.3 forever no matter how many
        // times it read high.
        var dose = 1.8
        for _ in 0..<5 {
            dose = MealDosing.recommendation(
                reference: (startTime: now, doseUnits: dose, outcome: .roseTooHigh(at: now + 3600)),
                peakBasalRateUnitsPerHour: 0.6,
                insulinSensitivityMgDlPerUnit: 50
            ).usual
        }

        #expect(dose == 4.3)
        // And back down again, so nothing here is a one-way ratchet. A fixed
        // step retraces exactly, which a percentage of a moving dose did not.
        for _ in 0..<5 {
            dose = MealDosing.recommendation(
                reference: (startTime: now, doseUnits: dose, outcome: .predictedLow(at: now + 3600)),
                peakBasalRateUnitsPerHour: 0.6,
                insulinSensitivityMgDlPerUnit: 50
            ).usual
        }
        #expect(dose == 1.8)
    }

    // MARK: - The analysis window

    @Test func theWindowIsThreeAndAHalfHours() throws {
        let end = MealDosing.windowEnd(startTime: now, nextMealStart: nil, now: now + 1.0.daysToSeconds())
        #expect(end == now + 3.5.hoursToSeconds())
    }

    @Test func aFollowingMealCutsTheWindowShort() throws {
        let next = now + 2.0.hoursToSeconds()
        let end = MealDosing.windowEnd(startTime: now, nextMealStart: next, now: now + 1.0.daysToSeconds())

        // Glucose after someone else's plate says nothing about this dose.
        #expect(end == next)
    }

    @Test func aFollowingMealPastTheWindowChangesNothing() throws {
        let next = now + 5.0.hoursToSeconds()
        let end = MealDosing.windowEnd(startTime: now, nextMealStart: next, now: now + 1.0.daysToSeconds())

        #expect(end == now + 3.5.hoursToSeconds())
    }

    @Test func aWindowThatHasNotFinishedIsAnalyzedAsFarAsItHasGot() throws {
        let end = MealDosing.windowEnd(startTime: now, nextMealStart: nil, now: now + 1.0.hoursToSeconds())
        #expect(end == now + 1.0.hoursToSeconds())
    }

    // MARK: - Classifying a window

    @Test func aFlatWindowHeld() throws {
        let readings = flat(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds(), mgDl: 120)
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        #expect(outcome == .onTarget)
    }

    @Test func aRiseOverEightyReadsAsUnderDosed() throws {
        // 120 at the meal, climbing 1 mg/dL a minute: it crosses +80 at 81
        // minutes, and the first reading past that is at 85.
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            let sinceMeal = minutes - 30
            return sinceMeal <= 0 ? 120 : 120 + sinceMeal
        }
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        guard case .roseTooHigh(let at) = outcome else {
            Issue.record("expected an excursion, got \(outcome)")
            return
        }
        #expect(at == now + 85.0.minutesToSeconds())
    }

    @Test func exactlyEightyIsNotAnExcursion() throws {
        // The doc says "more than 80", so the boundary belongs to "held".
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            return minutes <= 30 ? 120 : 200
        }
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        #expect(outcome == .onTarget)
    }

    @Test func aPredictedLowInsideTheWindowReadsAsOverDosed() throws {
        // Falling 1 mg/dL a minute from 200 at the meal. The prediction is a
        // 15-minute linear extrapolation, so it goes under 70 well before
        // glucose does.
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            let sinceMeal = minutes - 30
            return sinceMeal <= 0 ? 200 : max(40, 200 - sinceMeal)
        }
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        guard case .predictedLow(let at) = outcome else {
            Issue.record("expected a predicted low, got \(outcome)")
            return
        }
        // Past the lead-in, which is the whole point of having one.
        #expect(at >= now + MealRecordStorePolicy.lowPredictionLeadIn)
    }

    @Test func aPredictedLowBeforeTheLeadInIsIgnored() throws {
        // Glucose dives for the first half hour, then sits flat and in range.
        // That low is the *previous* meal's insulin finishing, and reading it
        // as this meal's outcome would walk this dose down for something it
        // didn't cause.
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            let sinceMeal = minutes - 30
            if sinceMeal <= 0 { return 120 }
            if sinceMeal <= 30 { return max(75, 120 - sinceMeal * 1.5) }
            return 120
        }
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        #expect(outcome == .onTarget)
    }

    @Test func theEarliestEventWinsWhenBothFire() throws {
        // Up 100 in the first hour, then a dive steep enough to predict a low.
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            let sinceMeal = minutes - 30
            if sinceMeal <= 0 { return 120 }
            if sinceMeal <= 60 { return 120 + sinceMeal * 2 }
            return max(50, 240 - (sinceMeal - 60) * 2)
        }
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        // The rise crossed +80 at 45 minutes, before the low was ever
        // predicted, so this meal was under-dosed and the low that followed is
        // the excursion coming down.
        guard case .roseTooHigh(let at) = outcome else {
            Issue.record("expected the earlier excursion to win, got \(outcome)")
            return
        }
        #expect(at < now + 1.0.hoursToSeconds())
    }

    @Test func noGlucoseAtTheMealIsUnknownRatherThanOnTarget() throws {
        // Readings start half an hour *after* the meal — a sensor warm-up, or a
        // phone that was off. There is no baseline to measure an excursion
        // from, and "we couldn't see" must not read as "this dose worked".
        let readings = flat(from: now + 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds(), mgDl: 120)
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        #expect(outcome == .unknown)
    }

    @Test func noReadingsInTheWindowIsUnknown() throws {
        let readings = flat(from: now - 30.0.minutesToSeconds(), to: now, mgDl: 120)
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        #expect(outcome == .unknown)
    }

    @Test func aWindowWithNoWidthIsUnknown() throws {
        let readings = flat(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds(), mgDl: 120)
        // Two meals announced at the same instant leave nothing to analyze.
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now,
            readings: readings,
            lowThresholdMgDl: 70
        )

        #expect(outcome == .unknown)
    }

    @Test func theBaselineIsTheReadingAtTheMealNotAfterIt() throws {
        // 100 at the meal, already at 150 five minutes later. Measuring the
        // excursion from 150 would understate the rise by the 50 that happened
        // first, and this window would read as held.
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            let sinceMeal = minutes - 30
            if sinceMeal <= 0 { return 100 }
            return 150 + min(sinceMeal, 40)
        }
        let outcome = MealDosing.outcome(
            startTime: now,
            windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings,
            lowThresholdMgDl: 70
        )

        guard case .roseTooHigh = outcome else {
            Issue.record("expected an excursion off the 100 baseline, got \(outcome)")
            return
        }
    }

    @Test func theLowThresholdIsTheUsersOwn() throws {
        // The same trace against two alert levels. Run-to-run adaptation reads
        // the level the user set, so a user who alerts at 90 learns from lows a
        // user who alerts at 60 never sees.
        // Falls 1 mg/dL a minute from 140 and settles at 80. The 15-minute
        // extrapolation therefore bottoms out around 65 — comfortably under a
        // 100 threshold and comfortably over a 50 one.
        let readings = series(from: now - 30.0.minutesToSeconds(), to: now + 3.5.hoursToSeconds()) { minutes in
            let sinceMeal = minutes - 30
            return sinceMeal <= 0 ? 140 : max(80, 140 - sinceMeal)
        }

        let atOneHundred = MealDosing.outcome(
            startTime: now, windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings, lowThresholdMgDl: 100
        )
        let atFifty = MealDosing.outcome(
            startTime: now, windowEnd: now + 3.5.hoursToSeconds(),
            readings: readings, lowThresholdMgDl: 50
        )

        guard case .predictedLow = atOneHundred else {
            Issue.record("expected a predicted low at a 100 threshold, got \(atOneHundred)")
            return
        }
        // The same trace, and nothing to learn from: this user was never
        // going to be told about it.
        #expect(atFifty == .onTarget)
    }
}
