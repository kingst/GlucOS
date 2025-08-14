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
    @StateObject var deviceManagerObservable = getDeviceDataManager().observableObject()
    var selectedHours: Int

    private var maxY: Int {
        let readings = deviceManagerObservable.glucoseChartData.map({ $0.readingInMgDl }) + deviceManagerObservable.filteredGlucoseChartData.map({ $0.glucose })
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

            ForEach(deviceManagerObservable.glucoseChartData, id: \.created) { reading in
                PointMark(x: .value("Time", reading.created),
                         y: .value("mg/dL", reading.readingInMgDl))
                    .symbolSize(20)
                    .foregroundStyle(.blue)
            }
            ForEach(deviceManagerObservable.filteredGlucoseChartData, id: \.at) { reading in
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
