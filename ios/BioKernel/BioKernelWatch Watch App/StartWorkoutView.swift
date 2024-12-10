//
//  StartWorkoutView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct StartWorkoutView: View {
    let workouts: [String] = ["Walk", "Strength training", "Outdoor cycle", "Indoor cycle", "Softball", "Hike", "Run"]
    var body: some View {
        List(workouts, id: \.self) { workout in
            Text(workout)
        }
    }
}

#Preview {
    StartWorkoutView()
}
