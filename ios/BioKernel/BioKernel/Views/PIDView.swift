
//
//  PIDView.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import SwiftUI
import Charts

struct PIDView: View {
    @EnvironmentObject var viewModel: DiagnosticViewModel
    @State private var selectedHours = 4
    
    private var timeWindow: (min: Date, max: Date) {
        let max = Date()
        let min = max - TimeInterval(24 * 3600)
        return (min, max)
    }
    
    private struct ChartPoint: Identifiable {
        let id = UUID()
        let at: Date
        let value: Double
        let type: String
    }
    
    private var pidChartPoints: [ChartPoint] {
        var points = [ChartPoint]()
        for data in viewModel.chartData {
            points.append(ChartPoint(at: data.at, value: data.proportionalContribution, type: "Proportional"))
            points.append(ChartPoint(at: data.at, value: data.derivativeContribution, type: "Derivative"))
            points.append(ChartPoint(at: data.at, value: data.integratorContribution, type: "Integral"))
            points.append(ChartPoint(at: data.at, value: data.totalPidContribution, type: "Total"))
        }
        return points
    }
    
    private var deltaGlucoseChartPoints: [ChartPoint] {
        var points = [ChartPoint]()
        for data in viewModel.chartData {
            points.append(ChartPoint(at: data.at, value: data.deltaGlucoseError, type: "Delta Glucose Error"))
            points.append(ChartPoint(at: data.at, value: data.accumulatedError, type: "Accumulated Error"))
        }
        return points
    }

    private var strideInHours: Int {
        return selectedHours > 6 ? 2 : 1
    }
    
    var body: some View {
        VStack {
            Picker("", selection: $selectedHours) {
                Text("2H").tag(2)
                Text("4H").tag(4)
                Text("6H").tag(6)
                Text("12H").tag(12)
            }
            .pickerStyle(SegmentedPickerStyle())
            
            DiagnosticChartScrollView(selectedHours: $selectedHours) {
                VStack {
                    Chart(pidChartPoints) {
                        LineMark(
                            x: .value("Time", $0.at),
                            y: .value("Value", $0.value)
                        )
                        .foregroundStyle(by: .value("Series", $0.type))
                    }
                    .chartXScale(domain: timeWindow.min...timeWindow.max)
                    .chartLegend(position: .bottom, alignment: .trailing)
                    
                    Chart(deltaGlucoseChartPoints) {
                        LineMark(
                            x: .value("Time", $0.at),
                            y: .value("Value", $0.value)
                        )
                        .foregroundStyle(by: .value("Series", $0.type))
                    }
                    .chartXScale(domain: timeWindow.min...timeWindow.max)
                    .chartLegend(position: .bottom, alignment: .trailing)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: strideInHours)) { value in
                        AxisValueLabel(format: .dateTime.hour())
                        AxisGridLine()
                        AxisTick()
                    }
                }
            }
        }
    }
}
