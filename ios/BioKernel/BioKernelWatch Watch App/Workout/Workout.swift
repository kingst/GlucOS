//
//  Workout.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/14/24.
//

import SwiftUI
import HealthKit

struct Workout {
    let description: String
    let activityType: HKWorkoutActivityType
    let locationType: HKWorkoutSessionLocationType
    let image: Image
    let imageName: String
    
    private init(description: String,
                activityType: HKWorkoutActivityType,
                locationType: HKWorkoutSessionLocationType,
                imageName: String) {
        self.description = description
        self.activityType = activityType
        self.locationType = locationType
        self.imageName = imageName
        self.image = Image(systemName: imageName)
    }
    
    static let walk = Workout(
        description: "Walk",
        activityType: .walking,
        locationType: .outdoor,
        imageName: "figure.walk"
    )
    
    static let strengthTraining = Workout(
        description: "Strength training",
        activityType: .functionalStrengthTraining,
        locationType: .indoor,
        imageName: "figure.strengthtraining.traditional"
    )
    
    static let outdoorCycle = Workout(
        description: "Outdoor cycle",
        activityType: .cycling,
        locationType: .outdoor,
        imageName: "figure.outdoor.cycle"
    )
    
    static let indoorCycle = Workout(
        description: "Indoor cycle",
        activityType: .cycling,
        locationType: .indoor,
        imageName: "figure.outdoor.cycle"
    )
    
    static let softball = Workout(
        description: "Softball",
        activityType: .softball,
        locationType: .outdoor,
        imageName: "figure.baseball"
    )
    
    static let basketball = Workout(
        description: "Basketball",
        activityType: .basketball,
        locationType: .outdoor,
        imageName: "figure.basketball"
    )
    
    static let hike = Workout(
        description: "Hike",
        activityType: .hiking,
        locationType: .outdoor,
        imageName: "figure.hiking"
    )
    
    static let run = Workout(
        description: "Run",
        activityType: .running,
        locationType: .outdoor,
        imageName: "figure.run"
    )

    static let workouts = [walk, strengthTraining, outdoorCycle, indoorCycle, softball, basketball, hike, run]
}
