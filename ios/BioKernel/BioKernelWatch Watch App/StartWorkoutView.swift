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
        List(Workout.workouts, id: \.self.description) { workout in
            Button(action: { startWorkout(workout) }) {
                Text(workout.description)
            }
        }
    }
}

#Preview {
    StartWorkoutView(startWorkout: { _ in })
}
