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
    safetyService: SafetyService = MockSafetyService(),
    // A real in-memory store by default, so the loop's one transaction is on the
    // path under test rather than stubbed out. `.distantPast` as the creation
    // instant keeps `safety_history_complete_since` out of the way for the tests
    // that are not about it; the ones that are construct their own store.
    //
    // Pass nil explicitly for the no-store case.
    recordStore: LoopRecordStore? = try? GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast),
    aiInterfaceStorage: AiInterfaceStorage? = nil
) -> LoopRunner {
    let physModels = physiologicalModels
        ?? LocalPhysiologicalModels(storedObjectFactory: MockStoredObject.self, glucoseStorage: glucoseStorage, insulinStorage: insulinStorage)
    return LoopRunner(
        glucoseStorage: glucoseStorage,
        insulinStorage: insulinStorage,
        physiologicalModels: physModels,
        targetGlucoseService: targetGlucoseService,
        machineLearning: machineLearning,
        safetyService: safetyService,
        settingsStorage: { settings },
        observableState: AppObservableState(),
        doseProgress: DoseProgress(),
        recordStore: recordStore,
        aiInterfaceStorage: aiInterfaceStorage,
        startBackgroundTask: false
    )
}
