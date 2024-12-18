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
    let smallFontSize: Font = .title3
    
    var body: some View {
        TimelineView(MetricsTimelineSchedule(from: workoutManager.builder?.startDate ?? Date())) { context in
            VStack(spacing: 8) {
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
                
                // Metrics grid
                HStack(spacing: 8) {
                    // Distance
                    VStack {
                        workoutManager.workoutImage
                            .font(smallFontSize)
                            .foregroundColor(.teal)
                        HStack(spacing: 2) {
                            Text(Measurement(
                                value: workoutManager.distance,
                                unit: UnitLength.meters
                            ).formatted(.measurement(width: .abbreviated, usage: .road)))
                            .font(smallFontSize)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    // Heart Rate
                    VStack {
                        Image(systemName: "heart.fill")
                            .font(smallFontSize)
                            .foregroundColor(.red)
                        Text("\(workoutManager.heartRate.formatted(.number.precision(.fractionLength(0))))")
                            .font(smallFontSize)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}

// Update your preview provider
struct MetricsView_Previews: PreviewProvider {
    static var previews: some View {
        MetricsView()
            .environmentObject(WorkoutManager.preview())
            .environmentObject(StateViewModel.preview())
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
        guard let workout = selectedWorkout else {
            return Image(systemName: "figure.walk") // default icon
        }
        
        switch workout.activityType {
        case .running:
            return Image(systemName: "figure.run")
        case .walking:
            return Image(systemName: "figure.walk")
        case .cycling:
            return Image(systemName: "figure.outdoor.cycle")
        case .swimming:
            return Image(systemName: "figure.pool.swim")
        case .hiking:
            return Image(systemName: "figure.hiking")
        case .yoga:
            return Image(systemName: "figure.mind.and.body")
        case .functionalStrengthTraining:
            return Image(systemName: "figure.strengthtraining.traditional")
        case .traditionalStrengthTraining:
            return Image(systemName: "dumbbell.fill")
        case .softball:
            return Image(systemName: "baseball.fill")
        case .baseball:
            return Image(systemName: "baseball.fill")
        case .basketball:
            return Image(systemName: "basketball.fill")
        default:
            return Image(systemName: "figure.walk")
        }
    }
}
