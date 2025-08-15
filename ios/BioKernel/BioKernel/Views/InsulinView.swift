
//
//  InsulinView.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import SwiftUI
import Charts

struct InsulinView: View {
    @EnvironmentObject var viewModel: DiagnosticViewModel
    @State private var selectedHours = 2
    
    private var timeWindow: (min: Date, max: Date) {
        let max = Date()
        let min = max - TimeInterval(selectedHours * 3600)
        return (min, max)
    }
    
    private struct ChartPoint: Identifiable {
        let id = UUID()
        let at: Date
        let value: Double
        let type: String
    }
    
    private var glucoseChartPoints: [ChartPoint] {
        var points = [ChartPoint]()
        for data in viewModel.chartData {
            points.append(ChartPoint(at: data.at, value: data.glucose, type: "Glucose"))
        }
        return points
    }
    
    private var iobChartPoints: [ChartPoint] {
        var points = [ChartPoint]()
        for data in viewModel.chartData {
            points.append(ChartPoint(at: data.at, value: data.insulinOnBoard, type: "IOB"))
            points.append(ChartPoint(at: data.at, value: data.basalRateInsulinOnBoard, type: "Basal Rate IOB"))
        }
        return points
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
            
            VStack {
                Chart(glucoseChartPoints) {
                    LineMark(
                        x: .value("Time", $0.at),
                        y: .value("Value", $0.value)
                    )
                    .foregroundStyle(by: .value("Series", $0.type))
                }
                .chartForegroundStyleScale(["Glucose": .blue])
                .chartXScale(domain: timeWindow.min...timeWindow.max)
                .chartLegend(position: .bottom, alignment: .leading)
                
                Chart(iobChartPoints) {
                    LineMark(
                        x: .value("Time", $0.at),
                        y: .value("Value", $0.value)
                    )
                    .foregroundStyle(by: .value("Series", $0.type))
                    .lineStyle(StrokeStyle(dash: $0.type == "Basal Rate IOB" ? [5, 5] : []))
                }
                .chartForegroundStyleScale(["IOB": .red, "Basal Rate IOB": .green])
                .chartXScale(domain: timeWindow.min...timeWindow.max)
                .chartLegend(position: .bottom, alignment: .leading)
            }.padding()
        }
    }
}
