//
//  MetricsView.swift
//  LoopViewerWatch Watch App
//
//  Created by Sam King on 3/5/23.
//  Copyright © 2023 Sam King. All rights reserved.
//

import SwiftUI

struct MetricsView: View {
    @EnvironmentObject var stateViewModel: StateViewModel
    @EnvironmentObject var workoutManager: WorkoutManager
    let smallFontSize: Font = .title2.monospacedDigit()
    
    var body: some View {
        TimelineView(MetricsTimelineSchedule(from: workoutManager.builder?.startDate ?? Date())) { context in
            VStack(spacing: 4) {
                // Header
                Text("Glucose")
                    .font(.body)
                    .bold()
                    .foregroundColor(.gray)
                
                // Glucose reading with trend and age
                HStack(spacing: 8) {
                    Text(stateViewModel.appState?.lastGlucoseString() ?? "-")
                        .font(.largeTitle)
                        .bold()
                    
                    Text("\(stateViewModel.appState?.minutesSinceLastReading() ?? 0)m")
                        .font(.footnote)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(stateViewModel.appState?.readingAgeColor() ?? Color.red)
                        .cornerRadius(4)
                }
                
                // time
                Text(workoutManager.builder?.elapsedTime.toHMS() ?? "-")
                    .font(.title2.monospacedDigit())
                
                MetricsGridView()
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

// Update your preview provider
struct MetricsView_Previews: PreviewProvider {
    static var previews: some View {
        let workoutManager = WorkoutManager.preview()
        let alertManager = GlucoseAlertManager(workoutManager: workoutManager)
        let stateViewModel = StateViewModel.preview(alertManager: alertManager)
        
        return MetricsView()
            .environmentObject(workoutManager)
            .environmentObject(stateViewModel)
    }
}

private struct MetricsTimelineSchedule: TimelineSchedule {
    var startDate: Date
    
    init(from startDate: Date) {
        self.startDate = startDate
    }
    
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> PeriodicTimelineSchedule.Entries {
        PeriodicTimelineSchedule(
            from: self.startDate,
            by: 1.0
        ).entries(from: startDate, mode: mode)
    }
}

extension TimeInterval {
    func toHMS() -> String {
        let t = Int(self)
        let hours = t / 60 / 60
        let minutes = (t - hours * 60 * 60) / 60
        let seconds = (t - hours * 60 * 60 - minutes * 60)
        return String(format: "%01d:%02d:%02d", hours, minutes, seconds)
    }
}

extension WorkoutManager {
    var workoutImage: Image {
        selectedWorkout?.image ?? Image(systemName: "figure.walk")
    }
}
