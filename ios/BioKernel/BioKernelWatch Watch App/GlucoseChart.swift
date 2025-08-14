//
//  GlucoseChart.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI
import Charts

struct GlucoseChart: View {
    @EnvironmentObject var stateViewModel: StateViewModel
    @State private var selectedHours = 2

    private var timeWindow: (start: Date, end: Date) {
        let end = Date()
        let start = end - 24.hoursToSeconds()
        return (start, end)
    }

    private var maxY: Int {
        let maxReading = stateViewModel.appState?.glucoseReadings.map({ $0.glucoseReadingInMgDl }).max() ?? 200.0
        if maxReading > 300 {
            return 400
        } else if maxReading > 200 {
            return 300
        } else {
            return 200
        }
    }

    private func chart(geometry: GeometryProxy, state: BioKernelState) -> some View {
        Chart {
            RectangleMark(
                xStart: .value("Time", timeWindow.start),
                xEnd: .value("Time", timeWindow.end),
                yStart: .value("Target range low", 70),
                yEnd: .value("Target range high", 140)
            )
            .foregroundStyle(.green)
            .opacity(0.25)

            ForEach(state.glucoseReadings, id: \.at) { reading in
                PointMark(
                    x: .value("Time", reading.at),
                    y: .value("Glucose", reading.glucoseReadingInMgDl)
                )
                .symbolSize(10)
                .foregroundStyle(.blue)
            }
        }
        // avoid divide by 0
        .frame(width: geometry.size.width * CGFloat(24 / (selectedHours == 0 ? 4 : selectedHours)))
        .chartYScale(domain: 0...maxY)
        .chartXScale(domain: timeWindow.start...timeWindow.end)
        .chartXVisibleDomain(length: Double(selectedHours).hoursToSeconds())
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(maxHeight: .infinity)
        .padding(.top, 10)
    }

    var body: some View {
        if let state = stateViewModel.appState {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            chart(geometry: geometry, state: state)
                            Color.clear.frame(width: 1, height: 1).id("rightmost")
                        }
                    }
                    .onTapGesture {
                        let timeRanges = [2, 4, 6, 12]
                        if let currentIndex = timeRanges.firstIndex(of: selectedHours) {
                            let nextIndex = (currentIndex + 1) % timeRanges.count
                            selectedHours = timeRanges[nextIndex]
                        }
                    }
                    .onChange(of: selectedHours, initial: true) {
                        proxy.scrollTo("rightmost", anchor: .trailing)
                    }
                }
            }
        } else {
            Text("No data available")
                .frame(maxHeight: .infinity)
        }
    }
}

#Preview {
    GlucoseChart()
}
