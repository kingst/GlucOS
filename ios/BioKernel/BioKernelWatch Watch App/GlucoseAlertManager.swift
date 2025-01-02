//
//  GlucoseAlertManager.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 1/2/25.
//

import Foundation
import WatchKit

class GlucoseAlertManager {
    // Weak reference to avoid retain cycles
    private weak var workoutManager: WorkoutManager?
    
    init(workoutManager: WorkoutManager) {
        self.workoutManager = workoutManager
    }
    
    // Called by StateViewModel when context updates
    func handleStateUpdate(oldState: BioKernelState?, newState: BioKernelState) {
        guard let oldState = oldState,
              oldState.isPredictedGlucoseInRange && !newState.isPredictedGlucoseInRange,
              workoutManager?.running == true else {
            return
        }
        
        triggerAlert()
    }
    
    private func triggerAlert() {
        // Play haptic sequence
        DispatchQueue.main.async {
            // First play success haptic
            WKInterfaceDevice.current().play(.success)
            
            // Then play notification haptic after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                WKInterfaceDevice.current().play(.notification)
            }
        }
    }
}
