//
//  MealRecordStoreTests.swift
//  BioKernelTests
//
//  `GRDBMealRecordStore`: ingestion, cancellation, the run-to-run lookup, the
//  normalizing rule behind it, and retention.
//
//  The tests that matter here are the ones ingestion's shape demands: it runs
//  on every loop tick over a two-day file window, so the same announcement is
//  offered hundreds of times a day and has to land exactly once — and it must
//  never disturb the one thing the store holds that the files do not, which is
//  what the user actually dosed.
//

import Testing
import Foundation
import GRDB
import LoopKit
@testable import BioKernel

struct MealRecordStoreTests {

    let now = Date.f("2026-03-14 12:00:00 +0000")
    let coach = "com.example.coach"
    let other = "com.example.other"

    func makeStore() throws -> GRDBMealRecordStore {
        return try GRDBMealRecordStore(inMemory: ())
    }

    func announcement(
        _ mealId: String,
        bundleIdentifier: String? = nil,
        updatedAt: Date,
        startTime: Date,
        mealDescription: String? = "eggs and toast"
    ) -> MealAnnouncement {
        return MealAnnouncement(
            bundleIdentifier: bundleIdentifier ?? coach,
            mealId: mealId,
            updatedAt: updatedAt,
            startTime: startTime,
            mealDescription: mealDescription
        )
    }

    // MARK: - The normalizing rule

    @Test func theDosingKeyFoldsCaseAndCollapsesWhitespace() throws {
        let expected = "eggs and toast"

        #expect(MealRecordStorePolicy.dosingKey(for: "eggs and toast") == expected)
        #expect(MealRecordStorePolicy.dosingKey(for: "Eggs And Toast") == expected)
        #expect(MealRecordStorePolicy.dosingKey(for: "  eggs   and\ttoast\n") == expected)
    }

    @Test func theDosingKeyLeavesEverythingElseAlone() throws {
        // Punctuation and word order stay significant: an AI that writes a
        // different description means a different plate, and guessing past that
        // is how two genuinely different meals end up sharing a dose.
        #expect(MealRecordStorePolicy.dosingKey(for: "eggs, toast") != MealRecordStorePolicy.dosingKey(for: "eggs toast"))
        #expect(MealRecordStorePolicy.dosingKey(for: "toast and eggs") != MealRecordStorePolicy.dosingKey(for: "eggs and toast"))
    }

    // MARK: - Ingestion

    @Test func anAnnouncementLandsAsAMeal() async throws {
        let store = try makeStore()
        let changed = try await store.ingest([announcement("m1", updatedAt: now, startTime: now)], at: now)

        #expect(changed == 1)
        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.mealDescription == "eggs and toast")
        #expect(meal.dosingKey == "eggs and toast")
        #expect(meal.isCancelled == false)
        #expect(meal.doseUnits == nil)
    }

    @Test func ingestingTheSameAnnouncementAgainChangesNothing() async throws {
        let store = try makeStore()
        let announcements = [announcement("m1", updatedAt: now, startTime: now)]

        #expect(try await store.ingest(announcements, at: now) == 1)
        // The loop offers the same two-day window every five minutes. Landing
        // twice would double every meal in the list.
        #expect(try await store.ingest(announcements, at: now) == 0)
        #expect(try await store.ingest(announcements, at: now) == 0)

        let meals = try await store.meals(from: now - 1, to: now + 1)
        #expect(meals.count == 1)
    }

    @Test func aNewerRevisionWins() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")], at: now)
        try await store.ingest([announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: "eggs and toast")], at: now)

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.mealDescription == "eggs and toast")
        #expect(meal.dosingKey == "eggs and toast")
    }

    @Test func anOlderRevisionIsIgnored() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: "eggs and toast")], at: now)
        // A stale row from yesterday's file, read after the newer one.
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")], at: now)

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.mealDescription == "eggs and toast")
    }

    @Test func twoAppsWithTheSameMealIdAreTwoMeals() async throws {
        let store = try makeStore()
        try await store.ingest([
            announcement("m1", bundleIdentifier: coach, updatedAt: now, startTime: now, mealDescription: "eggs"),
            announcement("m1", bundleIdentifier: other, updatedAt: now, startTime: now, mealDescription: "burrito")
        ], at: now)

        #expect(try await store.meal(bundleIdentifier: coach, mealId: "m1")?.mealDescription == "eggs")
        #expect(try await store.meal(bundleIdentifier: other, mealId: "m1")?.mealDescription == "burrito")
    }

    // MARK: - Cancellation

    @Test func aCancellationMarksTheMealAndHidesIt() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now)], at: now)
        try await store.ingest([announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: nil)], at: now)

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.isCancelled)
        // Still keeps what the meal was — the one thing a row with a real dose
        // on it needs to be able to say.
        #expect(meal.mealDescription == "eggs and toast")
        // And drops out of the list.
        #expect(try await store.meals(from: now - 1, to: now + 1).isEmpty)
    }

    @Test func aCancellationKeepsTheDoseThatWasAlreadyDelivered() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now)], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.5, at: now)
        try await store.ingest([announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: nil)], at: now)

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        // The insulin went in. A cancellation is the AI saying the meal isn't
        // happening, not a claim about the pump.
        #expect(meal.doseUnits == 2.5)
        #expect(meal.isCancelled)
    }

    @Test func aCancelledMealIsNeverAReference() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now)], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.5, at: now)
        try await store.ingest([announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: nil)], at: now)

        #expect(try await store.lastDosedMeal(dosingKey: "eggs and toast", before: now + 3600) == nil)
    }

    @Test func cancellingAMealWeNeverSawIsRecordedAnyway() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now, mealDescription: nil)], at: now)

        // Recording it is what stops a re-read of an older revision from
        // resurrecting the meal.
        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.isCancelled)
        #expect(try await store.meals(from: now - 1, to: now + 1).isEmpty)
    }

    @Test func cancelledMealsDoNotShareADosingKey() async throws {
        let store = try makeStore()
        try await store.ingest([
            announcement("m1", updatedAt: now, startTime: now, mealDescription: nil),
            announcement("m2", updatedAt: now, startTime: now, mealDescription: nil)
        ], at: now)

        // Every cancelled row stores an empty key, which is not an identity —
        // matching on it would hand back an arbitrary cancelled row.
        #expect(try await store.lastDosedMeal(dosingKey: "", before: now + 3600) == nil)
    }

    // MARK: - Recording a dose

    @Test func aDoseIsRecordedAgainstTheMeal() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now)], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 1.8, at: now + 60)

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.doseUnits == 1.8)
        #expect(meal.dosedAt == now + 60)
        #expect(meal.isUsableReference)
    }

    @Test func aRevisedDescriptionDoesNotUnmakeAnInjection() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 1.8, at: now)
        // The AI sharpens up the description after the fact.
        try await store.ingest([announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: "eggs and toast")], at: now)

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.mealDescription == "eggs and toast")
        #expect(meal.doseUnits == 1.8)
    }

    @Test func recordingADoseForAMealWeDoNotHaveIsANoOp() async throws {
        let store = try makeStore()
        try await store.recordDose(bundleIdentifier: coach, mealId: "nope", units: 1.8, at: now)

        #expect(try await store.meal(bundleIdentifier: coach, mealId: "nope") == nil)
    }

    // MARK: - Offering to dose from the detail screen

    /// A `StoredMeal` built in memory, for the rules that take rows rather
    /// than a store.
    func stored(
        _ mealId: String = "m1",
        bundleIdentifier: String? = nil,
        startTime: Date,
        description: String = "eggs and toast",
        doseUnits: Double? = nil,
        isCancelled: Bool = false
    ) -> StoredMeal {
        return StoredMeal(
            bundleIdentifier: bundleIdentifier ?? coach,
            mealId: mealId,
            updatedAt: startTime,
            startTime: startTime,
            mealDescription: description,
            dosingKey: MealRecordStorePolicy.dosingKey(for: description),
            isCancelled: isCancelled,
            doseUnits: doseUnits,
            dosedAt: doseUnits == nil ? nil : startTime
        )
    }

    @Test func aRecentUndosedMealCanBeDosed() throws {
        #expect(stored(startTime: now - 5.0.minutesToSeconds()).canDose(at: now))
        #expect(stored(startTime: now - 29.0.minutesToSeconds()).canDose(at: now))
    }

    @Test func aMealPastTheWindowCannotBeDosed() throws {
        // A meal dose only helps while the food is still absorbing.
        #expect(!stored(startTime: now - 31.0.minutesToSeconds()).canDose(at: now))
        #expect(!stored(startTime: now - 4.0.hoursToSeconds()).canDose(at: now))
    }

    @Test func aMealAnnouncedForTheFutureCanStillBeDosed() throws {
        // Announcing ahead of a meal is explicitly supported by the interface,
        // and pre-bolusing is the point of doing it.
        #expect(stored(startTime: now + 20.0.minutesToSeconds()).canDose(at: now))
    }

    @Test func aMealThatWasAlreadyDosedCannotBeDosedAgain() throws {
        // The stacking guard: re-opening the screen must not offer a second
        // dose for the same plate.
        #expect(!stored(startTime: now, doseUnits: 2.5).canDose(at: now))
    }

    @Test func aCancelledMealCannotBeDosed() throws {
        #expect(!stored(startTime: now, isCancelled: true).canDose(at: now))
    }

    @Test func theWindowBoundaryIsExclusiveOfTheStaleSide() throws {
        // Exactly 30 minutes old is out. The boundary has to fall somewhere and
        // "still offered" is the side that doses.
        let boundary = now - MealRecordStorePolicy.dosingWindow
        #expect(!stored(startTime: boundary).canDose(at: now))
        #expect(stored(startTime: boundary + 1).canDose(at: now))
    }

    // MARK: - Freshness

    @Test @MainActor func theMealsListIngestsBeforeItReads() async throws {
        // The bug this pins: the list used to read the *store*, and nothing
        // outside the loop tick ever filled it — so an announcement written a
        // minute ago was invisible until the next tick, and on a phone with no
        // pump paired (the loop's caller returns early without one) it stayed
        // invisible.
        //
        // The spy only reveals its meal once ingest has run, so a `load()` that
        // read first would come back empty here and pass on a warm store.
        let meal = stored("m1", startTime: now)
        let storage = SpyMealStorage(revealAfterIngest: [meal])
        let model = MealsViewModel(mealStorage: storage)

        await model.load(now: now)

        #expect(model.meals.map { $0.mealId } == ["m1"])
        #expect(await storage.ingestCount == 1)
    }

    // MARK: - Day sections

    @Test func theMealsListGroupsRowsByLocalDay() throws {
        // Sections follow the list's own order — newest day first — and the
        // boundary is midnight, not a rolling 24 hours: a 11:40pm plate and a
        // 12:20am one are 40 minutes apart and belong under different
        // headings, which is the case a duration-based rule gets wrong.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))

        let lateNight = Date.f("2026-03-14 23:40:00 +0000")
        let afterMidnight = Date.f("2026-03-15 00:20:00 +0000")
        let lunch = Date.f("2026-03-15 12:00:00 +0000")

        let groups = MealsViewModel.groupedByDay(
            [
                stored("m3", startTime: lunch),
                stored("m2", startTime: afterMidnight),
                stored("m1", startTime: lateNight)
            ],
            calendar: calendar
        )

        #expect(groups.map { group in group.meals.map { $0.mealId } } == [["m3", "m2"], ["m1"]])
        #expect(groups.map { group in group.day } == [
            Date.f("2026-03-15 00:00:00 +0000"),
            Date.f("2026-03-14 00:00:00 +0000")
        ])
    }

    @Test func concurrentIngestsOfTheSameAnnouncementLeaveOneRow() async throws {
        // Ingest now runs from five places (launch, foreground, the Meals
        // view, the handoff link, the loop tick), and `LocalMealStorage` is an
        // actor that awaits inside `ingest`, so it does not serialize itself —
        // two of them genuinely overlap.
        //
        // What makes that safe is here, not there: each ingest is one
        // transaction, GRDB serializes writes, and the upsert's
        // `WHERE excluded.updated_at > meal.updated_at` makes the loser a
        // no-op rather than a second row.
        let store = try makeStore()
        let announcements = [announcement("m1", updatedAt: now, startTime: now)]

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await store.ingest(announcements, at: self.now) }
            }
        }

        let meals = try await store.meals(from: now - 1, to: now + 1)
        #expect(meals.count == 1)
        #expect(meals.first?.mealDescription == "eggs and toast")
    }

    @Test func anIngestRacingADoseCannotClearIt() async throws {
        // The dangerous interleaving: the user delivers while a foreground or
        // loop ingest is in flight for the same meal. `recordDose` writes the
        // dose columns and the upsert never touches them, so whichever lands
        // second, the insulin survives — which matters because that number is
        // also what the next instance of this meal adapts from.
        let store = try makeStore()
        let announcements = [announcement("m1", updatedAt: now, startTime: now)]
        try await store.ingest(announcements, at: now)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await store.ingest(announcements, at: self.now) }
            group.addTask {
                try? await store.recordDose(bundleIdentifier: self.coach, mealId: "m1", units: 2.5, at: self.now)
            }
            group.addTask { _ = try? await store.ingest(announcements, at: self.now) }
        }

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.doseUnits == 2.5)
    }

    @Test func aRevisionRacingADoseKeepsBoth() async throws {
        // Same race, but the ingest carries a *newer* revision, so its
        // DO UPDATE actually fires rather than being skipped on the
        // updated_at guard. The description moves; the dose does not.
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now, mealDescription: "eggs")], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.5, at: now)

        try await store.ingest(
            [announcement("m1", updatedAt: now + 300, startTime: now, mealDescription: "eggs and toast")],
            at: now
        )

        let meal = try #require(await store.meal(bundleIdentifier: coach, mealId: "m1"))
        #expect(meal.mealDescription == "eggs and toast")
        #expect(meal.doseUnits == 2.5)
    }

    // MARK: - Neighbouring meals

    @Test func aLaterMealIsANeighbourAndTruncatesTheWindow() throws {
        let anchor = stored("m1", startTime: now)
        let later = stored("m2", startTime: now + 2.0.hoursToSeconds())

        let (others, nextStart) = MealWindowAnalysis.neighbours(of: anchor, in: [anchor, later])

        #expect(others.map { $0.mealId } == ["m2"])
        #expect(nextStart == later.startTime)
    }

    @Test func aMealInTheLeadInIsShownButDoesNotTruncate() throws {
        // It explains carbs already on board, which is worth seeing — but it
        // says nothing about where *this* meal's evidence should stop.
        let anchor = stored("m1", startTime: now)
        let earlier = stored("m0", startTime: now - 20.0.minutesToSeconds())

        let (others, nextStart) = MealWindowAnalysis.neighbours(of: anchor, in: [earlier, anchor])

        #expect(others.map { $0.mealId } == ["m0"])
        #expect(nextStart == nil)
    }

    @Test func theAnchorIsExcludedByIdentityNotByTime() throws {
        // A split plate announced as two records at the same instant. Comparing
        // times would drop the second one off the timeline entirely.
        let anchor = stored("m1", startTime: now, description: "eggs")
        let sameInstant = stored("m2", startTime: now, description: "toast")

        let (others, nextStart) = MealWindowAnalysis.neighbours(of: anchor, in: [anchor, sameInstant])

        #expect(others.map { $0.mealId } == ["m2"])
        // Simultaneous, so there is no window left between them to analyze —
        // truncating here would leave nothing rather than something short.
        #expect(nextStart == nil)
    }

    @Test func twoAppsSharingAMealIdAreDifferentNeighbours() throws {
        // Identity is the pair, so the other app's meal is a neighbour even
        // though it carries the same `mealId` as the anchor.
        let anchor = stored("m1", bundleIdentifier: coach, startTime: now)
        let theirs = stored("m1", bundleIdentifier: other, startTime: now + 1.0.hoursToSeconds())

        let (others, nextStart) = MealWindowAnalysis.neighbours(of: anchor, in: [anchor, theirs])

        #expect(others.map { $0.bundleIdentifier } == [other])
        #expect(nextStart == theirs.startTime)
    }

    @Test func theEarliestFollowingMealIsTheTruncationPoint() throws {
        let anchor = stored("m1", startTime: now)
        let second = stored("m2", startTime: now + 3.0.hoursToSeconds())
        let third = stored("m3", startTime: now + 1.0.hoursToSeconds())

        // Order in is arbitrary; order out is by start time.
        let (others, nextStart) = MealWindowAnalysis.neighbours(of: anchor, in: [second, anchor, third])

        #expect(others.map { $0.mealId } == ["m3", "m2"])
        #expect(nextStart == third.startTime)
    }

    @Test func aWindowWithNoOtherMealsHasNoNeighbours() throws {
        let anchor = stored("m1", startTime: now)

        let (others, nextStart) = MealWindowAnalysis.neighbours(of: anchor, in: [anchor])

        #expect(others.isEmpty)
        #expect(nextStart == nil)
    }

    // MARK: - The run-to-run lookup

    @Test func theReferenceIsTheMostRecentDosedInstance() async throws {
        let store = try makeStore()
        for (index, offset) in [3.0, 2.0, 1.0].enumerated() {
            let start = now - offset.daysToSeconds()
            try await store.ingest([announcement("m\(index)", updatedAt: start, startTime: start)], at: now)
            try await store.recordDose(bundleIdentifier: coach, mealId: "m\(index)", units: 1.0 + Double(index), at: start)
        }

        let reference = try #require(await store.lastDosedMeal(dosingKey: "eggs and toast", before: now))
        // We reason about the last plate only — no averaging over the history.
        #expect(reference.doseUnits == 3.0)
    }

    @Test func anUndosedInstanceIsNotAReference() async throws {
        let store = try makeStore()
        let older = now - 2.0.daysToSeconds()
        let newer = now - 1.0.daysToSeconds()

        try await store.ingest([announcement("m1", updatedAt: older, startTime: older)], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.0, at: older)
        // Announced but never dosed from this screen, which is most meals.
        try await store.ingest([announcement("m2", updatedAt: newer, startTime: newer)], at: now)

        let reference = try #require(await store.lastDosedMeal(dosingKey: "eggs and toast", before: now))
        #expect(reference.mealId == "m1")
    }

    @Test func theReferenceMustBeStrictlyBeforeTheMeal() async throws {
        let store = try makeStore()
        try await store.ingest([announcement("m1", updatedAt: now, startTime: now)], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.0, at: now)

        // A meal is not its own reference.
        #expect(try await store.lastDosedMeal(dosingKey: "eggs and toast", before: now) == nil)
        #expect(try await store.lastDosedMeal(dosingKey: "eggs and toast", before: now + 1) != nil)
    }

    @Test func meansMatchAcrossAppsForNow() async throws {
        let store = try makeStore()
        let older = now - 1.0.daysToSeconds()
        try await store.ingest([announcement("m1", bundleIdentifier: other, updatedAt: older, startTime: older)], at: now)
        try await store.recordDose(bundleIdentifier: other, mealId: "m1", units: 2.0, at: older)

        // First cut: two apps that describe a meal the same way share its
        // history. The origin is on the row so this can be scoped later.
        let reference = try #require(await store.lastDosedMeal(dosingKey: "eggs and toast", before: now))
        #expect(reference.bundleIdentifier == other)
    }

    @Test func aDifferentDescriptionIsADifferentMeal() async throws {
        let store = try makeStore()
        let older = now - 1.0.daysToSeconds()
        try await store.ingest([announcement("m1", updatedAt: older, startTime: older, mealDescription: "burrito")], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.0, at: older)

        #expect(try await store.lastDosedMeal(dosingKey: "eggs and toast", before: now) == nil)
    }

    @Test func aDescriptionThatOnlyDiffersInCaseIsTheSameMeal() async throws {
        let store = try makeStore()
        let older = now - 1.0.daysToSeconds()
        try await store.ingest([announcement("m1", updatedAt: older, startTime: older, mealDescription: "  Eggs   And Toast ")], at: now)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.0, at: older)

        #expect(try await store.lastDosedMeal(dosingKey: MealRecordStorePolicy.dosingKey(for: "eggs and toast"), before: now) != nil)
    }

    // MARK: - Reads

    @Test func mealsComeBackInStartOrder() async throws {
        let store = try makeStore()
        for offset in [1.0, 3.0, 2.0] {
            let start = now - offset.hoursToSeconds()
            try await store.ingest([announcement("m\(offset)", updatedAt: start, startTime: start)], at: now)
        }

        let meals = try await store.meals(from: now - 1.0.daysToSeconds(), to: now)
        #expect(meals.map { $0.startTime } == meals.map { $0.startTime }.sorted())
    }

    @Test func aWindowExcludesMealsOutsideIt() async throws {
        let store = try makeStore()
        let inside = now - 1.0.hoursToSeconds()
        let outside = now - 5.0.hoursToSeconds()
        try await store.ingest([
            announcement("m1", updatedAt: inside, startTime: inside),
            announcement("m2", updatedAt: outside, startTime: outside)
        ], at: now)

        let meals = try await store.meals(from: now - 2.0.hoursToSeconds(), to: now)
        #expect(meals.map { $0.mealId } == ["m1"])
    }

    // MARK: - Retention

    @Test func mealsPastNinetyDaysArePruned() async throws {
        let store = try makeStore()
        let old = now - 91.0.daysToSeconds()
        let recent = now - 89.0.daysToSeconds()

        // Ingested as of a time when both were inside the horizon.
        try await store.ingest([
            announcement("m1", updatedAt: old, startTime: old),
            announcement("m2", updatedAt: recent, startTime: recent)
        ], at: old)

        // Then a tick today sweeps.
        try await store.ingest([], at: now)

        #expect(try await store.meal(bundleIdentifier: coach, mealId: "m1") == nil)
        #expect(try await store.meal(bundleIdentifier: coach, mealId: "m2") != nil)
    }

    @Test func retentionRunsEvenWhenNothingWasAnnounced() async throws {
        let store = try makeStore()
        let old = now - 91.0.daysToSeconds()
        try await store.ingest([announcement("m1", updatedAt: old, startTime: old)], at: old)

        // The files go quiet whenever the user stops announcing, and rows
        // shouldn't outlive the horizon just because nothing new arrived.
        #expect(try await store.ingest([], at: now) == 0)
        #expect(try await store.meal(bundleIdentifier: coach, mealId: "m1") == nil)
    }

    @Test func aDosedMealGetsNoExemptionFromRetention() async throws {
        let store = try makeStore()
        let old = now - 91.0.daysToSeconds()
        try await store.ingest([announcement("m1", updatedAt: old, startTime: old)], at: old)
        try await store.recordDose(bundleIdentifier: coach, mealId: "m1", units: 2.0, at: old)

        // Unlike the alert store there is no such thing as an outstanding meal.
        try await store.ingest([], at: now)
        #expect(try await store.meal(bundleIdentifier: coach, mealId: "m1") == nil)
    }

    // MARK: - What the window's numbers count

    func bolus(
        _ id: String,
        at: Date,
        units: Double,
        automatic: Bool?
    ) -> NewPumpEvent {
        let dose = DoseEntry(
            type: .bolus,
            startDate: at,
            endDate: at + 60,
            value: units,
            unit: .units,
            deliveredUnits: units,
            // Required: `deduplicatedDoses` drops a dose with no sync id, so a
            // bolus without one would pass these tests by disappearing.
            syncIdentifier: id,
            insulinType: .lyumjev,
            automatic: automatic,
            isMutable: false
        )
        return NewPumpEvent(date: at, dose: dose, raw: Data(id.utf8), title: id, type: .bolus)
    }

    @Test @MainActor func theInsulinTotalStopsAtTheNextMeal() async throws {
        // The bug this pins: the total under the chart was read from the meal
        // through the end of the *chart* — 3.5 hours — while the outcome above
        // it was read over the window the next meal cut short. A snack two
        // hours in therefore had its own dose charged to the earlier plate.
        let meal = stored("m1", startTime: now)
        let nextMealAt = now + 2.0.hoursToSeconds()
        let storage = SpyMealStorage(
            revealAfterIngest: [meal],
            analysis: MealWindowAnalysis(
                analysisEnd: nextMealAt,
                outcome: .unknown,
                truncatedByNextMeal: true,
                otherMeals: [stored("m2", startTime: nextMealAt)]
            )
        )
        let insulin = SpyInsulinStorage()
        let model = MealWindowViewModel(
            meal: meal,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: insulin,
            mealStorage: storage
        )

        // Well after the window closed, so nothing here is bounded by the
        // present.
        await model.load(now: now + 6.0.hoursToSeconds())

        #expect(insulin.deliveredRequests.count == 1)
        #expect(insulin.deliveredRequests.first?.startDate == meal.startTime)
        #expect(insulin.deliveredRequests.first?.endDate == nextMealAt)
        #expect(model.data?.analysisEnd == nextMealAt)
    }

    @Test @MainActor func theIobCurveStillCoversTheWholeChart() async throws {
        // The other half of the rule: IOB answers "how much insulin was
        // working", and a unit is working whether or not the meal that
        // prompted it is the one on screen. Cutting this at the next meal
        // would draw the curve falling off a cliff mid-chart.
        let meal = stored("m1", startTime: now)
        let nextMealAt = now + 2.0.hoursToSeconds()
        let storage = SpyMealStorage(
            revealAfterIngest: [meal],
            analysis: MealWindowAnalysis(
                analysisEnd: nextMealAt,
                outcome: .unknown,
                truncatedByNextMeal: true,
                otherMeals: [stored("m2", startTime: nextMealAt)]
            )
        )
        let insulin = SpyInsulinStorage()
        let model = MealWindowViewModel(
            meal: meal,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: insulin,
            mealStorage: storage
        )

        await model.load(now: now + 6.0.hoursToSeconds())

        let chartEnd = now + MealRecordStorePolicy.postMealWindow
        #expect(insulin.iobRequests.first == now - MealRecordStorePolicy.preMealWindow)
        // Within one sample of the chart's right edge, and well past the meal
        // that truncated the count.
        let lastIob = insulin.iobRequests.max() ?? .distantPast
        #expect(lastIob > nextMealAt)
        #expect(chartEnd.timeIntervalSince(lastIob) < MealWindowViewModel.iobSampleInterval)
    }

    @Test @MainActor func theLastBolusStatIgnoresTheLoopsOwnBoluses() async throws {
        let meal = stored("m1", startTime: now)
        let insulin = SpyInsulinStorage()
        let manualAt = now - 2.0.hoursToSeconds()
        insulin.events = [
            bolus("manual", at: manualAt, units: 3.0, automatic: false),
            bolus("micro", at: now - 5.0.minutesToSeconds(), units: 0.05, automatic: true)
        ]
        let model = MealAnnouncementViewModel(
            meal: meal,
            mealStorage: SpyMealStorage(revealAfterIngest: [meal]),
            settingsStorage: MockSettingsStorage(),
            insulinStorage: insulin,
            glucoseStorage: MockGlucoseStorage(),
            deviceDataManager: MockDeviceDataManager(),
            doseProgress: DoseProgress()
        )

        await model.load(now: now)

        // On a closed-loop phone the newest bolus is nearly always the loop's,
        // so counting those pinned the tile to a few minutes ago every time it
        // opened. What the user needs from it is whether *they* have already
        // dosed — here, at lunch.
        #expect(model.lastBolusAt == manualAt)
    }

    @Test @MainActor func steppingOntoATierHighlightsIt() async throws {
        // The chips read off the amount that would be delivered, not off which
        // control the user last touched. Stepping down once from `usual` lands
        // exactly on `less`, and a dark chip there tells the user they are
        // about to deliver something other than the number under their finger.
        let meal = stored("m1", startTime: now)
        let model = MealAnnouncementViewModel(
            meal: meal,
            mealStorage: SpyMealStorage(revealAfterIngest: [meal]),
            settingsStorage: MockSettingsStorage(),
            insulinStorage: SpyInsulinStorage(),
            glucoseStorage: MockGlucoseStorage(),
            deviceDataManager: MockDeviceDataManager(),
            doseProgress: DoseProgress()
        )

        await model.load(now: now)

        // 3h of a 0.6 U/h peak basal, in steps of 25 / 50 mg/dL per unit.
        #expect(model.recommendation?.usual == 1.8)
        #expect(model.doseStep == 0.5)
        #expect(model.highlightedTier == .usual)

        model.adjustDose(by: -model.doseStep)
        #expect(model.units == 1.3)
        #expect(model.highlightedTier == .less)

        // A step past the tiers is nobody's chip.
        model.adjustDose(by: -model.doseStep)
        #expect(model.highlightedTier == nil)

        // And stepping back onto one lights it again.
        model.adjustDose(by: model.doseStep * 2)
        #expect(model.highlightedTier == .usual)

        // Typing the amount is the same as stepping to it.
        model.manualUnits = "2.30"
        #expect(model.highlightedTier == .more)
    }

    @Test func aBolusTheDriverDidntFlagCountsAsTheUsers() async throws {
        // `automatic` is optional, and nil means the driver never said. The
        // window timeline already titles those "bolus" rather than
        // "automatic", so the stat has to read them the same way — otherwise
        // the same dose is the user's on one screen and the loop's on the
        // other.
        let unflaggedAt = now - 1.0.hoursToSeconds()
        let doses = InsulinTimeline.deduplicatedDoses(
            events: [
                bolus("unflagged", at: unflaggedAt, units: 4.0, automatic: nil),
                bolus("micro", at: now - 5.0.minutesToSeconds(), units: 0.05, automatic: true)
            ],
            at: .distantFuture
        )

        #expect(MealAnnouncementViewModel.lastManualBolus(in: doses) == unflaggedAt)
    }

    @Test func aZeroUnitBolusIsNotALastBolus() async throws {
        // Kept from the original rule: a cancelled bolus lands in the log with
        // nothing delivered, and it is not something the user dosed.
        let doses = InsulinTimeline.deduplicatedDoses(
            events: [bolus("cancelled", at: now - 1.0.hoursToSeconds(), units: 0.0, automatic: false)],
            at: .distantFuture
        )

        #expect(MealAnnouncementViewModel.lastManualBolus(in: doses) == nil)
    }
}

/// A `MealStorage` that hands back its meals only after `ingest` has run, so a
/// caller's read/ingest ordering is observable.
private actor SpyMealStorage: MealStorage {
    private let revealAfterIngest: [StoredMeal]
    /// What `analysis` answers, when a test cares. Injected rather than
    /// derived: the classification is `LocalMealStorage`'s job and is tested
    /// there, and what these tests are about is what the *view models* do with
    /// the window it reports.
    private let analysisResult: MealWindowAnalysis?
    private var hasIngested = false
    private(set) var ingestCount = 0

    init(revealAfterIngest: [StoredMeal], analysis: MealWindowAnalysis? = nil) {
        self.revealAfterIngest = revealAfterIngest
        self.analysisResult = analysis
    }

    func ingest(at: Date) async {
        ingestCount += 1
        hasIngested = true
    }

    func recentMeals(at: Date) async -> [StoredMeal] {
        return hasIngested ? revealAfterIngest : []
    }

    func meal(bundleIdentifier: String, mealId: String) async -> StoredMeal? {
        return revealAfterIngest.first { $0.bundleIdentifier == bundleIdentifier && $0.mealId == mealId }
    }

    func analysis(for meal: StoredMeal, at: Date) async -> MealWindowAnalysis {
        return analysisResult ?? MealWindowAnalysis(
            analysisEnd: meal.startTime,
            outcome: .unknown,
            truncatedByNextMeal: false,
            otherMeals: []
        )
    }

    func referenceMeal(for meal: StoredMeal) async -> StoredMeal? { return nil }

    func recommendation(for meal: StoredMeal, at: Date) async -> MealDoseRecommendation {
        return MealDosing.recommendation(
            reference: nil,
            peakBasalRateUnitsPerHour: 0.6,
            insulinSensitivityMgDlPerUnit: 50
        )
    }

    func recordDose(for meal: StoredMeal, units: Double, at: Date) async {}
}

/// An `InsulinStorage` that records the window each derived number was asked
/// over, which is what the two reads in `MealWindowViewModel` differ in.
private class SpyInsulinStorage: MockInsulinStorage {
    var deliveredRequests: [(startDate: Date, endDate: Date)] = []
    var iobRequests: [Date] = []
    var events: [NewPumpEvent] = []

    override func insulinDelivered(startDate: Date, endDate: Date) async -> Double {
        deliveredRequests.append((startDate: startDate, endDate: endDate))
        return 0.0
    }

    override func insulinOnBoard(at: Date) async -> Double {
        iobRequests.append(at)
        return 0.0
    }

    override func pumpEvents(from: Date, to: Date) async -> [NewPumpEvent] {
        return events.filter { $0.date >= from && $0.date <= to }
    }
}
