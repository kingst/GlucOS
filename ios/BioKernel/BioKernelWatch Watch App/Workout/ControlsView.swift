//
//  ControlsView.swift
//  LoopViewerWatch Watch App
//
//  Created by Sam King on 3/5/23.
//  Copyright © 2023 Sam King. All rights reserved.
//

import SwiftUI

struct ControlsView: View {
    let stopWorkout: () -> Void
    let afterLock: () -> Void

    @EnvironmentObject var workoutManager: WorkoutManager
    @State var showingEndWorkoutAlert = false
    
    var body: some View {
        VStack {
            HStack {
                VStack {
                    Button(action: { showingEndWorkoutAlert = true }) {
                        Image(systemName: "xmark")
                    }
                    .tint(.red)
                    .font(.title2)
                    Text("End")
                }
                VStack {
                    Button(action: { workoutManager.togglePause() }) {
                        Image(systemName: workoutManager.running ? "pause" : "play")
                    }
                    .tint(.yellow)
                    .font(.title2)
                    Text(workoutManager.running ? "Pause" : "Resume")
                }
            }
            VStack {
                Button {
                    workoutManager.lock()
                    afterLock()
                } label: {
                    Image(systemName: "lock")
                }
                .tint(.blue)
                .font(.title2)
                Text("Lock")
            }
        }
        .confirmationDialog("End Workout?", isPresented: $showingEndWorkoutAlert, titleVisibility: .visible) {
            Button("Save Workout", role: .none) {
                workoutManager.end(save: true)
                stopWorkout()
            }
            Button("Discard Workout", role: .destructive) {
                workoutManager.end(save: false)
                stopWorkout()
            }
            Button("Resume Workout", role: .cancel) {
                // Do nothing, just dismiss
            }
        } message: {
            
        }
    }
}

struct ControlsView_Previews: PreviewProvider {
    static var previews: some View {
        ControlsView(stopWorkout: {}, afterLock: {})
            .environmentObject(WorkoutManager())
    }
}
