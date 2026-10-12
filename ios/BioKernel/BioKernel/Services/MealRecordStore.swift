//
//  MealRecordStore.swift
//  BioKernel
//
//  The protocol seam over the store of meals AI apps have announced. See
//  dev/meal-announcements-from-ai-apps.md.
//
//  Same shape as `GlucoseRecordStore`, `InsulinRecordStore` and
//  `AlertRecordStore`: the row struct is private to `GRDBMealRecordStore` and
//  only domain values cross this boundary.
//
//  This store exists because the interface files are a *window*, not a history.
//  `ai-interface.md` guarantees two days of retention and names the append day
//  in the file name, so an announcement nobody copies out within two days is
//  gone. Everything retrospective — the 90-day Meals view, and every
//  run-to-run question about how the last plate of this went — reads from here
//  instead, which is why ingestion runs at the top of every loop rather than
//  when a view happens to open.
//

import Foundation

enum MealRecordStoreError: Error {
    case couldNotOpen(String)
    case writeFailed(String)
    case readFailed(String)
}

/// A meal as GlucOS holds it: the announcement, plus what we did about it.
struct StoredMeal: Equatable, Sendable {
    /// The app that announced this meal. Half of its identity — `mealId` is
    /// only unique within one app — and, separately, a provenance record: meals
    /// are *matched* across apps by description today (see `dosingKey`), and
    /// keeping the origin means that decision can be narrowed later without
    /// having lost the data it would need.
    let bundleIdentifier: String
    let mealId: String
    /// The winning revision's write time. Newest wins on re-ingest.
    let updatedAt: Date
    /// When the meal starts. The anchor for every window in this feature.
    let startTime: Date
    /// What the AI called it, as written.
    let mealDescription: String
    /// `mealDescription` normalized — the key run-to-run adaptation groups by.
    /// Stored rather than derived at query time so the grouping is an indexed
    /// column instead of a scan, and so a change to the normalizing rule is
    /// visible as a migration rather than a silent re-partition of history.
    let dosingKey: String
    /// Whether the AI took the meal back.
    ///
    /// Cancelled meals are kept, not deleted. A cancellation can arrive after
    /// the user has already dosed, and in that case the insulin is real; the
    /// row is the only place that pairing survives. They drop out of the Meals
    /// view and are never a run-to-run reference.
    let isCancelled: Bool
    /// What the user actually dosed for this meal, and when — nil until they
    /// do, which is most meals most days.
    ///
    /// This is the number run-to-run adaptation reads back, and it is
    /// deliberately what the user *picked* rather than our recommendation or
    /// the pump's delivered total: the recommendation isn't what happened, and
    /// the pump's total over the window includes every basal adjustment the
    /// loop made for reasons that had nothing to do with the meal.
    let doseUnits: Double?
    let dosedAt: Date?
}

extension StoredMeal: Identifiable {
    /// Both halves of the identity, because `mealId` is only unique within the
    /// app that wrote it — keying a list on `mealId` alone would collapse two
    /// apps' meals into one row whenever they picked the same string.
    var id: String {
        return "\(bundleIdentifier)\u{0}\(mealId)"
    }

    /// Whether this meal can serve as a run-to-run reference: the user dosed
    /// it, and the AI didn't take it back.
    var isUsableReference: Bool {
        return doseUnits != nil && !isCancelled
    }

    /// Whether the meal detail screen should still offer to dose this meal.
    ///
    /// Three conditions, all narrow on purpose:
    ///
    ///  * **Nothing dosed yet.** Offering a second dose for a meal already
    ///    dosed is how someone stacks insulin by re-opening a screen.
    ///  * **Not cancelled.** The AI said the meal isn't happening.
    ///  * **Recent.** A meal dose only helps while the food is still
    ///    absorbing, so an hours-old meal gets no button rather than a button
    ///    that would do harm.
    ///
    /// Recency is measured from `startTime`, not from `updatedAt`. Those differ
    /// when an AI announces ahead of time or revises after the fact, and what
    /// governs whether insulin still helps is when the person ate. A meal
    /// announced *for the future* therefore keeps the button, which is the
    /// announce-ahead case working as intended.
    func canDose(at now: Date, window: TimeInterval = MealRecordStorePolicy.dosingWindow) -> Bool {
        guard doseUnits == nil, !isCancelled else { return false }
        return startTime > now - window
    }
}

enum MealRecordStorePolicy {
    /// Matches every other store's retention, so all of them answer
    /// retrospective questions over the same span, and matches the 90 days the
    /// Meals view shows.
    static let retention = 90.0.daysToSeconds()

    /// How much of a meal's aftermath the analysis window covers.
    static let postMealWindow = 3.5.hoursToSeconds()

    /// How much *before* a meal the window screens show.
    ///
    /// Never analyzed — glucose before the meal is context for reading the
    /// trace, not evidence about this dose. It is a policy rather than a view
    /// constant because the meal read that populates the window has to cover
    /// the same span: a meal 20 minutes before this one belongs on the
    /// timeline, and only the store knows about it.
    static let preMealWindow = 30.0.minutesToSeconds()

    /// How long after a meal the detail screen still offers to dose it.
    /// See `StoredMeal.canDose(at:window:)`.
    static let dosingWindow = 30.0.minutesToSeconds()

    /// How far into that window predicted-low events start counting.
    ///
    /// Skipping the first 45 minutes is the point of the number: a low
    /// predicted just after a meal is usually carried over from the *previous*
    /// meal's insulin, and reading it as this meal's outcome would walk the
    /// dose down for something this dose didn't cause.
    static let lowPredictionLeadIn = 0.75.hoursToSeconds()

    /// Normalizes a description into the key meals are grouped by.
    ///
    /// Case-folded, and every run of whitespace collapsed to one space — so
    /// "Eggs  and Toast" and "eggs and toast" are one meal with one dosing
    /// history. Nothing else is touched: punctuation and word order stay
    /// significant, because an AI that writes a different description means a
    /// different plate, and guessing past that is how two genuinely different
    /// meals end up sharing a dose.
    ///
    /// Matching is across apps for this first cut — two apps that describe a
    /// meal the same way share its history. `StoredMeal.bundleIdentifier`
    /// records which app announced each one so that can be scoped later.
    static func dosingKey(for mealDescription: String) -> String {
        return mealDescription
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

protocol MealRecordStore: Sendable {
    /// Copies announcements into the store, newest revision winning, and prunes
    /// past retention.
    ///
    /// Idempotent, because it runs on every loop tick over a two-day file
    /// window: the same announcement is offered ~576 times a day and must land
    /// once. Re-ingesting a meal never disturbs what the user dosed for it —
    /// an AI is allowed to revise a description after the fact, and that is not
    /// a reason to forget the injection.
    ///
    /// - Returns: how many rows were inserted or updated, for logging.
    @discardableResult
    func ingest(_ announcements: [MealAnnouncement], at: Date) async throws -> Int

    /// Meals whose `startTime` falls in the range, ascending, cancellations
    /// excluded.
    func meals(from: Date, to: Date) async throws -> [StoredMeal]

    /// One meal by its full identity, cancelled or not.
    func meal(bundleIdentifier: String, mealId: String) async throws -> StoredMeal?

    /// The most recent usable instance of the same meal strictly before
    /// `before` — the run-to-run reference.
    ///
    /// "Most recent" and nothing more: we reason about the last plate only, so
    /// there is no averaging over the history and no window of past instances.
    /// Each adjustment compounds off the one before it, which is what lets a
    /// meal converge instead of oscillating around a fixed baseline.
    func lastDosedMeal(dosingKey: String, before: Date) async throws -> StoredMeal?

    /// Records what the user dosed for a meal. A no-op when the meal isn't in
    /// the store.
    func recordDose(bundleIdentifier: String, mealId: String, units: Double, at: Date) async throws
}
