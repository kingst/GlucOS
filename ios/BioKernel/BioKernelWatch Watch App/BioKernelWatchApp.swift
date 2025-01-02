//
//  BioKernelWatchApp.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

@main
struct BioKernelWatch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor var appDelegate: WatchAppDelegate
    @StateObject var stateViewModel: StateViewModel
    @StateObject var workoutManager: WorkoutManager
    
    init() {
        let workoutManager = WorkoutManager()
        let alertManager = GlucoseAlertManager(workoutManager: workoutManager)
        let viewModel = StateViewModel(alertManager: alertManager)
        _stateViewModel = StateObject(wrappedValue: viewModel)
        _workoutManager = StateObject(wrappedValue: workoutManager)
        appDelegate.sessionDelegator.delegate = viewModel
    }
    
    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environmentObject(stateViewModel)
                .environmentObject(workoutManager)
        }
    }
}
