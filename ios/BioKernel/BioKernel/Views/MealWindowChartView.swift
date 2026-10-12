//
//  MealWindowChartView.swift
//  BioKernel
//
//  One meal's window: 30 minutes before through 3.5 hours after, glucose on
//  top and insulin on board below. Shared by the meal detail screen and the
//  announcement screen, which shows the reference meal's window underneath its
//  recommendation so the number has visible evidence behind it.
//
//  Borrowed from ClueClue's MealWindowChart, and deliberately the leaner of the
//  two: same two stacked charts, same shared x domain, same in-range band, but
//  GlucOS's palette.
//
//  Events reach the picture two ways. The meal, the user's own boluses and the
//  outcome get the marker rail — a dashed rule with a glyph on top. The loop's
//  automatic boluses get a bead on the glucose trace instead, because there can
//  be one every five minutes and a rail of those hides the events the screen is
//  about. Both kinds keep their row in the timeline underneath.
//

import Charts
import SwiftUI

struct MealWindowChartView: View {
    let meal: StoredMeal
    let data: MealWindowData

    /// The in-range band, matching the loop's own chart.
    private static let inRangeLow = 70.0
    private static let inRangeHigh = 140.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            glucoseChart
                .frame(height: 180)
            Text("INSULIN ON BOARD")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .kerning(0.6)
            iobChart
                .frame(height: 70)
            legend
        }
        .padding(MealStyle.cardPadding)
        .background(
            MealStyle.surface,
            in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
        )
    }

    /// Names what's in the picture. Without it the IOB area, the target band
    /// and the beads on the trace read as decoration.
    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(color: .blue, label: "Glucose")
            legendItem(color: AppColors.deepIndigo, label: "IOB")
            legendItem(color: AppColors.green, label: "Target")
            // Only on a window that has some. A legend entry for a mark that
            // isn't in the picture is noise, and this is the one mark a reader
            // has no reason to be looking for.
            if !automaticBolusPoints.isEmpty {
                automaticBolusLegendItem
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var automaticBolusLegendItem: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.blue)
                .frame(width: Self.beadDiameter, height: Self.beadDiameter)
            Text("Auto bolus")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 4)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var glucoseChart: some View {
        Chart {
            RectangleMark(
                xStart: .value("Start", data.start),
                xEnd: .value("End", data.end),
                yStart: .value("Range low", Self.inRangeLow),
                yEnd: .value("Range high", Self.inRangeHigh)
            )
            .foregroundStyle(AppColors.green)
            .opacity(0.25)

            // One dashed rule per event, with the glyphs riding on top — the
            // marker row in the figure. Events under 15 minutes apart would
            // overlap at this scale (a meal and its bolus usually share a
            // timestamp exactly), so a cluster's rule carries a vertical stack
            // of every glyph in it and the rest draw bare.
            ForEach(markerEvents) { event in
                if let stacked = markerStacks[event.id] {
                    RuleMark(x: .value("Event", event.at))
                        .foregroundStyle(MealStyle.line)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                        .annotation(position: .top, spacing: 2) {
                            VStack(spacing: 2) {
                                ForEach(stacked) { MealEventGlyph(event: $0, size: 18) }
                            }
                            .frame(height: 18, alignment: .top)
                        }
                } else {
                    RuleMark(x: .value("Event", event.at))
                        .foregroundStyle(MealStyle.line)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
            }

            ForEach(data.glucose, id: \.self) { point in
                LineMark(
                    x: .value("Time", point.at),
                    y: .value("mg/dL", point.glucoseInMgDl)
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .interpolationMethod(.monotone)
            }

            // The loop's own boluses, riding on the trace in the trace's
            // colour. After the line so they sit on top of it, and part of it
            // rather than annotating it: what they say is *when* the loop
            // stepped in, against the glucose that made it.
            ForEach(Array(automaticBolusPoints.enumerated()), id: \.offset) { _, point in
                PointMark(
                    x: .value("Time", point.at),
                    y: .value("mg/dL", point.glucoseInMgDl)
                )
                .foregroundStyle(.blue)
                .symbol(.circle)
                .symbolSize(Self.beadArea)
            }
        }
        .chartXScale(domain: data.start...data.end)
        .chartYScale(domain: 0...glucoseTop)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [70.0, 140.0, 200.0, 300.0]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                AxisValueLabel {
                    if let glucose = value.as(Double.self) {
                        Text(String(Int(glucose)))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }

    private var iobChart: some View {
        Chart {
            ForEach(data.iob, id: \.self) { sample in
                AreaMark(
                    x: .value("Time", sample.at),
                    y: .value("IOB", sample.units)
                )
                .foregroundStyle(AppColors.primary)
                .opacity(0.2)
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", sample.at),
                    y: .value("IOB", sample.units)
                )
                .foregroundStyle(AppColors.deepIndigo)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
        }
        // The same domain as the chart above, so the two read as one picture.
        .chartXScale(domain: data.start...data.end)
        .chartYScale(domain: 0...iobTop)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 1)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel(format: .dateTime.hour(), anchor: .top)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                AxisValueLabel {
                    if let units = value.as(Double.self) {
                        Text("\(String(format: "%0.1f", units))u")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }

    /// The 70–300 span always visible so windows are comparable at a glance,
    /// expanding only when the trace leaves it.
    private var glucoseTop: Double {
        let peak = data.glucose.map { $0.glucoseInMgDl }.max() ?? 300
        return peak > 300 ? 400 : 300
    }

    private var iobTop: Double {
        let peak = data.iob.map { $0.units }.max() ?? 1
        return max(1, peak * 1.2)
    }

    /// A bead's diameter, and the same value as the area Swift Charts wants
    /// for the symbol — near enough at this size, and it keeps the legend
    /// swatch and the mark from drifting apart.
    private static let beadDiameter: CGFloat = 7.0
    private static let beadArea: CGFloat = 36.0

    /// The events that get a rule and a glyph. See
    /// `MealWindowEvent.hasChartMarker` for what is left out and why.
    private var markerEvents: [MealWindowEvent] {
        return data.events.filter { $0.hasChartMarker }
    }

    /// Each automatic bolus placed on the glucose trace at the moment it was
    /// given.
    ///
    /// The height is linearly interpolated between the readings either side,
    /// so a bolus between two CGM ticks lands on the line rather than on the
    /// nearest reading. One that falls outside the readings entirely — before
    /// the first, after the last, or in a window with no CGM data at all — is
    /// dropped: there is no trace to put it on, and the timeline below still
    /// lists it.
    private var automaticBolusPoints: [MealGlucosePoint] {
        return data.events.compactMap { event in
            guard case .bolus(let at, _, let isAutomatic) = event, isAutomatic else { return nil }
            guard let glucose = glucose(at: at) else { return nil }
            return MealGlucosePoint(at: at, glucoseInMgDl: glucose)
        }
    }

    /// The trace's height at an instant. `data.glucose` is in time order, from
    /// a store that sorts on read.
    private func glucose(at instant: Date) -> Double? {
        guard let first = data.glucose.first, instant >= first.at else { return nil }
        var previous = first
        for point in data.glucose {
            guard point.at < instant else {
                let span = point.at.timeIntervalSince(previous.at)
                guard span > 0 else { return point.glucoseInMgDl }
                let fraction = instant.timeIntervalSince(previous.at) / span
                return previous.glucoseInMgDl + fraction * (point.glucoseInMgDl - previous.glucoseInMgDl)
            }
            previous = point
        }
        // Past the last reading: the trace has already stopped.
        return nil
    }

    /// Chains events under 15 minutes apart into one cluster, keyed by its
    /// first event's id.
    private var markerStacks: [String: [MealWindowEvent]] {
        let chainGap = 15.0.minutesToSeconds()
        var stacks: [String: [MealWindowEvent]] = [:]
        var headID = ""
        var previous = Date.distantPast
        for event in markerEvents {
            if !headID.isEmpty, event.at.timeIntervalSince(previous) < chainGap {
                stacks[headID, default: []].append(event)
            } else {
                headID = event.id
                stacks[headID] = [event]
            }
            previous = event.at
        }
        return stacks
    }
}

/// An event's icon in a filled circle — the chart marker and the timeline
/// node, so the same event reads the same in both places.
struct MealEventGlyph: View {
    let event: MealWindowEvent
    var size: CGFloat = MealStyle.timelineGlyph

    var body: some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: event.iconName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(MealStyle.surface)
        }
        .frame(width: size, height: size)
    }

    private var color: Color {
        switch event {
        case .meal: return AppColors.primary
        case .bolus: return AppColors.deepIndigo
        case .outcome(let outcome, _):
            switch outcome {
            case .predictedLow: return AppColors.red
            case .roseTooHigh: return AppColors.orange
            case .onTarget, .unknown: return .gray
            }
        }
    }
}

/// The window's events as a connected vertical rail, in time order. Headers
/// and empty states stay with the callers, which label it differently.
struct MealWindowTimelineView: View {
    let events: [MealWindowEvent]
    /// The meal's own time — offsets are relative to it.
    let anchor: Date

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                MealTimelineRow(
                    event: event,
                    anchor: anchor,
                    isLast: index == events.count - 1
                )
            }
        }
    }
}

private struct MealTimelineRow: View {
    let event: MealWindowEvent
    let anchor: Date
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(MealStyle.time(event.at))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(MealStyle.offset(event.at, from: anchor))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: MealStyle.timelineTimeColumn, alignment: .trailing)
            .monospacedDigit()

            MealEventGlyph(event: event)

            card
                .padding(.bottom, isLast ? 0 : 12)
        }
        .background(alignment: .topLeading) {
            // Connector down to the next node, centered under the glyph.
            if !isLast {
                Rectangle()
                    .fill(MealStyle.line)
                    .frame(width: 2)
                    .padding(.top, MealStyle.timelineGlyph)
                    .offset(x: MealStyle.timelineTimeColumn + 12 + MealStyle.timelineGlyph / 2 - 1)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let badge = event.badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(Capsule().stroke(MealStyle.line, lineWidth: 1))
                }
            }
            if let detail = event.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            MealStyle.surface,
            in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
        )
    }
}
