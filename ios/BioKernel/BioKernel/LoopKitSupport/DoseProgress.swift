//
//  DoseProgress.swift
//  BioKernel
//
//  Created by Sam King on 11/6/23.
//

import Foundation
import Combine
import LoopKit

/// Bolus-in-progress state, shared between the pump layer and the UI.
///
/// Owned by `AppComposition` and injected as its own environment object rather
/// than living inside `AppObservableState`: a nested `ObservableObject` never
/// fires the outer object's `objectWillChange`, so views gating on `isComplete`
/// would not refresh when a bolus starts or finishes.
///
/// `@preconcurrency` on the observer conformance bridges LoopKit's nonisolated
/// callback. Every reporter we register with is created with
/// `reportingOn: .main`, so the callback really does arrive on the main actor.
@MainActor
public class DoseProgress: ObservableObject, @preconcurrency DoseProgressObserver {
    @Published var deliveredUnits: Double = 0.0
    @Published var percentComplete: Double = 0.0
    @Published var totalUnits: Double = 0.0
    @Published var isComplete: Bool = true
    @Published var error: String?
    
    var doseProgressReporter: DoseProgressReporter? = nil
    
    public func update(totalUnits: Double, doseProgressReporter: DoseProgressReporter) {
        deliveredUnits = doseProgressReporter.progress.deliveredUnits
        percentComplete = doseProgressReporter.progress.percentComplete
        isComplete = doseProgressReporter.progress.isComplete
        self.totalUnits = totalUnits
        
        self.doseProgressReporter = doseProgressReporter
        error = nil
        doseProgressReporter.addObserver(self)
    }
    
    func cancel() {
        self.doseProgressReporter?.removeObserver(self)
        self.doseProgressReporter = nil
        self.isComplete = true
    }
        
    public func doseProgressReporterDidUpdate(_ doseProgressReporter: LoopKit.DoseProgressReporter) {
        deliveredUnits = doseProgressReporter.progress.deliveredUnits
        percentComplete = doseProgressReporter.progress.percentComplete
        isComplete = doseProgressReporter.progress.isComplete
        
        print("Delivered \(deliveredUnits) of \(totalUnits) units")
        
        if isComplete {
            self.doseProgressReporter?.removeObserver(self)
            self.doseProgressReporter = nil
        }
    }
}
