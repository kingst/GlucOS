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
    var body: some View {
        let maxY = { () -> Int in
            let maxReading = deviceManagerObservable.glucoseChartData.map({ $0.readingInMgDl }).max() ?? 300
            if maxReading > 300 {
                return 400
            } else if maxReading > 200 {
                return 300
            } else {
                return 200
            }
        }()
        let maxX = Date()
        let minX = maxX - 12.hoursToSeconds()
#if os(watchOS)
        let strideInHours = 3
#else
        let strideInHours = 2
#endif
        
        Chart {
            AreaMark(x: .value("Time", minX),
                     yStart: .value("Target range low", 70),
                     yEnd: .value("Target range high", 140))
            .foregroundStyle(.green)
            .opacity(0.25)
            AreaMark(x: .value("Time", maxX),
                     yStart: .value("Target range low", 70),
                     yEnd: .value("Target range high", 140))
            .foregroundStyle(.green)
            .opacity(0.25)

            ForEach(deviceManagerObservable.glucoseChartData, id: \.created) { reading in
                PointMark(x: .value("Time", reading.created),
                         y: .value("mg/dL", reading.readingInMgDl))
                    .symbolSize(10)  // Adjust the size of the points
                    .foregroundStyle(.blue)
            }
        }
        .chartYScale(domain: 0...maxY)
        .chartXScale(domain: minX...maxX)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: strideInHours)) { value in
                AxisValueLabel(format: .dateTime.hour())
                AxisGridLine()
                AxisTick()
            }
        }
    }
}


struct GlucoseChartView_Previews: PreviewProvider {
    static var previews: some View {
        GlucoseChartView()
    }
}
