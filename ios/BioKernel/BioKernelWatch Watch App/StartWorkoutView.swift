//
//  StartWorkoutView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct StartWorkoutView: View {
    let startWorkout: (Workout) -> Void
    
    var body: some View {
        NavigationStack {
            List(Workout.workouts, id: \.self.description) { workout in
                Button(action: { startWorkout(workout) }) {
                    HStack {
                        workout.image
                        Text(workout.description)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    StartWorkoutView(startWorkout: { _ in })
}
