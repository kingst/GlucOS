//
//  GlucoseChartView.swift
//  LoopViewer
//
//  Created by Sam King on 3/4/23.
//  Copyright © 2023 Sam King. All rights reserved.
//
import Charts
import SwiftUI

struct GlucoseChartView: View {
    @EnvironmentObject var appState: AppObservableState
    var selectedHours: Int

    private var maxY: Int {
        let readings = appState.glucoseChartData.map({ $0.readingInMgDl }) + appState.filteredGlucoseChartData.map({ $0.glucose })
        let maxReading = readings.max() ?? 300
        if maxReading > 300 {
            return 400
        } else if maxReading > 200 {
            return 300
        } else {
            return 200
        }
    }

    private var timeWindow: (min: Date, max: Date) {
        let max = Date()
        let min = max - 24.hoursToSeconds()
        return (min, max)
    }

    private var strideInHours: Int {
        return selectedHours > 6 ? 2 : 1
    }

    /// One point of the target line (dev/backlog/meal-soon.md §7.4).
    ///
    /// `series` is what keeps the runs separate: each contiguous run of ticks
    /// in one colour gets its own id, so the settings target on either side of
    /// an override, two overrides an hour apart, or a meal soon superseded by
    /// an exercise soon draw as separate segments and not one line joined
    /// across the gap. `legend` is the name the colour scale and the legend key
    /// off.
    ///
    /// `id` is the point's position in the line and not its time: the point
    /// that closes one run and the point that opens the next can share a time.
    struct TargetPoint: Identifiable, Equatable {
        let at: Date
        let targetMgDl: Double
        let series: String
        let legend: String
        let id: Int
    }

    static let targetLegend = "Target"

    /// The settings that move the target, which are the ones that always have
    /// a legend entry. Digestion and post exercise only scale dosing, so
    /// there is nothing of theirs to draw here.
    private static let targetKinds = TargetOverrideKind.allCases.filter { $0.movesTarget }

    /// The target line: the one target each tick dosed toward. A tick whose
    /// override moved the target draws at the override's target in that
    /// policy's colour, and every other tick draws at the settings target in
    /// grey. So the grey line stops where an override starts and picks up
    /// again where it ends, and the two are never drawn over the same stretch.
    /// A policy this build does not know draws as "Override".
    ///
    /// A run is a stretch of consecutive ticks in one colour. Each run is
    /// carried forward to the first tick of the run after it, because a tick's
    /// target stands until the next tick, but no further than
    /// `maxLoopSpacing` past its own last tick: if the loop stopped during an
    /// override and came back hours after it expired, the run ends where the
    /// loop stopped and the stretch with no ticks is left empty. The newest
    /// run has nothing after it to be carried to, and a run of a single tick
    /// is one point, which `isolated` draws.
    ///
    /// Rows written before schema v2 recorded no target: they are skipped and
    /// end the run.
    static func targetPoints(for readings: [FilteredGlucose]) -> [TargetPoint] {
        var points: [TargetPoint] = []
        var run = 0
        var previous: TargetPoint? = nil
        for reading in readings {
            guard let settingsTarget = reading.targetMgDl else {
                previous = nil
                continue
            }
            let legend: String
            let target: Double
            if let overrideTarget = reading.overrideTargetMgDl {
                legend = OverrideAppearance.title(forPolicy: reading.overridePolicy)
                target = overrideTarget
            } else {
                legend = targetLegend
                target = settingsTarget
            }
            if previous?.legend != legend {
                if let previous {
                    let closesAt = min(reading.at, previous.at + maxLoopSpacing)
                    points.append(TargetPoint(at: closesAt, targetMgDl: previous.targetMgDl, series: previous.series, legend: previous.legend, id: points.count))
                }
                run += 1
            }
            let point = TargetPoint(at: reading.at, targetMgDl: target, series: "\(legend) \(run)", legend: legend, id: points.count)
            points.append(point)
            previous = point
        }
        return points
    }

    /// The runs of the target line that are a single point. A line through
    /// one point draws nothing, so these are drawn as points instead. It is
    /// the newest run until its second tick, the grey settings line included.
    static func isolated(_ points: [TargetPoint]) -> [TargetPoint] {
        let runLengths = points.reduce(into: [String: Int]()) { $0[$1.series, default: 0] += 1 }
        return points.filter { runLengths[$0.series] == 1 }
    }

    /// One point of the purple filtered-glucose line.
    ///
    /// `series` is what breaks the line: successful loops close enough together
    /// to be consecutive share one, and the first loop after a miss starts the
    /// next, so each stretch draws as its own segment and not one line joined
    /// across the gap.
    private struct FilteredGlucosePoint: Identifiable {
        let at: Date
        let glucose: Double
        let series: String
        var id: Date { at }
    }

    /// The furthest apart two successful loops can be and still be joined.
    /// Loops run about every five minutes, so one missed loop leaves ten. It
    /// is also how far a run of the target line is carried past its last
    /// tick.
    static let maxLoopSpacing = 7.5.minutesToSeconds()

    /// The filtered-glucose line, split wherever a loop was missed.
    ///
    /// A loop that was skipped or never ran left no reading here at all, and
    /// one that hit a pump error is dropped below, so every kind of miss looks
    /// the same from here: more than `maxLoopSpacing` between two successful
    /// loops. A failed loop that is retried and succeeds inside that spacing
    /// is not a miss and does not break the line.
    private var filteredGlucosePoints: [FilteredGlucosePoint] {
        var points: [FilteredGlucosePoint] = []
        var run = 0
        var lastAt: Date? = nil
        for reading in appState.filteredGlucoseChartData where reading.dosed {
            if let lastAt, reading.at.timeIntervalSince(lastAt) > Self.maxLoopSpacing {
                run += 1
            }
            lastAt = reading.at
            points.append(FilteredGlucosePoint(at: reading.at, glucose: reading.glucose, series: "Filtered \(run)"))
        }
        return points
    }

    /// The successful loops with a miss on both sides. A line through a single
    /// point draws nothing, so these are drawn as points instead.
    private func isolated(_ points: [FilteredGlucosePoint]) -> [FilteredGlucosePoint] {
        let runLengths = points.reduce(into: [String: Int]()) { $0[$1.series, default: 0] += 1 }
        return points.filter { runLengths[$0.series] == 1 }
    }

    private func chart(geometry: GeometryProxy) -> some View {
        let filteredGlucose = filteredGlucosePoints
        let targets = Self.targetPoints(for: appState.filteredGlucoseChartData)
        // The five settings' colours are always in the legend. "Override" is
        // only there while a tick from a policy this build does not know is
        // on the chart.
        let showsUnknownPolicy = targets.contains { $0.legend == OverrideAppearance.unknownTitle }
        let legendDomain = [Self.targetLegend] + Self.targetKinds.map { $0.title } + (showsUnknownPolicy ? [OverrideAppearance.unknownTitle] : [])
        let legendRange = [Color.gray.opacity(0.6)] + Self.targetKinds.map { $0.color } + (showsUnknownPolicy ? [OverrideAppearance.color(forPolicy: nil)] : [])
        return Chart {
            AreaMark(x: .value("Time", timeWindow.min),
                     yStart: .value("Target range low", 70),
                     yEnd: .value("Target range high", 140))
            .foregroundStyle(.green)
            .opacity(0.25)
            AreaMark(x: .value("Time", timeWindow.max),
                     yStart: .value("Target range low", 70),
                     yEnd: .value("Target range high", 140))
            .foregroundStyle(.green)
            .opacity(0.25)

            // The target each tick dosed toward, as step lines under the
            // glucose points: a change reads as a step and not a ramp. Grey is
            // the settings target, and while an override moves the target the
            // line is that policy's colour at the override's target instead.
            ForEach(targets) { point in
                LineMark(x: .value("Time", point.at),
                         y: .value("mg/dL", point.targetMgDl),
                         series: .value("Run", point.series))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("Series", point.legend))
            }
            ForEach(Self.isolated(targets)) { point in
                PointMark(x: .value("Time", point.at),
                          y: .value("mg/dL", point.targetMgDl))
                    .symbolSize(10)
                    .foregroundStyle(by: .value("Series", point.legend))
            }

            ForEach(appState.glucoseChartData, id: \.created) { reading in
                PointMark(x: .value("Time", reading.created),
                         y: .value("mg/dL", reading.readingInMgDl))
                    .symbolSize(20)
                    .foregroundStyle(.blue)
            }
            ForEach(filteredGlucose) { point in
                LineMark(x: .value("Time", point.at),
                         y: .value("mg/dL", point.glucose),
                         series: .value("Run", point.series))
                    .symbolSize(5)
                    .foregroundStyle(.purple)
            }
            ForEach(isolated(filteredGlucose)) { point in
                PointMark(x: .value("Time", point.at),
                          y: .value("mg/dL", point.glucose))
                    .symbolSize(10)
                    .foregroundStyle(.purple)
            }
        }
        // avoid divide by 0
        .frame(width: geometry.size.width * CGFloat(24 / (selectedHours == 0 ? 4 : selectedHours)))
        .chartYScale(domain: 0...maxY)
        .chartXScale(domain: timeWindow.min...timeWindow.max)
        .chartForegroundStyleScale(domain: legendDomain, range: legendRange)
        // Trailing, because the chart is wider than the screen and opens
        // scrolled to its right edge; a leading legend would be off-screen.
        .chartLegend(position: .bottom, alignment: .trailing)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: strideInHours)) { value in
                AxisValueLabel(format: .dateTime.hour())
                AxisGridLine()
                AxisTick()
            }
        }
        .padding(.top, 10)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        chart(geometry: geometry)
                        Color.clear.frame(width: 1, height: 1).id("rightmost")
                    }
                }
                .onAppear {
                    proxy.scrollTo("rightmost", anchor: .trailing)
                }
                .onChange(of: selectedHours) {
                    proxy.scrollTo("rightmost", anchor: .trailing)
                }
            }
        }
    }
}

struct GlucoseChartView_Previews: PreviewProvider {
    static var previews: some View {
        GlucoseChartView(selectedHours: 4)
    }
}
