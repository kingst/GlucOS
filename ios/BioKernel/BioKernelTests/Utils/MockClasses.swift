//
//  MockClasses.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import Foundation
import BioKernel
import LoopKit
import LoopKitUI

class MockSettingsStorage: SettingsStorage {
    func viewModel() -> BioKernel.SettingsViewModel {
        SettingsViewModel(settings: snapshot())
    }
    
    var targetGlucoseInMgDl = 90.0
    var insulinSensitivityInMgDlPerUnit = 45.0
    var correctionDurationInSeconds = 30.0 * 60.0 // 30 minutes in seconds
    var shutOffGlucoseInMgDl = 80.0
    var closedLoopEnabled = true
    var useMachineLearningClosedLoop = false
    var useMicroBolus = false
    var useDynamicBasalRate = false
    var useDynamicInsulinSensitivity = false
    var microBolusDoseFactor = 0.3
    var freshnessIntervalInSeconds = 10.0 * 60.0 // 10 minutes in seconds
    var pumpBasalRateUnitsPerHour: Double = 1.0
    var maxBasalRateUnitsPerHour: Double = 4.0
    var maxBolusUnits: Double = 6.0
    var addedGlucoseDigestionThresholdMgDlPerHour = 20.0
    var learnedBasalRateUnitsPerHour = LearnedSettingsSchedule.empty()
    var learnedInsulinSensitivityInMgDlPerUnit = LearnedSettingsSchedule.empty()
    var bolusAmountForLess = 1.0
    var bolusAmountForUsual = 2.0
    var bolusAmountForMore = 3.0
    var pidIntegratorGain = 0.055
    var pidDerivativeGain = 0.35
    var useBiologicalInvariant = false
    var adjustTargetGlucoseDuringExercise = false
    
    func update(useMicroBolus: Bool, useMachineLearningClosedLoop: Bool, useBiologicalInvariant: Bool) {
        self.useMicroBolus = useMicroBolus
        self.useMachineLearningClosedLoop = useMachineLearningClosedLoop
        self.useBiologicalInvariant = useBiologicalInvariant
    }
    
    func snapshot() -> BioKernel.CodableSettings {
        return CodableSettings(created: Date(), pumpBasalRateUnitsPerHour: pumpBasalRateUnitsPerHour, insulinSensitivityInMgDlPerUnit: insulinSensitivityInMgDlPerUnit, maxBasalRateUnitsPerHour: maxBasalRateUnitsPerHour, maxBolusUnits: maxBolusUnits, shutOffGlucoseInMgDl: shutOffGlucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, closedLoopEnabled: closedLoopEnabled, useMachineLearningClosedLoop: useMachineLearningClosedLoop, useMicroBolus: useMicroBolus, microBolusDoseFactor: microBolusDoseFactor, learnedBasalRateUnitsPerHour: learnedBasalRateUnitsPerHour, learnedInsulinSensitivityInMgDlPerUnit: learnedInsulinSensitivityInMgDlPerUnit, bolusAmountForLess: bolusAmountForLess, bolusAmountForUsual: bolusAmountForUsual, bolusAmountForMore: bolusAmountForMore, pidIntegratorGain: pidIntegratorGain, pidDerivativeGain: pidDerivativeGain, useBiologicalInvariant: useBiologicalInvariant, adjustTargetGlucoseDuringExercise: adjustTargetGlucoseDuringExercise)
    }
    
    func writeToDisk(settings: BioKernel.CodableSettings) throws {
        // don't do anything
    }
}

class MockStoredObject: StoredObject {
    func read<T>() throws -> T? where T : Decodable { return nil }
    func write<T>(_ object: T) throws where T : Encodable { }
    static func create(fileName: String) -> BioKernel.StoredObject {
        return MockStoredObject()
    }
}

class MockWatchComms: WatchComms {
    func updateAppContext() async { }
}

class MockTargetGlucose: TargetGlucoseService {
    func targetGlucoseInMgDl(at: Date, settings: BioKernel.CodableSettings) async -> Double {
        return settings.targetGlucoseInMgDl
    }
}

class MockReplayLogger: EventLogger {
    func update(deviceToken: String) async { }
    func upload(healthKitRecords: BioKernel.HealthKitRecords) async -> Bool { return false }
    func add(debugMessage: String) async { }
    func getReadOnlyAuthToken() async -> String? { nil }
    func add(events: [BioKernel.ClosedLoopResult]) async { }
    func add(events: [NewPumpEvent]) async { }
    func add(events: [NewGlucoseSample]) async { }
    func add(events: [BioKernel.GlucoseAlert]) async { }
}

class MockInsulinStorage: InsulinStorage {
    // stub out these functions with default values
    func addPumpEvents(_ events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, insulinType: LoopKit.InsulinType) async -> Error? { nil }
    func insulinOnBoard(at: Date) async -> Double { 0.0 }
    func insulinDelivered(startDate: Date, endDate: Date) async -> Double { return 0.0 }
    func pumpAlarm() async -> LoopKit.PumpAlarmType? { nil }
    func setPumpRecordsBasalProfileStartEvents(_ flag: Bool) async { }
    func currentInsulinType() async -> LoopKit.InsulinType { .humalog }
    func lastPumpSync() async -> Date? { nil }
    func activeBolus(at: Date) async -> LoopKit.DoseEntry? { nil }
    func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double { return 0.0 }
}

class MockInsulinStorageConstantAutomaticTempBasal: MockInsulinStorage {
    
    var automaticTempBasal: Double
    
    init(automaticTempBasal: Double) {
        self.automaticTempBasal = automaticTempBasal
    }

    override func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double { return automaticTempBasal }
}
