
//
//  MLView.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import SwiftUI
import Charts

struct MLView: View {
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
    
    private var insulinChartPoints: [ChartPoint] {
        var points = [ChartPoint]()
        for data in viewModel.chartData {
            points.append(ChartPoint(at: data.at, value: data.mlInsulin, type: "ML Insulin"))
            points.append(ChartPoint(at: data.at, value: data.physiologicalInsulin, type: "Physiological Insulin"))
            points.append(ChartPoint(at: data.at, value: data.actualInsulin, type: "Actual Insulin"))
        }
        return points
    }
    
    private var mlInsulinLastThreeHoursChartPoints: [ChartPoint] {
        var points = [ChartPoint]()
        for data in viewModel.chartData {
            points.append(ChartPoint(at: data.at, value: data.machineLearningInsulinLastThreeHours, type: "ML Insulin Last 3 Hours"))
            points.append(ChartPoint(at: data.at, value: data.basalRate * 3, type: "Basal Rate * 3"))
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
                Chart(insulinChartPoints) {
                    LineMark(
                        x: .value("Time", $0.at),
                        y: .value("Value", $0.value)
                    )
                    .foregroundStyle(by: .value("Series", $0.type))
                }
                .chartXScale(domain: timeWindow.min...timeWindow.max)
                
                Chart(mlInsulinLastThreeHoursChartPoints) {
                    LineMark(
                        x: .value("Time", $0.at),
                        y: .value("Value", $0.value)
                    )
                    .foregroundStyle(by: .value("Series", $0.type))
                    .lineStyle(StrokeStyle(dash: $0.type == "Basal Rate * 3" ? [5, 5] : []))
                }
                .chartForegroundStyleScale(["ML Insulin Last 3 Hours": .purple, "Basal Rate * 3": .green])
                .chartXScale(domain: timeWindow.min...timeWindow.max)
            }.padding()
        }
    }
}
