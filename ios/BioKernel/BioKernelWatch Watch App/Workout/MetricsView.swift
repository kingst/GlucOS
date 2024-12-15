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
    
    var body: some View {
        TimelineView(MetricsTimelineSchedule(from: workoutManager.builder?.startDate ?? Date())) { context in
            VStack(alignment: .leading) {
                Text(workoutManager.builder?.elapsedTime.toHMS() ?? "-")
                HStack {
                    Text("\(stateViewModel.appState?.lastGlucoseString() ?? "-")")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .minimumScaleFactor(0.3)
                        .lineLimit(1)
                    VStack {
                        HStack {
                            Text("mg/dL")
                            Spacer()
                        }
                        LastReadingTimeView(updateTrigger: context.date)
                    }.font(.caption)
                }.foregroundColor(.yellow)
                Text("\(workoutManager.heartRate.formatted(.number.precision(.fractionLength(0)))) bpm")
                Text(
                    Measurement(
                        value: workoutManager.distance,
                        unit: UnitLength.meters
                    ).formatted(.measurement(width: .abbreviated, usage: .road))
                )
            }.font(.title2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scenePadding()
        }
    }
}

struct MetricsView_Previews: PreviewProvider {
    static var previews: some View {
        MetricsView()
            .environmentObject(WorkoutManager())
            .environmentObject(StateViewModel())
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
        
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
