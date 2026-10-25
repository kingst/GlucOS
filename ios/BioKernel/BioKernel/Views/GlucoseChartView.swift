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
    /// `series` is what keeps separate overrides separate: each contiguous run
    /// of ticks from one override kind gets its own id, so two overrides an
    /// hour apart — or a meal soon superseded by an exercise — draw as separate
    /// segments and not one line joined across the gap. `legend` is the name
    /// the colour scale and the legend key off.
    private struct TargetPoint: Identifiable {
        let at: Date
        let targetMgDl: Double
        let series: String
        let legend: String
        var id: Date { at }
    }

    private static let targetLegend = "Target"

    /// The continuous line: every tick that recorded a target. Rows written
    /// before schema v2 have none and are skipped.
    private var targetPoints: [TargetPoint] {
        return appState.filteredGlucoseChartData.compactMap { reading in
            guard let target = reading.targetMgDl else { return nil }
            return TargetPoint(at: reading.at, targetMgDl: target, series: Self.targetLegend, legend: Self.targetLegend)
        }
    }

    /// Only the ticks whose target came from an override, drawn on top of the
    /// continuous line in that kind's colour.
    private var overridePoints: [TargetPoint] {
        var points: [TargetPoint] = []
        var run = 0
        var runKind: TargetOverrideKind? = nil
        for reading in appState.filteredGlucoseChartData {
            guard let target = reading.targetMgDl, let kind = reading.targetSource?.overrideKind else {
                runKind = nil
                continue
            }
            if kind != runKind {
                run += 1
                runKind = kind
            }
            points.append(TargetPoint(at: reading.at, targetMgDl: target, series: "\(kind.title) \(run)", legend: kind.title))
        }
        return points
    }

    private func chart(geometry: GeometryProxy) -> some View {
        Chart {
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

            // The target each tick dosed toward, as step lines under the glucose
            // points: a change reads as a step and not a ramp. During an
            // override both lines sit on the same values and the override
            // colour wins; outside one only the base line shows.
            ForEach(targetPoints) { point in
                LineMark(x: .value("Time", point.at),
                         y: .value("mg/dL", point.targetMgDl),
                         series: .value("Run", point.series))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("Series", point.legend))
            }
            ForEach(overridePoints) { point in
                LineMark(x: .value("Time", point.at),
                         y: .value("mg/dL", point.targetMgDl),
                         series: .value("Run", point.series))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(by: .value("Series", point.legend))
            }

            ForEach(appState.glucoseChartData, id: \.created) { reading in
                PointMark(x: .value("Time", reading.created),
                         y: .value("mg/dL", reading.readingInMgDl))
                    .symbolSize(20)
                    .foregroundStyle(.blue)
            }
            ForEach(appState.filteredGlucoseChartData, id: \.at) { reading in
                LineMark(x: .value("Time", reading.at),
                         y: .value("mg/dL", reading.glucose))
                    .symbolSize(5)
                    .foregroundStyle(.purple)
            }
        }
        // avoid divide by 0
        .frame(width: geometry.size.width * CGFloat(24 / (selectedHours == 0 ? 4 : selectedHours)))
        .chartYScale(domain: 0...maxY)
        .chartXScale(domain: timeWindow.min...timeWindow.max)
        .chartForegroundStyleScale([
            Self.targetLegend: Color.gray.opacity(0.6),
            TargetOverrideKind.mealSoon.title: TargetOverrideKind.mealSoon.color,
            TargetOverrideKind.exercise.title: TargetOverrideKind.exercise.color
        ])
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
