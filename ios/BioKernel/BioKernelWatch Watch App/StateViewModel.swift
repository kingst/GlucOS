//
//  StateViewModel.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import Foundation
import SwiftUI

@MainActor
class StateViewModel: ObservableObject, SessionUpdateDelegate {
    let alertManager: GlucoseAlertManager
    
    let storage = StoredJsonObject.create(fileName: "appState.json")
    
    func didRecieveMessage(at: Date, workoutMessage: WorkoutMessage) {
        print("not implemented")
    }
    func contextDidUpdate(_ context: BioKernelState) {
        print("WC: StateViewModel: contextDidUpdate")
        do {
            try storage.write(context)
        } catch {
            print("unable to store app context: \(error)")
        }
        alertManager.handleStateUpdate(oldState: appState, newState: context)
        appState = context
    }
    
    init(alertManager: GlucoseAlertManager) {
        self.alertManager = alertManager
        appState = try? storage.read()
    }
    
    @Published var appState: BioKernelState? = nil
}

extension BioKernelState {
    func minutesSinceLastReading() -> Int? {
        guard let lastUpdate = self.glucoseReadings.last?.at else { return nil }
        return Int(Date().timeIntervalSince(lastUpdate).secondsToMinutes())
    }
    
    func readingAgeColor() -> Color {
        guard let minutesSinceLastReading = minutesSinceLastReading() else { return .red }
        if minutesSinceLastReading < 6 {
            return .green
        } else if minutesSinceLastReading < 12 {
            return .yellow
        } else {
            return .red
        }
    }
    
    func lastGlucoseString() -> String? {
        guard let lastGlucose = self.glucoseReadings.last else { return nil }
        return "\(String(format: "%0.0f", lastGlucose.glucoseReadingInMgDl))\(lastGlucose.trend ?? "")"
    }
}

// Create a preview state with realistic glucose values
extension StateViewModel {
    static func preview(alertManager: GlucoseAlertManager) -> StateViewModel {
        let model = StateViewModel(alertManager: alertManager)
        model.appState = BioKernelState.preview()
        return model
    }
}
