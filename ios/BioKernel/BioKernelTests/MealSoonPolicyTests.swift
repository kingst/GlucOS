//
//  MealSoonPolicyTests.swift
//  BioKernelTests
//
//  Created by Sam King on 10/20/26.
//
//  `MealSoonPolicy` and `TargetOverridePolicy`, which are pure: the override's
//  target for a settings target, and whether a meal-soon override is still in
//  effect given a row, the clock, and the doses the pump reported. See
//  dev/backlog/meal-soon.md §4.1 and §10. The exercise side of the status rule
//  is in `ExercisePolicyTests`.
//

import Testing
import Foundation
import LoopKit
@testable import BioKernel

struct MealSoonPolicyTests {

    let startedAt = Date.f("2026-10-20 12:00:00 +0000")
    var expiresAt: Date { startedAt + MealSoonPolicy.duration }

    // MARK: - Fixtures

    private func override(
        endedAt: Date? = nil,
        endReason: TargetOverrideEndReason? = nil,
        bolusSyncIdentifier: String? = nil
    ) -> TargetOverride {
        return TargetOverride(
            id: 1,
            kind: .mealSoon,
            startedAt: startedAt,
            expiresAt: expiresAt,
            settingsTargetMgDl: 90,
            endedAt: endedAt,
            endReason: endReason,
            endBolusSyncIdentifier: bolusSyncIdentifier
        )
    }

    private func bolus(at: Date, automatic: Bool?, syncIdentifier: String, duration: TimeInterval = 40) -> DoseEntry {
        return DoseEntry(
            type: .bolus,
            startDate: at,
            endDate: at + duration,
            value: 1.5,
            unit: .units,
            syncIdentifier: syncIdentifier,
            insulinType: .lyumjev,
            automatic: automatic
        )
    }

    // MARK: - target

    @Test func targetDropsFifteenWithAFloorOfSeventyFive() {
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 90) == 75)
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 80) == 75, "floored, not 65")
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 120) == 105)
        #expect(MealSoonPolicy.target(settingsTargetMgDl: 140) == 125)
    }

    // MARK: - status: the clock

    @Test func activeOneSecondBeforeExpiry() {
        let status = TargetOverridePolicy.status(of: override(), at: expiresAt - 1, doses: [])
        #expect(status == .active)
    }

    @Test func expiredAtExactlySixtyMinutes() {
        let status = TargetOverridePolicy.status(of: override(), at: expiresAt, doses: [])
        #expect(status == .ended(at: expiresAt, reason: .expired, bolusSyncIdentifier: nil))
    }

    // MARK: - status: boluses

    @Test func aManualBolusEndsItAtTheBolusStart() {
        let bolusAt = startedAt + 20.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 30.minutesToSeconds(),
            doses: [bolus(at: bolusAt, automatic: false, syncIdentifier: "manual-1")]
        )
        #expect(status == .ended(at: bolusAt, reason: .manualBolus, bolusSyncIdentifier: "manual-1"),
                "ended when the override stopped applying, not when we noticed")
    }

    @Test func anAutomaticBolusDoesNotEndIt() {
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 30.minutesToSeconds(),
            doses: [bolus(at: startedAt + 20.minutesToSeconds(), automatic: true, syncIdentifier: "micro-1")]
        )
        #expect(status == .active)
    }

    /// The store's window query tests overlap, so a bolus that began before the
    /// override and is still delivering comes back. The rule has to exclude it.
    @Test func aBolusThatStartedBeforeTheOverrideDoesNotEndIt() {
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 5.minutesToSeconds(),
            doses: [bolus(at: startedAt - 1.minutesToSeconds(), automatic: false, syncIdentifier: "earlier", duration: 3.minutesToSeconds())]
        )
        #expect(status == .active)
    }

    @Test func aBolusAfterExpiryReadsAsExpired() {
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 90.minutesToSeconds(),
            doses: [bolus(at: startedAt + 70.minutesToSeconds(), automatic: false, syncIdentifier: "late")]
        )
        #expect(status == .ended(at: expiresAt, reason: .expired, bolusSyncIdentifier: nil))
    }

    /// The window closes at `min(at, expiresAt)`: a dose after the instant being
    /// evaluated has not happened yet from the rule's point of view.
    @Test func aBolusAfterTheEvaluationInstantDoesNotCount() {
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 10.minutesToSeconds(),
            doses: [bolus(at: startedAt + 20.minutesToSeconds(), automatic: false, syncIdentifier: "future")]
        )
        #expect(status == .active)
    }

    /// Ending early means a higher target and less insulin, which is the safe
    /// side of an unknown.
    @Test func nilAutomaticCountsAsManual() {
        let bolusAt = startedAt + 20.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 30.minutesToSeconds(),
            doses: [bolus(at: bolusAt, automatic: nil, syncIdentifier: "unknown")]
        )
        #expect(status == .ended(at: bolusAt, reason: .manualBolus, bolusSyncIdentifier: "unknown"))
    }

    @Test func theEarliestOfTwoManualBolusesWins() {
        let first = startedAt + 20.minutesToSeconds()
        let second = startedAt + 30.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(),
            at: startedAt + 40.minutesToSeconds(),
            doses: [
                bolus(at: second, automatic: false, syncIdentifier: "second"),
                bolus(at: first, automatic: false, syncIdentifier: "first")
            ]
        )
        #expect(status == .ended(at: first, reason: .manualBolus, bolusSyncIdentifier: "first"),
                "earliest by start, not by order handed in")
    }

    @Test func aTempBasalIsNotABolus() {
        let tempBasal = DoseEntry(
            type: .tempBasal,
            startDate: startedAt + 5.minutesToSeconds(),
            endDate: startedAt + 35.minutesToSeconds(),
            value: 1.2,
            unit: .unitsPerHour,
            syncIdentifier: "temp",
            insulinType: .lyumjev,
            automatic: nil
        )
        let status = TargetOverridePolicy.status(of: override(), at: startedAt + 30.minutesToSeconds(), doses: [tempBasal])
        #expect(status == .active)
    }

    // MARK: - status: a closed row

    /// Cancelling from the UI closes the row directly, and that is how the rule
    /// sees a cancel. The stored reason wins over anything the clock or the
    /// doses would otherwise say.
    @Test func aClosedRowReturnsItsStoredReason() {
        let cancelledAt = startedAt + 5.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(endedAt: cancelledAt, endReason: .cancelled),
            at: startedAt + 90.minutesToSeconds(),
            doses: [bolus(at: startedAt + 20.minutesToSeconds(), automatic: false, syncIdentifier: "manual-1")]
        )
        #expect(status == .ended(at: cancelledAt, reason: .cancelled, bolusSyncIdentifier: nil))
    }

    @Test func aRowClosedByABolusCarriesTheDose() {
        let bolusAt = startedAt + 20.minutesToSeconds()
        let status = TargetOverridePolicy.status(
            of: override(endedAt: bolusAt, endReason: .manualBolus, bolusSyncIdentifier: "manual-1"),
            at: startedAt + 21.minutesToSeconds(),
            doses: []
        )
        #expect(status == .ended(at: bolusAt, reason: .manualBolus, bolusSyncIdentifier: "manual-1"))
    }

    // MARK: - isActive

    @Test func isActiveIsOpenAndBeforeExpiry() {
        #expect(override().isActive(at: expiresAt - 1))
        #expect(!override().isActive(at: expiresAt))
        #expect(!override(endedAt: startedAt + 1, endReason: .cancelled).isActive(at: startedAt + 2))
    }
}
