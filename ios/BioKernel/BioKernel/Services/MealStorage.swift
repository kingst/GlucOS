//
//  MealStorage.swift
//  BioKernel
//
//  The service layer over meals: ingestion, the 90-day history the Meals view
//  reads, and the dose recommendation the announcement view shows.
//
//  Three collaborators and no more — the announcement files, the meal store,
//  and glucose. What this deliberately does not touch is the pump. Nothing
//  here delivers insulin or asks anything to; `MealAnnouncementView` enacts the
//  bolus the user chose and then tells us the number through `recordDose`, so
//  the number this store learns from is what the user actually picked.
//
//  Ingestion runs at the top of every loop tick (`LoopRunner.loop`). That is
//  not a convenience — `ai-interface.md` retains two days of announcement
//  files, so ingestion is the only thing standing between an announcement and
//  being lost, and it has to run on the app's own schedule rather than when a
//  view opens. It is also why it must never fail a loop: an ingest error is
//  logged and the tick goes on to dose.
//

import Foundation
import HealthKit
import LoopKit

/// One past meal's window, read and classified.
///
/// Returned rather than recomputed per caller, because two callers want it: the
/// announcement view adapts a dose from it, and the detail view shows the user
/// what it found. Deriving it twice is how the number on one screen starts
/// disagreeing with the explanation on the other.
struct MealWindowAnalysis: Equatable, Sendable {
    /// Where the analysis window actually ended — 3.5 hours, cut short by the
    /// next meal and by the present.
    let analysisEnd: Date
    let outcome: MealOutcome
    /// Whether a following meal is what cut it short.
    let truncatedByNextMeal: Bool
    /// The *other* meals sharing this one's window, in start order — both the
    /// ones that follow it and any in the lead-in before it.
    ///
    /// Carried here rather than fetched separately by the view because the
    /// analysis already has to read them: the first meal after this one is what
    /// truncates the window. They matter on screen for the same reason they
    /// matter to the algorithm — a second plate is the usual explanation for
    /// what glucose did next, and when the analysis stopped early, seeing the
    /// meal that stopped it is the whole answer.
    let otherMeals: [StoredMeal]
}

extension MealWindowAnalysis {
    /// Splits a window's worth of meals into the anchor's neighbours and the
    /// instant that truncates its analysis.
    ///
    /// Pure, so the two rules that are easy to get subtly wrong are testable:
    ///
    ///  * The anchor is excluded **by identity**, not by time. Two different
    ///    meals can carry the same `startTime` — an AI announcing a split plate
    ///    as two records, say — and comparing times would silently drop one of
    ///    them from the timeline.
    ///  * Only a *later* meal truncates. A meal in the lead-in is shown, since
    ///    it explains carbs already on board, but it says nothing about where
    ///    this meal's evidence should stop.
    static func neighbours(
        of anchor: StoredMeal,
        in meals: [StoredMeal]
    ) -> (others: [StoredMeal], nextStart: Date?) {
        let others = meals
            .filter { $0.id != anchor.id }
            .sorted { $0.startTime < $1.startTime }
        let nextStart = others.first { $0.startTime > anchor.startTime }?.startTime
        return (others, nextStart)
    }
}

protocol MealStorage: Sendable {
    /// Copies whatever the AI apps have published into the store. Called at the
    /// top of each loop tick; never throws.
    func ingest(at: Date) async

    /// The Meals view's history: most recent first, cancellations excluded.
    func recentMeals(at: Date) async -> [StoredMeal]

    /// One meal by identity, for the detail and announcement views.
    func meal(bundleIdentifier: String, mealId: String) async -> StoredMeal?

    /// The past instance a recommendation for this meal would be adapted from,
    /// or nil on a meal we have never seen dosed.
    ///
    /// Separate from `recommendation` so the announcement view can chart the
    /// window it is learning from. Both call the same lookup, so the meal shown
    /// under "last time" is the meal the number came from.
    func referenceMeal(for meal: StoredMeal) async -> StoredMeal?

    /// Reads one meal's window and classifies what happened over it.
    ///
    /// The same call `recommendation` makes internally, exposed so the detail
    /// view shows the classification that actually drives the next dose rather
    /// than its own reading of the same data.
    func analysis(for meal: StoredMeal, at: Date) async -> MealWindowAnalysis

    /// What to dose for a meal, adapted from the last instance of it.
    func recommendation(for meal: StoredMeal, at: Date) async -> MealDoseRecommendation

    /// Records what the user dosed, which is what the next instance of this
    /// meal adapts from.
    func recordDose(for meal: StoredMeal, units: Double, at: Date) async
}

actor LocalMealStorage: MealStorage {
    private let announcementStorage: MealAnnouncementStorage
    private let recordStore: MealRecordStore?
    private let glucoseStorage: GlucoseStorage
    private let settingsStorage: @MainActor () -> SettingsStorage
    private let glucoseAlertsService: @MainActor () -> GlucoseAlertStorage
    private let log = DiagnosticLog(category: "MealStorage")

    init(
        announcementStorage: MealAnnouncementStorage,
        recordStore: MealRecordStore?,
        glucoseStorage: GlucoseStorage,
        settingsStorage: @MainActor @escaping () -> SettingsStorage,
        glucoseAlertsService: @MainActor @escaping () -> GlucoseAlertStorage
    ) {
        self.announcementStorage = announcementStorage
        self.recordStore = recordStore
        self.glucoseStorage = glucoseStorage
        self.settingsStorage = settingsStorage
        self.glucoseAlertsService = glucoseAlertsService
    }

    // MARK: - Ingestion

    func ingest(at: Date) async {
        guard let recordStore else { return }
        let announcements = await announcementStorage.announcements(at: at)
        do {
            let changed = try await recordStore.ingest(announcements, at: at)
            if changed > 0 {
                log.default("ingested %d meal announcement(s)", changed)
            }
        } catch {
            // A loop tick that can't copy meals is still a loop tick that has
            // to dose. The announcement stays in the file and the next tick
            // tries again — five minutes later, well inside the two days the
            // spec retains.
            log.error("could not ingest meal announcements: %{public}@", String(describing: error))
        }
    }

    // MARK: - Reads

    func recentMeals(at: Date) async -> [StoredMeal] {
        guard let recordStore else { return [] }
        do {
            let meals = try await recordStore.meals(
                from: at - MealRecordStorePolicy.retention,
                to: at
            )
            return meals.reversed()
        } catch {
            log.error("could not read meals: %{public}@", String(describing: error))
            return []
        }
    }

    func meal(bundleIdentifier: String, mealId: String) async -> StoredMeal? {
        guard let recordStore else { return nil }
        do {
            return try await recordStore.meal(bundleIdentifier: bundleIdentifier, mealId: mealId)
        } catch {
            log.error("could not read a meal: %{public}@", String(describing: error))
            return nil
        }
    }

    // MARK: - Dosing

    func referenceMeal(for meal: StoredMeal) async -> StoredMeal? {
        guard let recordStore else { return nil }
        do {
            return try await recordStore.lastDosedMeal(
                dosingKey: meal.dosingKey,
                before: meal.startTime
            )
        } catch {
            log.error("could not look up a reference meal: %{public}@", String(describing: error))
            return nil
        }
    }

    func recommendation(for meal: StoredMeal, at: Date) async -> MealDoseRecommendation {
        // `maxBasalRate()`, NOT `maxBasalRateUnitsPerHour`. The accessor is the
        // person's *peak therapy* basal rate — the maximum across the
        // ML-learned schedule, falling back to the pump basal rate they set as
        // a backup when nothing has been learned yet. The similarly named
        // stored property is a safety guardrail that `SafetyService` clamps
        // against, set well above anything they actually run.
        //
        // On the shipped defaults that is 2.0 U/h versus 0.3 U/h — a 6.0 U
        // cold-start meal dose instead of 0.9 U. This line had it wrong once;
        // see `MealDosing.coldStartDose` for the full note.
        //
        // The sensitivity read alongside it is the same one the loop doses off:
        // the ML-learned schedule with the hand-set value as its fallback,
        // sampled at `at` rather than at the meal's start time because it sizes
        // a step of insulin being given now.
        let (peakBasalRate, insulinSensitivity) = await MainActor.run {
            let settings = settingsStorage().snapshot()
            return (settings.maxBasalRate(), settings.learnedInsulinSensitivity(at: at))
        }

        // No store means no history, which is the cold start — not an error
        // worth failing the screen over. The user still gets a dose to work
        // from.
        guard let reference = await referenceMeal(for: meal), let previousDose = reference.doseUnits else {
            return MealDosing.recommendation(
                reference: nil,
                peakBasalRateUnitsPerHour: peakBasalRate,
                insulinSensitivityMgDlPerUnit: insulinSensitivity
            )
        }

        let analysis = await self.analysis(for: reference, at: at)
        return MealDosing.recommendation(
            reference: (startTime: reference.startTime, doseUnits: previousDose, outcome: analysis.outcome),
            peakBasalRateUnitsPerHour: peakBasalRate,
            insulinSensitivityMgDlPerUnit: insulinSensitivity
        )
    }

    func recordDose(for meal: StoredMeal, units: Double, at: Date) async {
        guard let recordStore else { return }
        do {
            try await recordStore.recordDose(
                bundleIdentifier: meal.bundleIdentifier,
                mealId: meal.mealId,
                units: units,
                at: at
            )
        } catch {
            log.error("could not record a meal dose: %{public}@", String(describing: error))
        }
    }

    // MARK: - Reading a past window

    func analysis(for meal: StoredMeal, at: Date) async -> MealWindowAnalysis {
        let fullWindowEnd = meal.startTime + MealRecordStorePolicy.postMealWindow

        // Every meal sharing this one's window, lead-in included, in one query.
        // Two jobs off one read: the first meal *after* this one truncates the
        // analysis, and all of them go on the timeline.
        var otherMeals: [StoredMeal] = []
        var nextMealStart: Date?
        if let recordStore {
            do {
                let inWindow = try await recordStore.meals(
                    from: meal.startTime - MealRecordStorePolicy.preMealWindow,
                    to: fullWindowEnd
                )
                (otherMeals, nextMealStart) = MealWindowAnalysis.neighbours(of: meal, in: inWindow)
            } catch {
                log.error("could not look for neighbouring meals: %{public}@", String(describing: error))
            }
        }

        let end = MealDosing.windowEnd(
            startTime: meal.startTime,
            nextMealStart: nextMealStart,
            now: at
        )

        // One read covering the whole window plus the prediction lookback
        // before it: replaying the low prediction at the window's first tick
        // needs the half hour of readings that precedes it.
        let readings = await glucoseStorage.readingsBetween(
            startDate: meal.startTime - LocalPhysiologicalModels.predictionLookback,
            endDate: end
        )

        let lowThreshold = await MainActor.run { glucoseAlertsService().lowAlertLevelMgDl() }

        return MealWindowAnalysis(
            analysisEnd: end,
            outcome: MealDosing.outcome(
                startTime: meal.startTime,
                windowEnd: end,
                readings: readings,
                lowThresholdMgDl: lowThreshold
            ),
            truncatedByNextMeal: nextMealStart.map { $0 < fullWindowEnd } ?? false,
            otherMeals: otherMeals
        )
    }
}
