//
//  GlucoseChart.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI
import Charts

struct GlucoseChart: View {
    var body: some View {
        Chart {
            PointMark(
                x: .value("Time", 1),
                y: .value("Glucose", 98)
            )
            PointMark(
                x: .value("Time", 2),
                y: .value("Glucose", 102)
            )
            PointMark(
                x: .value("Time", 3),
                y: .value("Glucose", 105)
            )
            PointMark(
                x: .value("Time", 4),
                y: .value("Glucose", 111)
            )
        }
        .chartYScale(domain: 0...200)
        .frame(maxHeight: .infinity)
    }
}

#Preview {
    GlucoseChart()
}
