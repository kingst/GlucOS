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
    
    init() {
        let viewModel = StateViewModel()
        _stateViewModel = StateObject(wrappedValue: viewModel)
        appDelegate.sessionDelegator.delegate = viewModel
    }
    
    var body: some Scene {
        WindowGroup {
            WatchMainView()
                .environmentObject(stateViewModel)
        }
    }
}
