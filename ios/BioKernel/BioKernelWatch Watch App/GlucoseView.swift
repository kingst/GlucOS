//
//  GlucoseView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct GlucoseView: View {
    @EnvironmentObject var stateViewModel: StateViewModel
    
    var body: some View {
        VStack {
            HStack {
                VStack {
                    Text("IoB").font(.caption)
                    if let iob = stateViewModel.appState?.insulinOnBoard, iob > 0.05 {
                        Text(String(format: "%0.1f", iob))
                            .font(.title3)
                            .foregroundColor(.blue)
                    } else {
                        Text("-")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack {
                    if let glucose = stateViewModel.appState?.glucoseReadings.last {
                        let trend = glucose.trend ?? ""
                        Text("\(String(format: "%0.0f", glucose.glucoseReadingInMgDl))\(trend)")
                            .font(.title2)
                            .minimumScaleFactor(0.3)
                            .lineLimit(1)
                    } else {
                        Text("-").font(.title2)
                    }
                    Text("mg/dl").font(.system(size: 10))
                }
                .frame(maxWidth: .infinity)
                VStack {
                    Text("Pred").font(.caption)
                    if let prediction = stateViewModel.appState?.predictedGlucose, let isPredictedGlucoseInRange = stateViewModel.appState?.isPredictedGlucoseInRange {
                        let color: Color = isPredictedGlucoseInRange ? .blue : .yellow
                        Text("\(String(format: "%0.0f", prediction))")
                            .font(.title3)
                            .foregroundColor(color)
                    } else {
                        Text("-")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview {
    let workoutManager = WorkoutManager.preview()
    let alertManager = GlucoseAlertManager(workoutManager: workoutManager)
    let viewModel = StateViewModel.preview(alertManager: alertManager)
        
    GlucoseView()
        .environmentObject(viewModel)
        .environmentObject(workoutManager)
}
