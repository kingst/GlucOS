//
//  MetricsGridView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/18/24.
//

import SwiftUI

struct MetricsGridView: View {
    @EnvironmentObject var workoutManager: WorkoutManager
    @EnvironmentObject var stateViewModel: StateViewModel
    
    private let labelFont: Font = .title3
    private let valueFont: Font = .title2
    
    var body: some View {
        Grid(horizontalSpacing: 4) {
            // Icons row
            GridRow {
                workoutManager.workoutImage
                    .font(labelFont)
                    .foregroundColor(.teal)
                    .gridColumnAlignment(.center)
                    .frame(maxWidth: .infinity)
                
                Text("Pred")
                    .font(labelFont)
                    .gridColumnAlignment(.center)
                    .frame(maxWidth: .infinity)
                
                Image(systemName: "heart.fill")
                    .font(labelFont)
                    .foregroundColor(.red)
                    .gridColumnAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            
            // Values row
            GridRow {
                Text(Measurement(
                    value: workoutManager.distance,
                    unit: UnitLength.meters
                ).formatted(.measurement(width: .abbreviated, usage: .road)))
                .font(valueFont)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.5)
                
                PredictionValueView(fontSize: valueFont)
                    .frame(maxWidth: .infinity)
                
                Text(workoutManager.heartRate.formatted(.number.precision(.fractionLength(0))))
                    .font(valueFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct PredictionValueView: View {
    @EnvironmentObject var stateViewModel: StateViewModel
    let fontSize: Font
    
    private var predictionText: String {
        if let prediction = stateViewModel.appState?.predictedGlucose {
            return String(format: "%0.0f", prediction)
        }
        return "-"
    }
    
    private var textColor: Color {
        guard let isInRange = stateViewModel.appState?.isPredictedGlucoseInRange else { return .blue }
        return isInRange ? .blue : .yellow
    }
    
    var body: some View {
        Text(predictionText)
            .font(fontSize)
            .lineLimit(1)
            .foregroundColor(textColor)
    }
}

#Preview {
    let workoutManager = WorkoutManager()
    let alertManager = GlucoseAlertManager(workoutManager: workoutManager)
    let viewModel = StateViewModel(alertManager: alertManager)
    MetricsGridView()
        .environmentObject(workoutManager)
        .environmentObject(viewModel)
}
