//
//  MealDosingDataTypes.swift
//  BioKernel
//
//  The meal-dose arithmetic from dev/meal-announcements-from-ai-apps.md,
//  "Dosing basics" and "Run-to-run adaptations".
//
//  Pure, and deliberately storage-free: everything here takes the numbers it
//  needs as arguments so the rules can be tested directly, the way
//  `ClosedLoopDataTypes` holds the clamping and micro-bolus arithmetic for the
//  loop. `MealDosingService` is what gathers the inputs.
//
//  Two things this file does NOT do, both on purpose:
//
//   * It never rounds to a pump's supported bolus volumes. The doc's arithmetic
//     is in 0.05 U increments, which is the smallest increment the pumps we
//     support deliver, but "what this pump can actually give" is a question for
//     the delivery path — `MealAnnouncementView` rounds through the pump
//     manager immediately before enacting, exactly as `BolusView` does.
//
//   * It never clamps to `maxBolusUnits`. Same reason: that is a safety bound
//     applied at delivery, and folding it in here would silently hand back a
//     recommendation that isn't what the algorithm concluded.
//

import Foundation
import HealthKit
import LoopKit

enum MealDosingPolicy {
    /// The cold-start dose is this many hours of the user's peak basal rate.
    ///
    /// A first-time meal has no history to learn from, so the opening bid is
    /// framed in the person's own basal need — three hours of it, which is
    /// roughly how long a meal takes to finish absorbing. At a 0.6 U/h peak
    /// that is 1.8 U.
    ///
    /// **Peak basal rate, not `maxBasalRateUnitsPerHour`.** See
    /// `coldStartDose` — getting these two confused is a several-fold dosing
    /// error.
    static let usualDoseHours = 3.0

    /// How far one adjustment step is meant to move glucose, in mg/dL.
    ///
    /// A step is this much glucose turned into insulin through the person's own
    /// sensitivity, so what sets its size is their dose response and not the
    /// size of the dose being adjusted. A step as a fraction of the dose made
    /// the step on a big meal big and the step on a small meal too small to
    /// register, when a step has to be worth the same glucose either way.
    static let adjustmentGlucoseMgDl = 25.0

    /// The floor on any adjustment, and the increment every dose is snapped to.
    ///
    /// An adjustment of nothing means a meal that reads "dose more" every time
    /// never moves, so a step that rounds to zero is held here instead. This is
    /// the smallest increment the pumps we support can deliver, so it is also
    /// the smallest adjustment that could show up in the insulin history.
    static let minimumDoseIncrement = 0.05

    /// How far glucose has to climb from its level at the meal for the meal to
    /// read as under-dosed, in mg/dL.
    static let excursionThresholdMgDl = 80.0
}

/// What happened after a past instance of this meal, over its analysis window.
///
/// The two events are the doc's two rules, and each carries when it happened
/// because the earliest one wins — a meal can both predict a low and rise 80
/// mg/dL, and which came first is the difference between dosing less and
/// dosing more.
enum MealOutcome: Equatable {
    /// Glucose was predicted low inside the window, past the lead-in.
    case predictedLow(at: Date)
    /// Glucose rose more than `excursionThresholdMgDl` above where it started.
    case roseTooHigh(at: Date)
    /// Neither happened, over a window we could actually see.
    case onTarget
    /// We couldn't tell — no glucose at the meal, or no window left after a
    /// following meal cut it short. Distinct from `onTarget` because "nothing
    /// went wrong" and "we don't know" must not adjust a dose the same way.
    case unknown

    /// When the event fired, for ordering. Nil for the non-events.
    var at: Date? {
        switch self {
        case .predictedLow(let at): return at
        case .roseTooHigh(let at): return at
        case .onTarget, .unknown: return nil
        }
    }
}

/// The three amounts offered for a meal, plus why.
struct MealDoseRecommendation: Equatable {
    /// The algorithm's answer.
    let usual: Double
    /// One step either side of it. `less` never goes below zero.
    let less: Double
    let more: Double
    /// The distance from `usual` to either neighbour, in units.
    ///
    /// Carried rather than re-derived, so the Adjust card's +/- can move by the
    /// same amount without the view holding an insulin sensitivity of its own —
    /// two sources for one number is two numbers waiting to disagree.
    let step: Double
    /// The instance this was adapted from, and what it did. Nil on a meal we
    /// have never seen, which is what makes `usual` the cold-start dose.
    let reference: MealDoseReference?

    /// The amount for a tier.
    func units(for tier: MealDoseTier) -> Double {
        switch tier {
        case .less: return less
        case .usual: return usual
        case .more: return more
        }
    }
}

/// What the recommendation was adapted from — carried so the announcement view
/// can say *why* it is suggesting this number rather than presenting it bare.
struct MealDoseReference: Equatable {
    let startTime: Date
    let doseUnits: Double
    let outcome: MealOutcome
}

enum MealDoseTier: String, CaseIterable, Equatable {
    case less, usual, more
}

/// Which meal of the day an announcement lands in, for the dosing card's
/// eyebrow.
///
/// Presentation only — nothing in `MealDosing` reads it. Dosing history is
/// keyed on the description, not the slot, so two breakfasts that are
/// different plates stay different meals and the same plate eaten at midnight
/// still matches. Ported from ClueClue's `MealContext` so the same meal reads
/// with the same label in both apps.
enum MealSlot: String, Equatable {
    case breakfast, lunch, dinner, snack

    /// Uppercase, for the card eyebrow.
    var label: String {
        return rawValue.uppercased()
    }

    /// Local time, deliberately: the boundaries are about the person's day, so
    /// a meal eaten at 8am is breakfast wherever they happen to be.
    static func at(_ date: Date, calendar: Calendar = .current) -> MealSlot {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        switch minuteOfDay {
        case (6 * 60)..<(10 * 60): return .breakfast       // 06:00–09:59
        case (11 * 60 + 30)..<(14 * 60): return .lunch     // 11:30–13:59
        case (17 * 60)..<(21 * 60): return .dinner         // 17:00–20:59
        default: return .snack
        }
    }
}

enum MealDosing {

    // MARK: - Dosing basics

    /// The dose for a meal we have never seen: three hours of the person's
    /// peak basal rate.
    ///
    /// - Parameter peakBasalRateUnitsPerHour: the highest rate in the person's
    ///   own basal schedule — `CodableSettings.maxBasalRate()`, which takes the
    ///   maximum across the ML-learned schedule and falls back to the pump
    ///   basal rate when no schedule has been learned yet.
    ///
    /// **Do not pass `settings.maxBasalRateUnitsPerHour` here.** That setting
    /// is a *safety guardrail* — the ceiling `SafetyService` clamps delivery
    /// to, deliberately set well above any rate the person actually runs. It
    /// is not a therapy number and it is not what the design doc's
    /// "maxHourlyBasalRate" means.
    ///
    /// The two differ by a lot, and in the dangerous direction. On the shipped
    /// defaults the guardrail is 2.0 U/h against a 0.3 U/h pump basal rate: a
    /// cold-start meal dose of 6.0 U where it should be 0.9 U. This function
    /// takes a bare `Double` and cannot tell them apart, which is exactly why
    /// the distinction is written down here — it was got wrong once already.
    static func coldStartDose(peakBasalRateUnitsPerHour: Double) -> Double {
        let dose = MealDosingPolicy.usualDoseHours * peakBasalRateUnitsPerHour
        return max(0, dose).rounded(toNearest: MealDosingPolicy.minimumDoseIncrement)
    }

    /// One adjustment step, in units: the insulin that moves this person's
    /// glucose by `adjustmentGlucoseMgDl`.
    ///
    /// The same number does two jobs, which is why it is one function. It is
    /// the gap between `less`, `usual` and `more` on the announcement view, and
    /// it is how far a run-to-run adjustment moves the dose. Keeping them
    /// identical means "dose more" lands exactly where the user would have
    /// landed by tapping `more` themselves.
    ///
    /// It does not scale with the dose. The tiers on a 1 U breakfast and a 6 U
    /// dinner sit the same distance apart, because the mistake a step is
    /// correcting is a glucose miss, and a 40 mg/dL overshoot needs the same
    /// insulin whichever plate produced it.
    ///
    /// - Parameter insulinSensitivityMgDlPerUnit: how far one unit moves this
    ///   person's glucose — `CodableSettings.learnedInsulinSensitivity(at:)`,
    ///   which reads the ML-learned schedule and falls back to the sensitivity
    ///   they set by hand. A non-positive value is not something to divide by,
    ///   so it takes the floor rather than returning an infinite step.
    static func adjustment(insulinSensitivityMgDlPerUnit: Double) -> Double {
        guard insulinSensitivityMgDlPerUnit > 0 else { return MealDosingPolicy.minimumDoseIncrement }
        let insulinToMove = MealDosingPolicy.adjustmentGlucoseMgDl / insulinSensitivityMgDlPerUnit
        return max(insulinToMove, MealDosingPolicy.minimumDoseIncrement)
            .rounded(toNearest: MealDosingPolicy.minimumDoseIncrement)
    }

    /// Wraps a `usual` dose in its two neighbours.
    static func tiers(
        usual: Double,
        insulinSensitivityMgDlPerUnit: Double,
        reference: MealDoseReference? = nil
    ) -> MealDoseRecommendation {
        let snapped = max(0, usual).rounded(toNearest: MealDosingPolicy.minimumDoseIncrement)
        let delta = adjustment(insulinSensitivityMgDlPerUnit: insulinSensitivityMgDlPerUnit)
        return MealDoseRecommendation(
            usual: snapped,
            // A dose can't be negative, and `less` on a 0.05 U usual would be.
            less: max(0, snapped - delta).rounded(toNearest: MealDosingPolicy.minimumDoseIncrement),
            more: (snapped + delta).rounded(toNearest: MealDosingPolicy.minimumDoseIncrement),
            step: delta,
            reference: reference
        )
    }

    // MARK: - Run-to-run adaptations

    /// The recommendation for a meal, given the last instance of it we can
    /// learn from.
    ///
    /// The new `usual` is a step off *last time's* dose, not off the cold-start
    /// baseline. That is what lets a meal walk to the right number over a few
    /// repeats instead of oscillating one step either side of a fixed guess
    /// forever.
    ///
    /// `.onTarget` and `.unknown` both hold the dose. They differ in what they
    /// mean, not in what they do here — one is "this dose worked", the other is
    /// "we couldn't see", and neither is evidence for moving.
    /// - Parameter peakBasalRateUnitsPerHour: only consulted on a meal we have
    ///   never seen. See `coldStartDose` for which setting this is, and which
    ///   one it must not be.
    /// - Parameter insulinSensitivityMgDlPerUnit: sets the size of the step,
    ///   for both the adjustment and the tiers around it. See `adjustment`.
    static func recommendation(
        reference: (startTime: Date, doseUnits: Double, outcome: MealOutcome)?,
        peakBasalRateUnitsPerHour: Double,
        insulinSensitivityMgDlPerUnit: Double
    ) -> MealDoseRecommendation {
        guard let reference else {
            return tiers(
                usual: coldStartDose(peakBasalRateUnitsPerHour: peakBasalRateUnitsPerHour),
                insulinSensitivityMgDlPerUnit: insulinSensitivityMgDlPerUnit
            )
        }

        let previous = reference.doseUnits
        let delta = adjustment(insulinSensitivityMgDlPerUnit: insulinSensitivityMgDlPerUnit)
        let usual: Double
        switch reference.outcome {
        case .predictedLow:
            usual = previous - delta
        case .roseTooHigh:
            usual = previous + delta
        case .onTarget, .unknown:
            usual = previous
        }

        return tiers(
            usual: usual,
            insulinSensitivityMgDlPerUnit: insulinSensitivityMgDlPerUnit,
            reference: MealDoseReference(
                startTime: reference.startTime,
                doseUnits: previous,
                outcome: reference.outcome
            )
        )
    }

    // MARK: - Reading a past window

    /// The end of a meal's analysis window: 3.5 hours, cut short by the next
    /// meal and by the present.
    ///
    /// - Parameter nextMealStart: the start of the first meal after this one,
    ///   whatever it was. Any meal truncates the window, not just another
    ///   instance of the same one — the point is that glucose after someone
    ///   else's plate says nothing about this dose.
    /// - Parameter now: a window that hasn't finished yet is analyzed as far as
    ///   it has got. Partial evidence can only fail to find an event, so the
    ///   worst it does is hold the dose steady for one more repeat.
    static func windowEnd(startTime: Date, nextMealStart: Date?, now: Date) -> Date {
        var end = startTime + MealRecordStorePolicy.postMealWindow
        if let nextMealStart, nextMealStart > startTime, nextMealStart < end {
            end = nextMealStart
        }
        return min(end, now)
    }

    /// Classifies what happened over one past meal's window.
    ///
    /// - Parameter readings: every CGM reading from `predictionLookback` before
    ///   the meal through the end of the window. The lead-in matters: the
    ///   predicted-low replay at an instant needs the half hour of readings
    ///   before it, so a window's first prediction depends on readings from
    ///   before the window opened.
    /// - Parameter lowThresholdMgDl: the user's own low alert level. A
    ///   prediction at or below it is the same event that would have notified
    ///   them at the time.
    static func outcome(
        startTime: Date,
        windowEnd: Date,
        readings: [NewGlucoseSample],
        lowThresholdMgDl: Double
    ) -> MealOutcome {
        guard windowEnd > startTime else { return .unknown }

        let sorted = readings.sorted { $0.date < $1.date }

        // Where glucose stood when the meal started: the last reading at or
        // before it. A reading *after* the meal is not a baseline — digestion
        // has already begun, so measuring the excursion from it understates
        // the rise by however much happened first.
        guard let baseline = sorted.last(where: { $0.date <= startTime }) else { return .unknown }
        let baselineMgDl = baseline.quantity.doubleValue(for: .milligramsPerDeciliter)

        let inWindow = sorted.filter { $0.date > startTime && $0.date <= windowEnd }
        guard !inWindow.isEmpty else { return .unknown }

        // Rule 1: the earliest reading more than 80 mg/dL above the baseline.
        // The doc frames this as "the max over the window rises by more than
        // 80", and the first crossing is when that became true — which is what
        // the earliest-event-wins tie-break needs.
        let excursion = inWindow.first {
            $0.quantity.doubleValue(for: .milligramsPerDeciliter) - baselineMgDl > MealDosingPolicy.excursionThresholdMgDl
        }

        // Rule 2: the earliest predicted low past the lead-in, replaying the
        // same prediction the low alert uses at each CGM tick — which is where
        // it would have run in production.
        let leadIn = startTime + MealRecordStorePolicy.lowPredictionLeadIn
        let predictedLow = inWindow.first { reading in
            guard reading.date >= leadIn else { return false }
            guard let predicted = LocalPhysiologicalModels.predictGlucoseIn15Minutes(
                from: reading.date,
                readings: sorted
            ) else { return false }
            return predicted <= lowThresholdMgDl
        }

        // Earliest event wins.
        switch (predictedLow, excursion) {
        case (nil, nil):
            return .onTarget
        case (let low?, nil):
            return .predictedLow(at: low.date)
        case (nil, let high?):
            return .roseTooHigh(at: high.date)
        case (let low?, let high?):
            return low.date <= high.date
                ? .predictedLow(at: low.date)
                : .roseTooHigh(at: high.date)
        }
    }
}
