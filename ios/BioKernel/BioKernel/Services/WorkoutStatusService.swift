//
//  WorkoutDisplayService.swift
//  BioKernel
//
//  Created by Sam King on 12/28/24.
//

import Foundation
import SwiftUI

@MainActor
public protocol WorkoutStatusService: SessionUpdateDelegate {
    func observableObject() -> WorkoutStatus
    func isExercising(at: Date) -> Bool
}

@MainActor
public class WorkoutStatus: ObservableObject {
    @Published var lastWorkoutMessage: WorkoutMessage? = nil
    @Published var isExercising: Bool = false
    public init() { }
}

@MainActor
class LocalWorkoutStatusService: WorkoutStatusService {
    struct WorkoutStatusState: Codable {
        let lastMessageAt: Date?
        let lastWorkoutMessage: WorkoutMessage?
    }
    static let shared = LocalWorkoutStatusService()
    let storage = getStoredObject().create(fileName: "workoutStatus.json")
    let observable = WorkoutStatus()
    var lastMessageAt: Date?
    var lastWorkoutMessage: WorkoutMessage?
    
    func observableObject() -> WorkoutStatus {
        return observable
    }

    func isExercising(at: Date) -> Bool {
        let exercising = calculateIsExercising(at: at)
        DispatchQueue.main.async {
            self.observable.isExercising = exercising
        }
        return exercising
    }
    
    func calculateIsExercising(at: Date) -> Bool {
        guard let lastMessageAt = lastMessageAt else { return false }

        // make sure that we have gotten a fresh message within the last 60 minutes
        // or else we will expire the exercise session automatically
        guard at.timeIntervalSince(lastMessageAt) < 60.minutesToSeconds() else { return false }
        
        // check to make sure that our last message was to start a workout
        switch (lastWorkoutMessage) {
        case (.none):
            return false
        case (.ended):
            return false
        case (.started):
            return true
        }
    }
    
    func didRecieveMessage(at: Date, workoutMessage: WorkoutMessage) {
        print("WC: WorkoutStatusService: didRecieveMessage")
        lastMessageAt = at
        lastWorkoutMessage = workoutMessage
        do {
            try storage.write(WorkoutStatusState(lastMessageAt: lastMessageAt, lastWorkoutMessage: workoutMessage))
        } catch {
            print("unable to store workout message: \(error)")
        }
        let exercising = calculateIsExercising(at: at)
        DispatchQueue.main.async {
            self.observable.lastWorkoutMessage = workoutMessage
            self.observable.isExercising = exercising
        }
    }
    
    func contextDidUpdate(_ context: BioKernelState) {
        print("WC: contextDidUpdate not implemented")
    }
    
    init() {
        let state: WorkoutStatusState = (try? storage.read()) ?? WorkoutStatusState(lastMessageAt: nil, lastWorkoutMessage: nil)
        lastMessageAt = state.lastMessageAt
        lastWorkoutMessage = state.lastWorkoutMessage
        
        DispatchQueue.main.async {
            self.observable.lastWorkoutMessage = state.lastWorkoutMessage
        }
    }
}
