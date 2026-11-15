//
//  MockClasses.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import Foundation
@testable import BioKernel
import HealthKit
import MockKit
import LoopKit
import LoopKitUI
import G7SensorKit

class MockPumpManagerDelegate: PumpManagerDelegate {
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, hasNewPumpEvents events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }
    
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: LoopKit.BasalRateSchedule, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }
    
    var automaticDosingEnabled: Bool = true
    
    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: any LoopKit.PumpManager) { }
    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: any LoopKit.PumpManager) -> Bool { return true }
    func pumpManagerWillDeactivate(_ pumpManager: any LoopKit.PumpManager) { }
    func pumpManagerPumpWasReplaced(_ pumpManager: any LoopKit.PumpManager) { }
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) { }
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didError error: LoopKit.PumpManagerError) { }
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, hasNewPumpEvents events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, completion: @escaping ((any Error)?) -> Void) {
        completion(nil)
    }
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (Result<(newValue: any LoopKit.ReservoirValue, lastValue: (any LoopKit.ReservoirValue)?, areStoredValuesContinuous: Bool), any Error>) -> Void) { }
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) { }
    func pumpManagerDidUpdateState(_ pumpManager: any LoopKit.PumpManager) { }
    func startDateToFilterNewPumpEvents(for manager: any LoopKit.PumpManager) -> Date { return Date() }
    
    var detectedSystemTimeOffset: TimeInterval = 0
    
    func deviceManager(_ manager: any LoopKit.DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: LoopKit.DeviceLogEntryType, message: String, completion: (((any Error)?) -> Void)?) {
        completion?(nil)
    }
    
    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didUpdate status: LoopKit.PumpManagerStatus, oldStatus: LoopKit.PumpManagerStatus) { }
    func issueAlert(_ alert: LoopKit.Alert) { }
    func retractAlert(identifier: LoopKit.Alert.Identifier) { }
    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Result<Bool, any Error>) -> Void) { }
    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Result<[LoopKit.PersistedAlert], any Error>) -> Void) { }
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Result<[LoopKit.PersistedAlert], any Error>) -> Void) { }
    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) { }
}

class MockSettingsStorage: SettingsStorage {
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
    var machineLearningGain = 2.0
    var usePidLowPassFilter = false
    
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
    
    func update(usePidLowPassFilter: Bool) {
        self.usePidLowPassFilter = usePidLowPassFilter
    }
    
    func update(shutOffGlucoseInMgDl: Double) {
        self.shutOffGlucoseInMgDl = shutOffGlucoseInMgDl
    }
    
    func update(pumpBasalRateUnitsPerHour: Double) {
        self.pumpBasalRateUnitsPerHour = pumpBasalRateUnitsPerHour
    }
    
    func snapshot() -> BioKernel.CodableSettings {
        return CodableSettings(created: Date(), pumpBasalRateUnitsPerHour: pumpBasalRateUnitsPerHour, insulinSensitivityInMgDlPerUnit: insulinSensitivityInMgDlPerUnit, maxBasalRateUnitsPerHour: maxBasalRateUnitsPerHour, maxBolusUnits: maxBolusUnits, shutOffGlucoseInMgDl: shutOffGlucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, closedLoopEnabled: closedLoopEnabled, useMachineLearningClosedLoop: useMachineLearningClosedLoop, useMicroBolus: useMicroBolus, microBolusDoseFactor: microBolusDoseFactor, learnedBasalRateUnitsPerHour: learnedBasalRateUnitsPerHour, learnedInsulinSensitivityInMgDlPerUnit: learnedInsulinSensitivityInMgDlPerUnit, bolusAmountForLess: bolusAmountForLess, bolusAmountForUsual: bolusAmountForUsual, bolusAmountForMore: bolusAmountForMore, pidIntegratorGain: pidIntegratorGain, pidDerivativeGain: pidDerivativeGain, useBiologicalInvariant: useBiologicalInvariant, machineLearningGain: machineLearningGain, usePidLowPassFilter: usePidLowPassFilter)
    }
    
    func writeToDisk(settings: BioKernel.CodableSettings) throws {
        // don't do anything
    }
}

class MockMachineLearning: MachineLearning {
    func tempBasal(settings: BioKernel.CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [BioKernel.AddedGlucoseDataRow]?, at: Date, pidTempBasal: PIDTempBasalResult) async -> Double? {
        return nil
    }
}


class MockSafetyService: SafetyService {
    func tempBasal(at: Date, settings: CodableSettings, reactiveSafeTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async -> BioKernel.SafetyTempBasal {
        return SafetyTempBasal(tempBasal: 0, machineLearningInsulinLastThreeHours: 0)
    }
}

/// A `LoopRecordStore` that can be made to fail on demand.
///
/// The real store is a `GRDBLoopRecordStore` over an in-memory database, which
/// is what most tests should use. This one exists for the paths where "what
/// happens when the store is broken" *is* the behavior under test — the safety
/// ledger failing closed, and the AI marker not being published for a tick that
/// was never recorded.
actor MockLoopRecordStore: LoopRecordStore {
    var failWrites: Bool
    var failReads: Bool
    private(set) var written: [(record: LoopRecord, safetyState: SafetyState?)] = []
    /// Counted so a test can assert that a code path touched the store not at
    /// all, which is the whole of what `LoopRunner.init` is supposed to do.
    private(set) var readCount = 0

    init(failWrites: Bool = false, failReads: Bool = false) {
        self.failWrites = failWrites
        self.failReads = failReads
    }

    func record(_ record: LoopRecord, safetyState: SafetyState?, at: Date) async throws {
        guard !failWrites else { throw LoopRecordStoreError.writeFailed("injected") }
        written.append((record, safetyState))
    }

    func lastMicroBolus() async throws -> Date? {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        return written.compactMap { entry -> Date? in
            guard case .dosed(let snapshot) = entry.record.outcome else { return nil }
            guard case .microBolus = snapshot.decision else { return nil }
            return entry.record.at
        }.max()
    }

    func safetyStates(from: Date, to: Date) async throws -> [SafetyState] {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        return written.compactMap { $0.safetyState }.filter { $0.at >= from && $0.at < to }
    }

    func records(since: Date) async throws -> [LoopRecord] {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        return written.map { $0.record }.filter { $0.at >= since }
    }

    func filteredGlucose(since: Date) async throws -> [FilteredGlucose] {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        return []
    }

    func latestRecord() async throws -> LoopRecord? {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        return written.last?.record
    }

    func exportSnapshotURL() async -> URL? { return nil }

    // MARK: Target overrides

    /// Every override ever started, oldest first, closed rows included. The
    /// same shape as the table: an open row is the state, a closed row is the
    /// log entry.
    private(set) var overrides: [TargetOverride] = []

    func setFailWrites(_ fail: Bool) { failWrites = fail }
    func setFailReads(_ fail: Bool) { failReads = fail }

    /// Run once, inside the next `openTargetOverride`, after it has read the
    /// open row and before it hands it back. Whatever this does to the store
    /// lands while the caller is still suspended on the read, so the row the
    /// caller gets is already out of date. That is the window a re-entrant
    /// actor leaves open, held open on purpose.
    private var afterNextOpenRead: (@Sendable () async -> Void)?
    /// The same for the next `endTargetOverride`, after its write.
    private var afterNextEndWrite: (@Sendable () async -> Void)?

    func setAfterNextOpenRead(_ hook: @escaping @Sendable () async -> Void) { afterNextOpenRead = hook }
    func setAfterNextEndWrite(_ hook: @escaping @Sendable () async -> Void) { afterNextEndWrite = hook }

    func startTargetOverride(policyIdentifier: String, effect: OverrideEffect, at: Date, expiresAt: Date, settingsTargetMgDl: Double) async throws -> TargetOverride {
        guard !failWrites else { throw LoopRecordStoreError.writeFailed("injected") }
        overrides = overrides.map { $0.endedAt == nil ? Self.closed($0, at: at, reason: .cancelled) : $0 }
        let override = TargetOverride(
            id: Int64(overrides.count + 1),
            policyIdentifier: policyIdentifier,
            effect: effect,
            startedAt: at,
            expiresAt: expiresAt,
            settingsTargetMgDl: settingsTargetMgDl,
            endedAt: nil,
            endReason: nil
        )
        overrides.append(override)
        return override
    }

    func openTargetOverride() async throws -> TargetOverride? {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        let open = overrides.filter { $0.endedAt == nil }.max { $0.startedAt < $1.startedAt }
        if let hook = afterNextOpenRead {
            afterNextOpenRead = nil
            await hook()
        }
        return open
    }

    func endTargetOverride(id: Int64, at: Date, reason: TargetOverrideEndReason) async throws {
        guard !failWrites else { throw LoopRecordStoreError.writeFailed("injected") }
        overrides = overrides.map {
            guard $0.id == id, $0.endedAt == nil else { return $0 }
            return Self.closed($0, at: at, reason: reason)
        }
        if let hook = afterNextEndWrite {
            afterNextEndWrite = nil
            await hook()
        }
    }

    func targetOverrides(since: Date) async throws -> [TargetOverride] {
        readCount += 1
        guard !failReads else { throw LoopRecordStoreError.readFailed("injected") }
        return overrides.filter { $0.startedAt >= since }
    }

    private static func closed(_ override: TargetOverride, at: Date, reason: TargetOverrideEndReason) -> TargetOverride {
        return TargetOverride(
            id: override.id,
            policyIdentifier: override.policyIdentifier,
            effect: override.effect,
            startedAt: override.startedAt,
            expiresAt: override.expiresAt,
            settingsTargetMgDl: override.settingsTargetMgDl,
            endedAt: at,
            endReason: reason
        )
    }
}

class MockPhysiologicalModels: PhysiologicalModels {
    var mockPredictGlucose: Double? = nil
    var mockTempBasalResult = 0.0
    
    func tempBasal(settings: BioKernel.CodableSettings, dosing: BioKernel.DosingParameters, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [BioKernel.AddedGlucoseDataRow]?, at: Date) async -> BioKernel.PIDTempBasalResult {
        return PIDTempBasalResult(at: at, Kp: 1, Ki: 1, Kd: 1, filteredGlucose: 100, error: 0, tempBasal: mockTempBasalResult, accumulatedError: 0, derivative: nil, lastGlucose: nil, lastGlucoseAt: nil, deltaGlucoseError: nil, basalRateInsulinOnBoard: nil)
    }
    func predictGlucoseIn15Minutes(from: Date) async -> Double? { return mockPredictGlucose }
    func deltaGlucoseError(settings: BioKernel.CodableSettings, dataFrame: [BioKernel.AddedGlucoseDataRow]?, at: Date) async -> Double? { return nil }
}

class MockStoredObject: StoredObject {
    func read<T>() throws -> T? where T : Decodable { return nil }
    func write<T>(_ object: T) throws where T : Encodable { }
    static func create(fileName: String) -> BioKernel.StoredObject {
        return MockStoredObject()
    }
}

class MockHealthKitStore: HealthKitStorage {
    func save(_ glucoseSample: LoopKit.NewGlucoseSample, metadata: [String : Any]) async { }
    func save(_ pumpEvent: LoopKit.NewPumpEvent, metadata: [String : Any]) async { }
    func save(glucoseSamples: [LoopKit.NewGlucoseSample]) async { }
    func save(pumpEvents: [LoopKit.NewPumpEvent]) async { }
    func removeDuplicateEntries() async { }
    func fetchGlucoseSamples(startDate: Date, endDate: Date) async -> [HKQuantitySample] { return [] }
    func fetchInsulinSamples(startDate: Date, endDate: Date) async -> [HKQuantitySample] { return [] }
    func authorize() async throws { }
    func authorizationStatus() async -> HKAuthorizationStatus { .notDetermined }
    func preferences() async -> HealthKitPreferences { HealthKitPreferences() }
    func updatePreferences(_ preferences: HealthKitPreferences) async { }
}

class MockWatchComms: WatchComms {
    func updateAppContext() async { }
}

class MockTargetGlucose: TargetGlucoseService {
    /// The open row `targetGlucose` answers from, or nil for none. The answer
    /// is `OverrideGuardrails.resolve`, the rule the real service applies, so
    /// a pipeline test sees the real offsets, multipliers and clamps and not
    /// a copy of them.
    var override: TargetOverride?

    init(override: TargetOverride? = nil) {
        self.override = override
    }

    /// `kind` started at `startedAt` for its default duration, with the
    /// effect it has at `settingsTargetMgDl`. A nil kind is no override.
    convenience init(kind: TargetOverrideKind?, startedAt: Date, settingsTargetMgDl: Double = 90) {
        self.init(override: kind.map { kind in
            TargetOverride(
                id: 1,
                policyIdentifier: kind.policyIdentifier,
                effect: kind.effect(settingsTargetMgDl: settingsTargetMgDl),
                startedAt: startedAt,
                expiresAt: startedAt + kind.defaultDuration,
                settingsTargetMgDl: settingsTargetMgDl,
                endedAt: nil,
                endReason: nil
            )
        })
    }

    func targetGlucose(at: Date, settings: BioKernel.CodableSettings) async -> TargetGlucose {
        return OverrideGuardrails.resolve(override: override, at: at, settingsTargetMgDl: settings.targetGlucoseInMgDl)
    }

    func start(policyIdentifier: String, effect: OverrideEffect, at: Date, duration: TimeInterval, settings: BioKernel.CodableSettings) async throws { }
    func cancelOverride(at: Date) async throws { }
    func activeOverride(at: Date) async -> TargetOverride? { return nil }
}

/// The fields of a `TargetGlucose`, so a test can compare one against numbers
/// it writes out. A `TargetGlucose` itself can only be built by
/// `OverrideGuardrails.resolve`.
struct TargetGlucoseFields: Equatable {
    var mgDl: Double
    var settingsMgDl: Double
    var overridePolicy: String?
    var overrideMovesTarget: Bool
    var dosingMultiplier: Double?

    /// No override: the settings target, after its clamp, and nothing else.
    static func settings(_ mgDl: Double) -> TargetGlucoseFields {
        return TargetGlucoseFields(mgDl: mgDl, settingsMgDl: mgDl, overridePolicy: nil, overrideMovesTarget: false, dosingMultiplier: nil)
    }

    /// An override that moves the target to `mgDl`, with or without a dosing
    /// multiplier.
    static func target(_ overridePolicy: String, mgDl: Double, settingsMgDl: Double, dosingMultiplier: Double? = nil) -> TargetGlucoseFields {
        return TargetGlucoseFields(mgDl: mgDl, settingsMgDl: settingsMgDl, overridePolicy: overridePolicy, overrideMovesTarget: true, dosingMultiplier: dosingMultiplier)
    }

    /// An override that leaves the target on the settings target.
    static func dosingOnly(_ overridePolicy: String, settingsMgDl: Double, dosingMultiplier: Double?) -> TargetGlucoseFields {
        return TargetGlucoseFields(mgDl: settingsMgDl, settingsMgDl: settingsMgDl, overridePolicy: overridePolicy, overrideMovesTarget: false, dosingMultiplier: dosingMultiplier)
    }
}

extension TargetGlucose {
    var fields: TargetGlucoseFields {
        return TargetGlucoseFields(
            mgDl: mgDl,
            settingsMgDl: settingsMgDl,
            overridePolicy: overridePolicy,
            overrideMovesTarget: overrideMovesTarget,
            dosingMultiplier: dosingOverride?.dosingMultiplier
        )
    }
}

extension PumpMetadata {
    /// What `PumpMetadata(pumpManager:)` produces for the pump these tests
    /// stand in for.
    static let lyumjevOnOmnipod = PumpMetadata(
        pluginIdentifier: "OmnipodDash",
        smallestDeliveryUnit: 0.05,
        insulinType: .lyumjev
    )
}

class MockInsulinStorage: InsulinStorage {
    func registerForPumpEntryUpdates(delegate: any BioKernel.PumpEventUpdate) async { }
    func recentPumpEvents(since: Date) async -> [LoopKit.NewPumpEvent] { return [] }
    func pumpEvents(from: Date, to: Date) async -> [LoopKit.NewPumpEvent] { return [] }
    // stub out these functions with default values
    func addPumpEvents(_ events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, pump: BioKernel.PumpMetadata) async -> Error? { nil }
    func insulinOnBoard(at: Date) async -> Double { 0.0 }
    func insulinDelivered(startDate: Date, endDate: Date) async -> Double { return 0.0 }
    func pumpAlarm() async -> LoopKit.PumpAlarmType? { nil }
    func setPumpRecordsBasalProfileStartEvents(_ flag: Bool) async { }
    func currentInsulinType() async -> LoopKit.InsulinType { .humalog }
    func lastPumpSync() async -> Date? { mockLastPumpSync }
    func activeBolus(at: Date) async -> LoopKit.DoseEntry? { nil }
    func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double { return 0.0 }
    func recordScheduledBasalProgram(rateUnitsPerHour: Double, at: Date) async {
        recordedScheduledBasalPrograms.append((rateUnitsPerHour, at))
    }
    var mockLastPumpSync: Date? = nil
    /// Recorded rather than dropped, so a test can assert that a *failed*
    /// `syncBasalRateSchedule` enqueues nothing — the §1.1 case.
    var recordedScheduledBasalPrograms: [(rateUnitsPerHour: Double, at: Date)] = []
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


class MockDeviceDataManager: DeviceDataManager {
    var mockPumpManager: PumpManagerUI?
    var mockCgmManager: CGMManager?
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
    
    func refreshCgmAndPumpDataFromUI() async {
        // No-op for mock
    }
    
    func checkCgmData() async {
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

    func cgmPumpMetadata() async -> CgmPumpMetadata {
        return CgmPumpMetadata(cgmStartedAt: nil, cgmExpiresAt: nil, pumpStartedAt: nil, pumpExpiresAt: nil, pumpResevoirPercentRemaining: nil, supportedBasalRates: [], supportedBolusVolumes: [])
    }
}

// Mock view controllers needed for UI-related methods
class MockPumpManagerViewController: PumpManagerViewController {
    var completionDelegate: (any LoopKitUI.CompletionDelegate)? = nil
    
    var pumpManagerOnboardingDelegate: (any LoopKitUI.PumpManagerOnboardingDelegate)? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

class MockCGMManagerViewController: CGMManagerViewController {
    var cgmManagerOnboardingDelegate: (any LoopKitUI.CGMManagerOnboardingDelegate)? = nil
    
    var completionDelegate: (any LoopKitUI.CompletionDelegate)? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
}

// Mock dose progress reporter for testing dose updates
class MockDoseProgressReporter: DoseProgressReporter {
    var progress: LoopKit.DoseProgress = LoopKit.DoseProgress(deliveredUnits: 1, percentComplete: 0.1)
    
    func addObserver(_ observer: any LoopKit.DoseProgressObserver) {
        
    }
    
    func removeObserver(_ observer: any LoopKit.DoseProgressObserver) {
        
    }
    
}
