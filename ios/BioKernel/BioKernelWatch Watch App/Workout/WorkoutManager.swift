//
//  WorkoutManager.swift
//  LoopViewerWatch Watch App
//
//  Created by Sam King on 3/5/23.
//  Copyright © 2023 Sam King. All rights reserved.
//

import Foundation
import HealthKit
import WatchKit

class WorkoutManager: NSObject, ObservableObject, SessionCommands {
    var selectedWorkout: Workout? {
        didSet {
            guard let selectedWorkout = selectedWorkout else { return }
            startWorkout(workout: selectedWorkout)
        }
    }
    
    let healthStore = HKHealthStore()
    var session: HKWorkoutSession?
    var builder: HKLiveWorkoutBuilder?
    var cachedHealthKitAuthorization: Bool?
    
    var startedWorkout: Workout?
    var startedAt: Date?
    var lastSentStartedMessageAt: Date?
    
    func startWorkout(workout: Workout) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = workout.activityType
        configuration.locationType = workout.locationType
        
        guard let session = try? HKWorkoutSession(healthStore: healthStore, configuration: configuration) else {
            return
        }
        self.session = session
        self.builder = session.associatedWorkoutBuilder()
        self.distance = 0
        
        builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        
        self.session?.delegate = self
        self.builder?.delegate = self
        
        let startDate = Date()
        session.startActivity(with: startDate)
        startedAt = startDate
        startedWorkout = workout
        sendStartedMessage()
        builder?.beginCollection(withStart: startDate) { (success, error) in
            // the workout has started
        }
    }
    
    // send a new `started` message while we are actively working out
    func sendStartedMessage() {
        guard let workout = startedWorkout, let startDate = startedAt else { return }

        let at = Date()
        let lastSent = lastSentStartedMessageAt ?? .distantPast
        guard at.timeIntervalSince(lastSent) > 5.minutesToSeconds() else { return }
        
        sendMessageData(workoutMessage: .started(at: startDate, description: workout.description, imageName: workout.imageName))
        lastSentStartedMessageAt = at
    }
    
    func requestAuthorization(_ complete: @escaping (Bool) -> Void) {
        if let success = cachedHealthKitAuthorization {
            DispatchQueue.main.async { complete(success) }
            return
        }
        
        let typesToShare: Set = [ HKQuantityType.workoutType() ]
        let typesToRead: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!,
            HKQuantityType.quantityType(forIdentifier: .distanceCycling)!,
            HKQuantityType.quantityType(forIdentifier: .bloodGlucose)!,
            HKQuantityType.activitySummaryType()
        ]
        
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { (success, error) in
            DispatchQueue.main.async { [weak self] in
                self?.cachedHealthKitAuthorization = success
                complete(success)
            }
        }
    }
    
    @Published var running = false
    
    func pause() {
        session?.pause()
    }
    
    func resume() {
        session?.resume()
    }
    
    func togglePause() {
        if running == true {
            pause()
        } else {
            resume()
        }
    }
    
    func end(save: Bool) {
        sendMessageData(workoutMessage: .ended(at: Date()))
        startedAt = nil
        startedWorkout = nil
        lastSentStartedMessageAt = nil
        if save {
            session?.end()
        } else {
            builder?.discardWorkout()
            session?.end()
        }
    }
    
    func lock() {
        WKInterfaceDevice.current().enableWaterLock()
    }
    
    @Published var heartRate: Double = 0
    @Published var activeEnergy: Double = 0
    @Published var distance: Double = 0
    
    func updateForStatistics(_ stats: HKStatistics?) {
        guard let stats = stats else { return }
        
        DispatchQueue.main.async {
            self.sendStartedMessage()
            switch stats.quantityType {
            case HKQuantityType.quantityType(forIdentifier: .heartRate):
                let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
                self.heartRate = stats.mostRecentQuantity()?.doubleValue(for: heartRateUnit) ?? 0
            case HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned):
                let energyUnit = HKUnit.kilocalorie()
                self.activeEnergy = stats.sumQuantity()?.doubleValue(for: energyUnit) ?? 0
            case HKQuantityType.quantityType(forIdentifier: .distanceCycling), HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning):
                let meterUnit = HKUnit.meter()
                self.distance = stats.sumQuantity()?.doubleValue(for: meterUnit) ?? 0
            default:
                return
            }
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        DispatchQueue.main.async {
            self.running = toState == .running
        }
        
        if toState == .ended {
            builder?.endCollection(withEnd: date) { (success, error) in
                self.builder?.finishWorkout { (workout, error) in
                    
                }
            }
        }
    }
    
    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        print("workoutSession error")
    }
    
    
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        for type in collectedTypes {
            guard let quantityType = type as? HKQuantityType else { return }
            let stats = workoutBuilder.statistics(for: quantityType)
            updateForStatistics(stats)
        }
    }
    
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        
    }
}

extension WorkoutManager {
    static func preview() -> WorkoutManager {
        let manager = WorkoutManager()
        
        // Simulate an active workout session
        manager.running = true
        manager.heartRate = 142
        manager.activeEnergy = 240  // kilocalories
        manager.distance = 2463     // meters
        
        // Create a workout session
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .running
        configuration.locationType = .outdoor
        
        // Simulate a workout that started 31 minutes ago
        if let session = try? HKWorkoutSession(healthStore: manager.healthStore, configuration: configuration) {
            manager.session = session
            manager.builder = session.associatedWorkoutBuilder()
            manager.selectedWorkout = Workout.run
        }
        
        return manager
    }
}

