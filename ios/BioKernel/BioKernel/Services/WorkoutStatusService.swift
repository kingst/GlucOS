//
//  WorkoutDisplayService.swift
//  BioKernel
//
//  Created by Sam King on 12/28/24.
//

import Foundation
import SwiftUI

@MainActor protocol WorkoutStatusService: SessionUpdateDelegate {
    func observableObject() -> WorkoutStatus
}

@MainActor
class WorkoutStatus: ObservableObject {
    @Published var lastWorkoutMessage: WorkoutMessage? = nil
}

@MainActor
class LocalWorkoutStatusService: WorkoutStatusService {
    static let shared = LocalWorkoutStatusService()
    let storage = StoredJsonObject.create(fileName: "workoutStatus.json")
    let observable = WorkoutStatus()
    
    func observableObject() -> WorkoutStatus {
        return observable
    }
    
    func didRecieveMessage(_ workout: WorkoutMessage) {
        print("WC: WorkoutStatusService: didRecieveMessage")
        do {
            try storage.write(workout)
        } catch {
            print("unable to store workout message: \(error)")
        }
        DispatchQueue.main.async {
            self.observable.lastWorkoutMessage = workout
        }
    }
    
    func contextDidUpdate(_ context: BioKernelState) {
        print("WC: contextDidUpdate not implemented")
    }
    
    init() {
        observable.lastWorkoutMessage = try? storage.read()
    }
}
