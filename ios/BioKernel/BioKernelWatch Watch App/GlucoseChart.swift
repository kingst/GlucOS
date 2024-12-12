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
    
    private var timeWindow: (start: Date, end: Date) {
        let end = Date()
        let start = end - 3.hoursToSeconds()
        return (start, end)
    }
    
    var body: some View {
        let maxY = { () -> Int in
            let maxReading = stateViewModel.appState?.glucoseReadings.map({ $0.glucoseReadingInMgDl }).max() ?? 200.0
            if maxReading > 300 {
                return 400
            } else if maxReading > 200 {
                return 300
            } else {
                return 200
            }
        }()
        if let state = stateViewModel.appState {
            Chart {
                AreaMark(x: .value("Time", timeWindow.start),
                         yStart: .value("Target range low", 70),
                         yEnd: .value("Target range high", 140))
                .foregroundStyle(.green)
                .opacity(0.25)
                AreaMark(x: .value("Time", timeWindow.end),
                         yStart: .value("Target range low", 70),
                         yEnd: .value("Target range high", 140))
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
            .chartYScale(domain: 0...maxY)
            .chartXScale(domain: timeWindow.start...timeWindow.end)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            Text("No data available")
                .frame(maxHeight: .infinity)
        }
    }
}

#Preview {
    GlucoseChart()
}
