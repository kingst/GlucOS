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
    @EnvironmentObject var workoutManager: WorkoutManager
    
    var body: some View {
        VStack {
            HStack {
                VStack {
                    Button(action: { workoutManager.end(); stopWorkout() }) {
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
                } label: {
                    Image(systemName: "lock")
                }
                .tint(.blue)
                .font(.title2)
                Text("Lock")
            }
        }
    }
}

struct ControlsView_Previews: PreviewProvider {
    static var previews: some View {
        ControlsView(stopWorkout: {})
            .environmentObject(WorkoutManager())
    }
}
