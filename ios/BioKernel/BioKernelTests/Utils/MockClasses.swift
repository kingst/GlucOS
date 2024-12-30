//
//  MockClasses.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import Foundation
import BioKernel
import HealthKit
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
    
    func update(maxBasalRateUnitsPerHour: Double) {
        self.maxBasalRateUnitsPerHour = maxBasalRateUnitsPerHour
    }
    
    func update(freshnessIntervalInSeconds: TimeInterval) {
        self.freshnessIntervalInSeconds = freshnessIntervalInSeconds
    }
    
    func update(useBiologicalInvariant: Bool) {
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

class MockGlucoseStorage: GlucoseStorage {
    private var glucoseReadings: [NewGlucoseSample] = []
    
    func addCgmEvents(glucoseReadings: [NewGlucoseSample]) async {
        self.glucoseReadings.append(contentsOf: glucoseReadings)
    }
    
    func lastReading() async -> NewGlucoseSample? {
        return glucoseReadings.max(by: { $0.date < $1.date })
    }
    
    func readingsBetween(startDate: Date, endDate: Date) async -> [NewGlucoseSample] {
        return glucoseReadings.filter { reading in
            reading.date >= startDate && reading.date <= endDate
        }
    }
    
    // Helper method for tests
    func addGlucoseReading(quantity: HKQuantity, date: Date) async {
        let sample = NewGlucoseSample(
            date: date,
            quantity: quantity,
            condition: nil,
            trend: nil,
            trendRate: nil,
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: UUID().uuidString
        )
        await addCgmEvents(glucoseReadings: [sample])
    }
}

/*
class MockDeviceDataManager: DeviceDataManager {
    var mockPumpManager: PumpManagerUI?
    var mockCgmManager: CGMManager?
    let mockObservableObject = DeviceDataManagerObservableObject()
    private var lastError: (date: Date, error: Error)?
    
    var pumpManager: PumpManagerUI? {
        get { mockPumpManager }
        set { mockPumpManager = newValue }
    }
    
    var cgmManager: CGMManager? {
        get { mockCgmManager }
        set { mockCgmManager = newValue }
    }
    
    func pumpSettingsUI() -> PumpManagerViewController? {
        return nil
    }
    
    func pumpSettingsUI(for pumpManager: PumpManagerUI) -> PumpManagerViewController {
        return MockPumpManagerViewController()
    }
    
    func setupPumpManagerUI(withIdentifier identifier: String) -> Result<SetupUIResult<PumpManagerViewController, PumpManagerUI>, Error> {
        .success(.userInteractionRequired(MockPumpManagerViewController()))
    }
    
    func pumpManagerDescriptors() -> [PumpManagerDescriptor] {
        return []
    }
    
    func cgmSettingsUI(for cgmManager: CGMManagerUI) -> CGMManagerViewController {
        return MockCGMManagerViewController()
    }
    
    func cgmSettingsUI() -> CGMManagerViewController? {
        return nil
    }
    
    func setupCGMManagerUI(withIdentifier identifier: String) -> Result<SetupUIResult<CGMManagerViewController, CGMManagerUI>, Error> {
        .success(.userInteractionRequired(MockCGMManagerViewController()))
    }
    
    func cgmManagerDescriptors() -> [CGMManagerDescriptor] {
        return []
    }
    
    func observableObject() -> DeviceDataManagerObservableObject {
        return mockObservableObject
    }
    
    func refreshCgmAndPumpDataFromUI() async {
        // No-op for mock
    }
    
    func checkCgmDataAndLoop() async {
        // No-op for mock
    }
    
    func setLastError(error: Error) {
        self.lastError = (date: Date(), error: error)
    }
    
    func updateCgmManager(to manager: CGMManager?) {
        self.mockCgmManager = manager
    }
    
    func newCgmDataAvailable(readingResult: CGMReadingResult) async {
        // No-op for mock
    }
    
    func updateRawCgmManager(to rawValue: [String : Any]?) {
        // No-op for mock
    }
    
    func updateCgm(hasValidSensorSession: Bool) {
        // No-op for mock
    }
    
    func updatePumpManager(to manager: PumpManagerUI?) {
        self.mockPumpManager = manager
    }
    
    func updateRawPumpManager(to rawValue: [String : Any]?) {
        // No-op for mock
    }
    
    func updatePumpIsAllowingAutomation(status: PumpManagerStatus) {
        // No-op for mock
    }
    
    func update(insulinOnBoard: Double, pumpAlarm: PumpAlarmType?) {
        mockObservableObject.insulinOnBoard = insulinOnBoard
        mockObservableObject.pumpAlarm = pumpAlarm
    }
    
    func update(activeAlert: Alert?) {
        mockObservableObject.activeAlert = activeAlert
    }
    
    func update(glucoseChartData: [GlucoseChartPoint]) {
        mockObservableObject.glucoseChartData = glucoseChartData
    }
    
    func update(totalAmount: Double, bolusProgressReporter: DoseProgressReporter) {
        mockObservableObject.doseProgress.update(totalUnits: totalAmount, doseProgressReporter: bolusProgressReporter)
    }
    
    func cgmPumpMetadata() async -> CgmPumpMetadata {
        return CgmPumpMetadata(cgmStartedAt: nil, cgmExpiresAt: nil, pumpStartedAt: nil, pumpExpiresAt: nil, pumpResevoirPercentRemaining: nil)
    }
}

// Mock view controllers needed for UI-related methods
class MockPumpManagerViewController: PumpManagerViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

class MockCGMManagerViewController: CGMManagerViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

// Mock dose progress reporter for testing dose updates
class MockDoseProgressReporter: DoseProgressReporter {
    private(set) var progress: DoseProgress?
    
    func updateProgress(_ progress: DoseProgress) {
        self.progress = progress
    }
}
*/
