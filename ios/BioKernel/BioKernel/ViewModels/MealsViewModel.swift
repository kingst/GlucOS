//
//  MealsViewModel.swift
//  BioKernel
//
//  Models for the three meal surfaces: the 90-day list, one meal's window, and
//  the dose the announcement view offers.
//
//  `ObservableObject` with `@Published`, matching `DiagnosticViewModel` and
//  `GlucoseAlertsViewModel` rather than introducing a second observation style
//  into this app. All three load once on appear — these are records of things
//  that already happened, not live monitors, so there is nothing here that has
//  to keep up with a CGM tick.
//

import Combine
import Foundation
import HealthKit
import LoopKit

// MARK: - The meal list

/// One day of the list, for a section.
struct MealDayGroup: Identifiable, Sendable {
    /// Midnight local, which is both the section's identity and what its
    /// header is formatted from.
    let day: Date
    var meals: [StoredMeal]

    var id: Date { return day }
}

@MainActor
final class MealsViewModel: ObservableObject {
    @Published var meals: [StoredMeal] = []
    /// Held so the list can say "nothing yet" without flashing it during the
    /// first read.
    @Published var hasLoaded = false

    private let mealStorage: MealStorage

    init(mealStorage: MealStorage) {
        self.mealStorage = mealStorage
    }

    /// The list cut into day sections, newest day first — 90 days of meals as
    /// a flat list is a wall of rows, and the date on every one of them only
    /// repeats what the row above already said.
    var mealsByDay: [MealDayGroup] {
        return Self.groupedByDay(meals)
    }

    /// Pure, so the grouping is testable without a store.
    ///
    /// Walks the list in its existing order rather than sorting: `recentMeals`
    /// hands back newest first, and a section boundary is just a row whose day
    /// differs from the one above it. That also means the sections inherit
    /// whatever order the store used, so there is one answer to "what comes
    /// first" rather than two that can disagree.
    nonisolated static func groupedByDay(
        _ meals: [StoredMeal],
        calendar: Calendar = .current
    ) -> [MealDayGroup] {
        var groups: [MealDayGroup] = []
        for meal in meals {
            let day = calendar.startOfDay(for: meal.startTime)
            if let last = groups.last, last.day == day {
                groups[groups.count - 1].meals.append(meal)
            } else {
                groups.append(MealDayGroup(day: day, meals: [meal]))
            }
        }
        return groups
    }

    func load(now: Date = Date()) async {
        // Ingest before reading, so "show me my meals" means the files and not
        // whatever the last loop tick happened to have copied. The app-level
        // ingest (launch and foreground) covers the usual way a meal gets here,
        // but doing it here too makes the list self-consistent however the user
        // arrived — including a session long enough for a new announcement to
        // land while the app stayed open. Idempotent, so the overlap costs a
        // file read.
        await mealStorage.ingest(at: now)
        meals = await mealStorage.recentMeals(at: now)
        hasLoaded = true
    }
}

// MARK: - One meal's window

/// A glucose reading reduced to what the chart plots. `NewGlucoseSample`
/// carries a `HKQuantity` and a device, and neither belongs in a `ForEach`.
struct MealGlucosePoint: Hashable {
    let at: Date
    let glucoseInMgDl: Double
}

struct MealIobSample: Hashable {
    let at: Date
    let units: Double
}

/// One row in the window's "what happened" timeline, and one marker on the
/// chart.
///
/// Three cases, which is what GlucOS can actually say about a past window:
/// the meal, the boluses the pump delivered, and the run-to-run outcome. The
/// outcome stands in for what ClueClue shows as a glucose-alert row — GlucOS
/// does not persist its predicted-low alerts, but `MealDosing.outcome`
/// recomputes the same event from stored glucose, and unlike a notification it
/// is the *reason the next dose moves*, which is what this screen is for.
///
/// Basal is deliberately absent. It runs continuously and the loop adjusts it
/// for reasons that have nothing to do with the meal, so a row per temp basal
/// would bury the three events that matter. The IOB curve already shows what
/// basal did to the picture.
enum MealWindowEvent: Identifiable {
    case meal(StoredMeal)
    case bolus(at: Date, units: Double, isAutomatic: Bool)
    case outcome(MealOutcome, at: Date)

    var id: String {
        switch self {
        case .meal(let meal): return "meal-\(meal.id)"
        case .bolus(let at, let units, _): return "bolus-\(at.timeIntervalSince1970)-\(units)"
        case .outcome(_, let at): return "outcome-\(at.timeIntervalSince1970)"
        }
    }

    var at: Date {
        switch self {
        case .meal(let meal): return meal.startTime
        case .bolus(let at, _, _): return at
        case .outcome(_, let at): return at
        }
    }

    /// Whether the event gets a rule and a glyph on the chart's marker rail.
    ///
    /// Automatic boluses don't. A closed loop can micro-bolus every five
    /// minutes, so on a normal window they arrive as a row of syringes across
    /// the top of the chart that buries the two events the screen is actually
    /// about — the meal and the outcome. They keep their row in the timeline
    /// below, where a list has room for them, and the chart marks them as
    /// beads on the glucose trace instead.
    var hasChartMarker: Bool {
        switch self {
        case .meal, .outcome: return true
        case .bolus(_, _, let isAutomatic): return !isAutomatic
        }
    }

    /// Sort order for events sharing an instant: meal, then bolus, then
    /// outcome — the order you would narrate them.
    var tieBreakRank: Int {
        switch self {
        case .meal: return 0
        case .bolus: return 1
        case .outcome: return 2
        }
    }

    var iconName: String {
        switch self {
        case .meal: return "fork.knife"
        case .bolus: return "syringe.fill"
        case .outcome(let outcome, _):
            switch outcome {
            case .predictedLow: return "arrow.down.right"
            case .roseTooHigh: return "arrow.up.right"
            case .onTarget, .unknown: return "equal"
            }
        }
    }

    var title: String {
        switch self {
        case .meal(let meal): return meal.mealDescription
        case .bolus(_, let units, let isAutomatic):
            let amount = String(format: "%0.2f", units)
            // Named, because the difference matters when reading a window: a
            // micro-bolus is the loop correcting, not the person dosing for
            // the meal.
            return isAutomatic ? "\(amount)U automatic" : "\(amount)U bolus"
        case .outcome(let outcome, _):
            switch outcome {
            case .predictedLow: return "Predicted low"
            case .roseTooHigh: return "Glucose above target"
            case .onTarget: return "Held"
            case .unknown: return "Not enough data"
            }
        }
    }

    var detail: String? {
        switch self {
        case .meal, .bolus: return nil
        case .outcome(let outcome, _):
            switch outcome {
            case .predictedLow: return "Next time this meal doses less"
            case .roseTooHigh:
                return "Rose over \(Int(MealDosingPolicy.excursionThresholdMgDl)) mg/dL · next time this meal doses more"
            case .onTarget, .unknown: return nil
            }
        }
    }

    /// A pill on the row, for the outcome only.
    var badge: String? {
        switch self {
        case .meal, .bolus: return nil
        case .outcome(let outcome, _):
            switch outcome {
            case .predictedLow: return "Low"
            case .roseTooHigh: return "High"
            case .onTarget, .unknown: return nil
            }
        }
    }
}

/// Everything the window chart and the facts beneath it render.
struct MealWindowData {
    let start: Date
    let end: Date
    /// Where the counted window ends: 3.5 hours, cut short by the next meal
    /// and by the present. Always inside `start...end`, which stays the full
    /// width so two windows are the same size on screen.
    let analysisEnd: Date
    let glucose: [MealGlucosePoint]
    let iob: [MealIobSample]
    /// Total insulin the pump delivered from the meal through `analysisEnd`,
    /// from our own records — never from anything an AI wrote.
    let insulinDelivered: Double
    /// What the run-to-run rules make of this window. Shown because it is the
    /// reason the *next* instance of this meal gets the dose it gets, and a
    /// number with no visible reason behind it is not reviewable.
    let outcome: MealOutcome
    /// Where the window was cut short by the next meal, if it was.
    let truncatedByNextMeal: Bool
    /// The timeline under the chart, in time order.
    let events: [MealWindowEvent]
}

@MainActor
final class MealWindowViewModel: ObservableObject {
    @Published var data: MealWindowData?
    @Published var hasLoaded = false

    /// Spacing of the IOB curve's samples.
    ///
    /// Every sample is a separate derivation over its own six-hour lookback, so
    /// this is a real cost rather than a free interpolation. Ten minutes over a
    /// four-hour window is two dozen reads for a curve nobody reads off to the
    /// unit — five-minute samples would double that to draw the same shape.
    static let iobSampleInterval = 10.0.minutesToSeconds()

    private let meal: StoredMeal
    private let glucoseStorage: GlucoseStorage
    private let insulinStorage: InsulinStorage
    private let mealStorage: MealStorage

    init(
        meal: StoredMeal,
        glucoseStorage: GlucoseStorage,
        insulinStorage: InsulinStorage,
        mealStorage: MealStorage
    ) {
        self.meal = meal
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.mealStorage = mealStorage
    }

    func load(now: Date = Date()) async {
        let chartStart = meal.startTime - MealRecordStorePolicy.preMealWindow
        // The chart always shows the full 3.5 hours so a meal's window doesn't
        // change width as the afternoon goes on. The *analysis* window is the
        // one that gets cut short, and it is drawn inside this one.
        let chartEnd = meal.startTime + MealRecordStorePolicy.postMealWindow

        // The classification comes from `MealStorage`, which is also where the
        // recommendation gets it. Re-deriving it here would let the explanation
        // on this screen drift from the dose on the other one.
        let analysis = await mealStorage.analysis(for: meal, at: now)

        let readings = await glucoseStorage.readingsBetween(startDate: chartStart, endDate: chartEnd)
        // Counting stops where the evidence does. `analysisEnd` is the 3.5
        // hours cut short by the next meal and by the present — the same
        // window the outcome is read over — so this total is the insulin that
        // belongs to *this* plate rather than the next plate's dose added on.
        //
        // The IOB curve below is deliberately not bounded this way. It answers
        // "how much insulin was working", and a unit is working whether or not
        // the meal that prompted it is the one on screen.
        let countingEnd = max(meal.startTime, analysis.analysisEnd)
        let delivered = await insulinStorage.insulinDelivered(
            startDate: meal.startTime,
            endDate: countingEnd
        )

        data = MealWindowData(
            start: chartStart,
            end: chartEnd,
            analysisEnd: countingEnd,
            glucose: readings.map {
                MealGlucosePoint(at: $0.date, glucoseInMgDl: $0.quantity.doubleValue(for: .milligramsPerDeciliter))
            },
            iob: await iobSeries(from: chartStart, to: min(chartEnd, now)),
            insulinDelivered: delivered,
            outcome: analysis.outcome,
            truncatedByNextMeal: analysis.truncatedByNextMeal,
            events: await events(analysis: analysis, chartEnd: chartEnd, now: now)
        )
        hasLoaded = true
    }

    /// The meals, the boluses, and the outcome — in time order.
    private func events(analysis: MealWindowAnalysis, chartEnd: Date, now: Date) async -> [MealWindowEvent] {
        // This meal, plus any other that shares its window. A second plate is
        // the usual explanation for what glucose did next, and when it cut the
        // analysis short, its marker is where the evidence stops.
        var events: [MealWindowEvent] = [.meal(meal)]
        events += analysis.otherMeals.map { .meal($0) }

        // Bounded to the window rather than read through to now: this meal can
        // be 90 days old. `deduplicatedDoses` is the same helper the IOB path
        // and the AI exporter use, so a mutable bolus that was later finalized
        // shows once here too.
        let pumpEvents = await insulinStorage.pumpEvents(from: meal.startTime, to: min(chartEnd, now))
        for dose in InsulinTimeline.deduplicatedDoses(events: pumpEvents, at: .distantFuture)
        where dose.type == .bolus {
            let units = dose.deliveredUnits ?? dose.programmedUnits
            // A 0 U bolus is not an event anyone needs to read about.
            guard units > 0 else { continue }
            events.append(.bolus(at: dose.startDate, units: units, isAutomatic: dose.automatic == true))
        }

        // Only a real event gets a row. `.onTarget` and `.unknown` are the
        // absence of one, and the facts table below the chart already says so
        // in words.
        if let outcomeAt = analysis.outcome.at {
            events.append(.outcome(analysis.outcome, at: outcomeAt))
        }

        return events.sorted {
            if $0.at != $1.at { return $0.at < $1.at }
            return $0.tieBreakRank < $1.tieBreakRank
        }
    }

    private func iobSeries(from: Date, to: Date) async -> [MealIobSample] {
        guard to > from else { return [] }
        var samples: [MealIobSample] = []
        var at = from
        while at <= to {
            samples.append(MealIobSample(at: at, units: await insulinStorage.insulinOnBoard(at: at)))
            at = at + Self.iobSampleInterval
        }
        return samples
    }
}

// MARK: - The dose to offer

@MainActor
final class MealAnnouncementViewModel: ObservableObject {
    /// The three amounts, nil until loaded.
    @Published var recommendation: MealDoseRecommendation?
    /// Which tier the user has selected. Starts on `usual` — the algorithm's
    /// answer is the default, and less/more are one tap away.
    @Published var selectedTier: MealDoseTier? = .usual
    /// A hand-entered amount, which the doc allows alongside the three tiers.
    /// Non-empty means it wins over `selectedTier`.
    @Published var manualUnits: String = ""
    @Published var hasLoaded = false
    @Published var error: String?
    /// Set once the bolus is enacted, so a second tap can't deliver twice.
    @Published var delivered = false
    /// Whether the Adjust card is open. Collapsed by default: the three tiers
    /// are the intended path and the stepper is the escape hatch.
    @Published var adjustExpanded = false

    /// The decision context, shown as the card's stat row. All three are
    /// snapshots taken at load — this is a form, not a monitor, and a number
    /// that moved under the user mid-decision would be worse than a stale one.
    @Published var insulinOnBoard: Double?
    @Published var lastBolusAt: Date?
    @Published var currentGlucose: Double?

    /// The meal being dosed, re-read from the store on every `load`.
    ///
    /// Not the value the view was constructed with. This screen decides a dose
    /// from the meal's description — and an AI can revise or cancel an
    /// announcement at any point, including between the link being opened and
    /// this screen appearing. Dosing against the captured copy would mean
    /// dosing for a plate the AI has since corrected.
    @Published private(set) var meal: StoredMeal

    /// Set when the AI took the meal back. Delivery is refused while it is set.
    @Published private(set) var isCancelled = false

    private let mealStorage: MealStorage
    private let settingsStorage: SettingsStorage
    private let insulinStorage: InsulinStorage
    private let glucoseStorage: GlucoseStorage
    private let deviceDataManager: DeviceDataManager
    private let doseProgress: DoseProgress

    /// How far back to look for the last bolus, for the stat row.
    ///
    /// A bolus older than this reads as "none recently", which is the useful
    /// answer: the stat exists to catch stacking, and yesterday's dinner dose
    /// cannot stack.
    static let lastBolusLookback = 12.0.hoursToSeconds()

    /// How stale a CGM reading may be and still be shown as current.
    static let glucoseFreshness = 15.0.minutesToSeconds()

    init(
        meal: StoredMeal,
        mealStorage: MealStorage,
        settingsStorage: SettingsStorage,
        insulinStorage: InsulinStorage,
        glucoseStorage: GlucoseStorage,
        deviceDataManager: DeviceDataManager,
        doseProgress: DoseProgress
    ) {
        self.meal = meal
        self.mealStorage = mealStorage
        self.settingsStorage = settingsStorage
        self.insulinStorage = insulinStorage
        self.glucoseStorage = glucoseStorage
        self.deviceDataManager = deviceDataManager
        self.doseProgress = doseProgress
    }

    func load(now: Date = Date()) async {
        // Ingest first. This screen is reached from a handoff link the AI app
        // opens the instant it writes the announcement, and from the Meals
        // view — in both cases the file can be ahead of the store, and every
        // number below is derived from the meal.
        await mealStorage.ingest(at: now)

        // Then re-read, because ingest may have just changed this very meal.
        // A revision that sharpens the description changes the dosing key, and
        // so changes which past meal the recommendation is adapted from.
        if let current = await mealStorage.meal(
            bundleIdentifier: meal.bundleIdentifier,
            mealId: meal.mealId
        ) {
            meal = current
            isCancelled = current.isCancelled
        }

        recommendation = await mealStorage.recommendation(for: meal, at: now)
        insulinOnBoard = await insulinStorage.insulinOnBoard(at: now)
        lastBolusAt = await lastBolus(now: now)
        if let reading = await glucoseStorage.lastReading(),
           now.timeIntervalSince(reading.date) < Self.glucoseFreshness {
            currentGlucose = reading.quantity.doubleValue(for: .milligramsPerDeciliter)
        }
        hasLoaded = true
    }

    /// The most recent bolus *the user gave* inside the lookback.
    ///
    /// Automatic boluses are deliberately excluded. The tile sits beside IOB,
    /// which already counts every unit the loop put in, so the question left
    /// for this one is "have I dosed for this myself yet" — and on a phone
    /// that is closed-loop micro-bolusing, counting those pins the tile to a
    /// few minutes ago every time it is opened, which tells the user nothing.
    private func lastBolus(now: Date) async -> Date? {
        let events = await insulinStorage.pumpEvents(from: now - Self.lastBolusLookback, to: now)
        return Self.lastManualBolus(
            in: InsulinTimeline.deduplicatedDoses(events: events, at: .distantFuture)
        )
    }

    /// Pure, so the rule is testable without a pump.
    ///
    /// `automatic` is the same flag the window timeline reads to title a dose
    /// "automatic" rather than "bolus", and nil — a driver that never said —
    /// counts as manual there. One rule, so the tile and the timeline can't
    /// disagree about which doses were the user's.
    nonisolated static func lastManualBolus(in doses: [DoseEntry]) -> Date? {
        return doses
            .filter { $0.type == .bolus && $0.automatic != true }
            .filter { ($0.deliveredUnits ?? $0.programmedUnits) > 0 }
            .map { $0.startDate }
            .max()
    }

    /// The card's eyebrow: "BOLUS · BREAKFAST".
    var contextLabel: String {
        return "BOLUS · \(MealSlot.at(meal.startTime).label)"
    }

    /// One line saying why this number, for under the tiers.
    var reasoning: String {
        guard let reference = recommendation?.reference else {
            return "First time seeing this meal. Starting from \(MealDosingPolicy.usualDoseHours.formatted())h of your highest scheduled basal rate."
        }
        let previous = String(format: "%0.2f", reference.doseUnits)
        switch reference.outcome {
        case .predictedLow:
            return "Last time: \(previous)u · predicted low — dosing less"
        case .roseTooHigh:
            return "Last time: \(previous)u · rose over \(Int(MealDosingPolicy.excursionThresholdMgDl)) mg/dL — dosing more"
        case .onTarget:
            return "Last time: \(previous)u · held — same again"
        case .unknown:
            return "Last time: \(previous)u · not enough data to adjust"
        }
    }

    /// The step the Adjust card's +/- buttons move by — the same increment the
    /// tiers are spaced on, so stepping lands on the same numbers tapping does.
    var doseStep: Double {
        guard let recommendation else { return MealDosingPolicy.minimumDoseIncrement }
        return recommendation.step
    }

    /// Nudge the dose. Writes through `manualUnits`, so a stepped value takes
    /// precedence over the selected tier exactly as a typed one does — there is
    /// one answer to "what will be delivered", and it is `units`.
    func adjustDose(by delta: Double) {
        let next = max(0, (units ?? 0) + delta).rounded(toNearest: MealDosingPolicy.minimumDoseIncrement)
        manualUnits = String(format: "%0.2f", next)
    }

    /// What would be delivered right now: the hand-entered amount if there is
    /// one, otherwise the selected tier.
    var units: Double? {
        let trimmed = manualUnits.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            return Double(trimmed)
        }
        guard let recommendation, let selectedTier else { return nil }
        return recommendation.units(for: selectedTier)
    }

    /// Which chip reads as chosen: the tier whose amount is what would be
    /// delivered, or nil for an amount that is none of them.
    ///
    /// Derived from `units` rather than from `selectedTier`, because stepping
    /// and typing both write through `manualUnits` and a stepped value that
    /// lands back on a tier *is* that tier as far as the user can see. Keying
    /// the highlight off which control was last touched left every chip dark
    /// while the stepper sat exactly on `more`.
    ///
    /// `usual` is tested first so a tie goes to the algorithm's answer — the
    /// tiers collapse onto each other only near zero, where `less` is clamped.
    var highlightedTier: MealDoseTier? {
        guard let recommendation, let units else { return nil }
        let order: [MealDoseTier] = [.usual, .less, .more]
        return order.first { recommendation.units(for: $0).roughlyEqual(to: units) }
    }

    /// Deliver the chosen amount and record it as this meal's dose.
    ///
    /// Same gauntlet as `BolusView`, in the same order and for the same
    /// reasons: round to what the pump can give, refuse anything over
    /// `maxBolusUnits`, refuse zero, then Face ID. Meal dosing gets no
    /// exemption from any of it — the recommendation came from an algorithm
    /// reading a file another app wrote, which is more reason to keep the
    /// safety bound, not less.
    ///
    /// The dose is recorded *after* delivery succeeds. Run-to-run adaptation
    /// learns from what went in, so a bolus the pump refused must not become
    /// the number the next plate is adjusted from.
    func deliver(now: Date = Date()) async -> Bool {
        guard !delivered else { return false }

        // The AI took the meal back. Checked here and not only in the view
        // because the cancellation can land while this screen is open — the
        // Meals view ingests, or a loop tick does — and the button the user is
        // looking at was rendered before that.
        guard !isCancelled else {
            error = "This meal was cancelled by the app that announced it"
            return false
        }

        guard let pumpManager = deviceDataManager.pumpManager else {
            error = "No pump found"
            return false
        }
        guard let units else {
            error = "Could not read the bolus amount!"
            return false
        }

        let unitsRounded = pumpManager.roundToSupportedBolusVolume(units: units)
        let maxBolusUnits = settingsStorage.snapshot().maxBolusUnits

        guard unitsRounded <= maxBolusUnits else {
            error = "Bolus \(unitsRounded)U is above the max of \(maxBolusUnits)U"
            return false
        }
        guard unitsRounded > 0.0 else {
            error = "Bolus must be greater than 0"
            return false
        }

        if await FaceId.authenticate() != nil {
            error = "Not authenticated"
            return false
        }

        // Claimed before the await, not after: the two taps that would double
        // deliver fit either side of it.
        delivered = true

        // LoopKit tells apart a recommendation the user took from one they
        // moved, and the difference is worth recording: tapping `less` or
        // typing a number is the user overriding us, and the pump history is
        // where that shows up.
        let activationType = BolusActivationType.activationTypeFor(
            recommendedAmount: recommendation?.usual,
            bolusAmount: unitsRounded
        )

        if let bolusError = await pumpManager.enactBolus(
            units: unitsRounded,
            activationType: activationType,
            doseProgress: doseProgress
        ) {
            delivered = false
            error = bolusError.localizedDescription
            return false
        }

        await mealStorage.recordDose(for: meal, units: unitsRounded, at: now)
        return true
    }
}
