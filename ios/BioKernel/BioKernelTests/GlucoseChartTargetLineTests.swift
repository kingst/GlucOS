//
//  GlucoseChartTargetLineTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/15/26.
//
//  The target line on the main glucose chart, as the points it is drawn
//  from: `GlucoseChartView.targetPoints(for:)` and `isolated(_:)`. A run is a
//  stretch of consecutive ticks in one colour. See dev/backlog/meal-soon.md
//  §7.4 and dev/backlog/override-mechanism.md, "The glucose chart".
//

import Testing
import Foundation
import SwiftUI
@testable import BioKernel

@MainActor
struct GlucoseChartTargetLineTests {

    let start = Date.f("2026-11-15 12:00:00 +0000")

    // MARK: - Fixtures

    private func at(_ minutes: Double) -> Date {
        return start + minutes.minutesToSeconds()
    }

    /// One tick. The settings target is 90 unless a test says otherwise.
    private func tick(_ minutes: Double, targetMgDl: Double? = 90, overridePolicy: String? = nil, overrideTargetMgDl: Double? = nil) -> FilteredGlucose {
        return FilteredGlucose(
            glucose: 120,
            at: at(minutes),
            dosed: true,
            targetMgDl: targetMgDl,
            overridePolicy: overridePolicy,
            overrideTargetMgDl: overrideTargetMgDl
        )
    }

    /// The points without their ids, which are positions and say nothing a
    /// test wants to spell out.
    private struct Point: Equatable {
        let minutes: Double
        let targetMgDl: Double
        let series: String
    }

    private func points(_ readings: [FilteredGlucose]) -> [Point] {
        return GlucoseChartView.targetPoints(for: readings).map {
            Point(minutes: $0.at.timeIntervalSince(start) / 60, targetMgDl: $0.targetMgDl, series: $0.series)
        }
    }

    // MARK: - Runs

    /// The grey line stops where an override starts and picks up again where
    /// it ends. Each run is carried to the first tick of the run after it,
    /// because a tick's target stands until the next tick.
    @Test func eachRunIsCarriedToTheFirstTickOfTheNextRun() {
        let readings = [
            tick(0),
            tick(5),
            tick(10, overridePolicy: "mealSoon", overrideTargetMgDl: 75),
            tick(15, overridePolicy: "mealSoon", overrideTargetMgDl: 75),
            tick(20)
        ]
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 5, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 10, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 10, targetMgDl: 75, series: "Meal soon 2"),
            Point(minutes: 15, targetMgDl: 75, series: "Meal soon 2"),
            Point(minutes: 20, targetMgDl: 75, series: "Meal soon 2"),
            Point(minutes: 20, targetMgDl: 90, series: "Target 3")
        ])

        let drawn = GlucoseChartView.targetPoints(for: readings)
        #expect(drawn.map { $0.id } == Array(0..<7), "positions, so two points at one time are still two")
        #expect(drawn.map { $0.legend } == ["Target", "Target", "Target", "Meal soon", "Meal soon", "Meal soon", "Target"])
    }

    /// The loop stops ten minutes into Exercise and comes back three hours
    /// later, long after it expired. The coloured segment ends where the
    /// loop stopped, one loop spacing past its last tick, and is not drawn
    /// across the three hours with no ticks.
    @Test func aRunIsNotCarriedAcrossAGapInTheLoop() {
        let readings = [
            tick(0, overridePolicy: "exercise", overrideTargetMgDl: 140),
            tick(5, overridePolicy: "exercise", overrideTargetMgDl: 140),
            tick(10, overridePolicy: "exercise", overrideTargetMgDl: 140),
            tick(190),
            tick(195)
        ]
        let spacing = GlucoseChartView.maxLoopSpacing / 60
        #expect(spacing == 7.5)
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 140, series: "Exercise 1"),
            Point(minutes: 5, targetMgDl: 140, series: "Exercise 1"),
            Point(minutes: 10, targetMgDl: 140, series: "Exercise 1"),
            Point(minutes: 10 + spacing, targetMgDl: 140, series: "Exercise 1"),
            Point(minutes: 190, targetMgDl: 90, series: "Target 2"),
            Point(minutes: 195, targetMgDl: 90, series: "Target 2")
        ])
    }

    /// The grey line the same way: the settings target is not drawn across a
    /// gap into an override that started while the loop was down.
    @Test func theSettingsRunIsNotCarriedAcrossAGapEither() {
        let readings = [
            tick(0),
            tick(60, overridePolicy: "exerciseSoon", overrideTargetMgDl: 140),
            tick(65, overridePolicy: "exerciseSoon", overrideTargetMgDl: 140)
        ]
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 7.5, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 60, targetMgDl: 140, series: "Exercise soon 2"),
            Point(minutes: 65, targetMgDl: 140, series: "Exercise soon 2")
        ])
    }

    /// One missed loop is inside the spacing that still joins two ticks, so
    /// the run is carried the whole way to the next run's first tick.
    @Test func aRunIsCarriedTheWholeWayAcrossOneLoopSpacing() {
        let readings = [
            tick(0, overridePolicy: "mealSoon", overrideTargetMgDl: 75),
            tick(7)
        ]
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 75, series: "Meal soon 1"),
            Point(minutes: 7, targetMgDl: 75, series: "Meal soon 1"),
            Point(minutes: 7, targetMgDl: 90, series: "Target 2")
        ])
    }

    // MARK: - A run of one point

    /// A line through one point draws nothing. The newest run has nothing
    /// after it to be carried to, so on its first tick it is one point, and
    /// it is drawn as a point until its second tick.
    @Test func theNewestRunIsAPointUntilItsSecondTick() {
        let firstTickOfMealSoon = [
            tick(0),
            tick(5),
            tick(10, overridePolicy: "mealSoon", overrideTargetMgDl: 75)
        ]
        let isolated = GlucoseChartView.isolated(GlucoseChartView.targetPoints(for: firstTickOfMealSoon))
        #expect(isolated.map { $0.series } == ["Meal soon 2"])
        #expect(isolated.map { $0.at } == [at(10)])
        #expect(isolated.map { $0.targetMgDl } == [75])

        let secondTick = firstTickOfMealSoon + [tick(15, overridePolicy: "mealSoon", overrideTargetMgDl: 75)]
        #expect(GlucoseChartView.isolated(GlucoseChartView.targetPoints(for: secondTick)).isEmpty)
    }

    /// The grey settings line included: the first tick the chart has, and
    /// the first tick back on the settings after an override ends.
    @Test func theSettingsLineIsAPointOnItsFirstTickToo() {
        let only = GlucoseChartView.targetPoints(for: [tick(0)])
        #expect(GlucoseChartView.isolated(only).map { $0.legend } == ["Target"])

        let backOnSettings = GlucoseChartView.targetPoints(for: [
            tick(0, overridePolicy: "exercise", overrideTargetMgDl: 140),
            tick(5, overridePolicy: "exercise", overrideTargetMgDl: 140),
            tick(10)
        ])
        #expect(GlucoseChartView.isolated(backOnSettings).map { $0.series } == ["Target 2"])
    }

    @Test func noReadingsDrawNothing() {
        #expect(GlucoseChartView.targetPoints(for: []).isEmpty)
        #expect(GlucoseChartView.isolated([]).isEmpty)
    }

    /// Rows written before schema v2 recorded no target. They are skipped
    /// and end the run, so nothing is drawn through them.
    @Test func aTickWithNoTargetEndsTheRun() {
        let readings = [
            tick(0),
            tick(5),
            tick(10, targetMgDl: nil),
            tick(15),
            tick(20)
        ]
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 5, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 15, targetMgDl: 90, series: "Target 2"),
            Point(minutes: 20, targetMgDl: 90, series: "Target 2")
        ])
    }

    // MARK: - Policies

    /// An override that only scales dosing has a policy identifier and no
    /// override target. The target it dosed toward is the settings target,
    /// so it is part of the grey line and does not break it.
    @Test func aDosingOnlyOverrideIsPartOfTheSettingsLine() {
        let readings = [
            tick(0),
            tick(5, overridePolicy: "digestion"),
            tick(10, overridePolicy: "digestion"),
            tick(15)
        ]
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 5, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 10, targetMgDl: 90, series: "Target 1"),
            Point(minutes: 15, targetMgDl: 90, series: "Target 1")
        ])
    }

    /// A segment is named by its policy identifier. One this build does not
    /// know, or a tick that moved the target and named nothing, is
    /// "Override" at the target it dosed toward. It still draws.
    @Test func aPolicyThisBuildDoesNotKnowDrawsAsOverride() {
        let readings = [
            tick(0, overridePolicy: "some-future-source", overrideTargetMgDl: 110),
            tick(5, overridePolicy: "some-future-source", overrideTargetMgDl: 110),
            tick(10, overridePolicy: nil, overrideTargetMgDl: 120),
            tick(15)
        ]
        let drawn = GlucoseChartView.targetPoints(for: readings)
        #expect(drawn.map { $0.legend } == ["Override", "Override", "Override", "Override", "Target"])
        #expect(drawn.map { $0.targetMgDl } == [110, 110, 120, 120, 90])
        #expect(Set(drawn.dropLast().map { $0.series }) == ["Override 1"], "one colour, so one run")
        #expect(OverrideAppearance.unknownTitle == "Override")
    }

    /// One override superseded by another draws as two segments in two
    /// colours, joined where the second starts.
    @Test func oneOverrideSupersededByAnotherIsTwoRuns() {
        let readings = [
            tick(0, overridePolicy: "mealSoon", overrideTargetMgDl: 75),
            tick(5, overridePolicy: "exerciseSoon", overrideTargetMgDl: 140),
            tick(10, overridePolicy: "exerciseSoon", overrideTargetMgDl: 140)
        ]
        #expect(points(readings) == [
            Point(minutes: 0, targetMgDl: 75, series: "Meal soon 1"),
            Point(minutes: 5, targetMgDl: 75, series: "Meal soon 1"),
            Point(minutes: 5, targetMgDl: 140, series: "Exercise soon 2"),
            Point(minutes: 10, targetMgDl: 140, series: "Exercise soon 2")
        ])
    }

    /// The names the chart and every other screen use, by policy identifier.
    @Test func titlesAreLookedUpByPolicyIdentifier() {
        #expect(OverrideAppearance.title(forPolicy: "mealSoon") == "Meal soon")
        #expect(OverrideAppearance.title(forPolicy: "digestion") == "Digestion")
        #expect(OverrideAppearance.title(forPolicy: "exerciseSoon") == "Exercise soon")
        #expect(OverrideAppearance.title(forPolicy: "exercise") == "Exercise")
        #expect(OverrideAppearance.title(forPolicy: "postExercise") == "Post exercise")
        #expect(OverrideAppearance.title(forPolicy: "some-future-source") == "Override")
        #expect(OverrideAppearance.title(forPolicy: nil) == "Override")

        #expect(OverrideAppearance.bannerTitle(forPolicy: "mealSoon") == "Meal happening soon")
        #expect(OverrideAppearance.bannerTitle(forPolicy: "some-future-source") == "Override")
        for kind in TargetOverrideKind.allCases {
            #expect(OverrideAppearance.title(forPolicy: kind.policyIdentifier) == kind.title)
            #expect(OverrideAppearance.bannerTitle(forPolicy: kind.policyIdentifier) == kind.bannerTitle)
            #expect(OverrideAppearance.color(forPolicy: kind.policyIdentifier) == kind.color)
        }
        #expect(OverrideAppearance.color(forPolicy: "some-future-source") == AppColors.graphite)
    }
}
