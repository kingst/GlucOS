//
//  ClosedLoopTestSupport.swift
//  BioKernelTests
//

import Foundation
@testable import BioKernel

@MainActor
func makeClosedLoopService(
    settings: MockSettingsStorage,
    glucoseStorage: GlucoseStorage,
    insulinStorage: InsulinStorage,
    physiologicalModels: PhysiologicalModels? = nil,
    targetGlucoseService: TargetGlucoseService = MockTargetGlucose(),
    machineLearning: MachineLearning = MockMachineLearning(),
    safetyService: SafetyService = MockSafetyService()
) -> LoopRunner {
    let physModels = physiologicalModels
        ?? LocalPhysiologicalModels(glucoseStorage: glucoseStorage, insulinStorage: insulinStorage)
    return LoopRunner(
        storedObjectFactory: MockStoredObject.self,
        glucoseStorage: glucoseStorage,
        insulinStorage: insulinStorage,
        physiologicalModels: physModels,
        targetGlucoseService: targetGlucoseService,
        machineLearning: machineLearning,
        safetyService: safetyService,
        settingsStorage: { settings },
        observableState: AppObservableState(),
        startBackgroundTask: false
    )
}
