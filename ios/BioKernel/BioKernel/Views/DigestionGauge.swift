//
//  DigestionGauge.swift
//  BioKernel
//
//  Created by Sam King on 4/23/24.
//

import SwiftUI

struct DigestionGauge: View {
    let current: Double
    let minValue = 0.0
    let maxValue = 100.0

    let gradient = Gradient(colors: [AppColors.green, AppColors.yellow, AppColors.orange, AppColors.red])
    

    var body: some View {
        ZStack {
            Gauge(value: current.clamp(low: minValue, high: maxValue), in: minValue...maxValue) {
                
            } currentValueLabel: {
                Text("\(Int(current))")
                    .foregroundColor(.white)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gradient)
            
            let angle = ((current.clamp(low: minValue, high: maxValue) - minValue) / (maxValue - minValue) * 270 - 135)
            
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .offset(y: -27)
                .rotationEffect(.degrees(angle))
        }
    }
}

struct InsulinActionGauge: View {
    let current: Double
    let minValue = 0.0
    let maxValue = 2.5

    let gradient = Gradient(colors: [AppColors.green, AppColors.yellow, AppColors.orange, AppColors.red])
    

    var body: some View {
        ZStack {
            Gauge(value: current.clamp(low: minValue, high: maxValue), in: minValue...maxValue) {
                
            } currentValueLabel: {
                Text(String(format: "%0.02f", current))
                    .foregroundColor(.white)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gradient)
            let angle = ((current.clamp(low: minValue, high: maxValue) - minValue) / (maxValue - minValue) * 270 - 135)
            
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .offset(y: -27)
                .rotationEffect(.degrees(angle))
        }
    }
}

struct IoBGauge: View {
    let current: Double
    let minValue = 0.0
    let maxValue = 7.5

    let gradient = Gradient(colors: [AppColors.green, AppColors.yellow, AppColors.orange, AppColors.red])
    

    var body: some View {
        ZStack {
            Gauge(value: current.clamp(low: minValue, high: maxValue), in: minValue...maxValue) {
                
            } currentValueLabel: {
                Text(String(format: "%0.01f", current))
                    .foregroundColor(.white)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gradient)
            
            let angle = ((current.clamp(low: minValue, high: maxValue) - minValue) / (maxValue - minValue) * 270 - 135)
            
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
                .offset(y: -27)
                .rotationEffect(.degrees(angle))
        }
    }
}

#Preview {
    HStack {
        DigestionGauge(current: -11.0).background(.blue)
        InsulinActionGauge(current: 1.1).background(.blue)
    }
}
