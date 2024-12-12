//
//  StateViewModel.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import Foundation

@MainActor
class StateViewModel: ObservableObject, SessionUpdateDelegate {
    static let shared = StateViewModel()
    let storage = StoredJsonObject.create(fileName: "appState.json")
    func contextDidUpdate(_ context: BioKernelState) {
        print("WC: StateViewModel: contextDidUpdate")
        do {
            try storage.write(context)
        } catch {
            print("unable to store app context: \(error)")
        }
        appState = context
    }
    
    init() {
        appState = try? storage.read()
    }
    
    @Published var appState: BioKernelState? = nil
}
