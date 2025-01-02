//
//  ContentView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct WatchMainView: View {
    @EnvironmentObject private var workoutManager: WorkoutManager
    @State private var showingWorkout = false
    @State private var normalModeSelection = 0
    @State private var workoutModeSelection = 0
    
    var body: some View {
        if !showingWorkout {
            TabView(selection: $normalModeSelection) {
                VStack {
                    GlucoseView()
                    GlucoseChart()
                }
                .tag(0)
                StartWorkoutView(startWorkout: { workout in
                    workoutManager.requestAuthorization() { success in
                        if success {
                            workoutManager.selectedWorkout = workout
                            showingWorkout = true
                            workoutModeSelection = 1
                        }
                    }
                })
                .tag(1)
            }
        } else {
            TabView(selection: $workoutModeSelection) {
                ControlsView(stopWorkout: {
                    showingWorkout = false
                    normalModeSelection = 0
                }, afterLock: {
                    workoutModeSelection = 1
                })
                    .tag(0)
                MetricsView()
                    .tag(1)
                VStack {
                    GlucoseView()
                    GlucoseChart()
                }
                .tag(2)

            }
        }
    }
}

#Preview {
    WatchMainView()
}
