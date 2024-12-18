//
//  Workout.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/14/24.
//

import Foundation
import HealthKit


struct Workout {
    static let walk = Workout(description: "Walk", activityType: .walking, locationType: .outdoor)
    static let strengthTraining = Workout(description: "Strength training", activityType: .functionalStrengthTraining, locationType: .indoor)
    static let outdoorCycle = Workout(description: "Outdoor cycle", activityType: .cycling, locationType: .outdoor)
    static let indoorCycle = Workout(description: "Indoor cycle", activityType: .cycling, locationType: .indoor)
    static let softball = Workout(description: "Softball", activityType: .softball, locationType: .outdoor)
    static let basketball = Workout(description: "Basketball", activityType: .basketball, locationType: .outdoor)
    static let hike = Workout(description: "Hike", activityType: .hiking, locationType: .outdoor)
    static let run = Workout(description: "Run", activityType: .running, locationType: .outdoor)

    static let workouts = [walk, strengthTraining, outdoorCycle, indoorCycle, softball, basketball, hike, run]
    
    let description: String
    let activityType: HKWorkoutActivityType
    let locationType: HKWorkoutSessionLocationType
}
