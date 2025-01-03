//
//  DeviceDataManager.swift
//  BioKernel
//
//  Created by Sam King on 11/3/23.
//

import LoopKit
import LoopKitUI
import MockKit
import MockKitUI
import OmniBLE

import Combine
import SwiftUI
import G7SensorKit

public struct CgmPumpMetadata: Codable {
    public let cgmStartedAt: Date?
    public let cgmExpiresAt: Date?
    public let pumpStartedAt: Date?
    public let pumpExpiresAt: Date?
    public let pumpResevoirPercentRemaining: Double?
    
    public init(cgmStartedAt: Date?, cgmExpiresAt: Date?, pumpStartedAt: Date?, pumpExpiresAt: Date?, pumpResevoirPercentRemaining: Double?) {
        self.cgmStartedAt = cgmStartedAt
        self.cgmExpiresAt = cgmExpiresAt
        self.pumpStartedAt = pumpStartedAt
        self.pumpExpiresAt = pumpExpiresAt
        self.pumpResevoirPercentRemaining = pumpResevoirPercentRemaining
    }
}

@MainActor
public protocol DeviceDataManager {
    var pumpManager: PumpManagerUI? { get }
    func pumpSettingsUI() -> PumpManagerViewController?
    func pumpSettingsUI(for pumpManager: PumpManagerUI) -> PumpManagerViewController
    func setupPumpManagerUI(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<PumpManagerViewController, PumpManagerUI>, Error>
    func pumpManagerDescriptors() -> [PumpManagerDescriptor]

    var cgmManager: CGMManager? { get }
    func cgmSettingsUI(for cgmManager: CGMManagerUI) -> CGMManagerViewController
    func cgmSettingsUI() -> CGMManagerViewController?
    func setupCGMManagerUI(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<CGMManagerViewController, CGMManagerUI>, Error>
    func cgmManagerDescriptors() -> [CGMManagerDescriptor]
    
    func observableObject() -> DeviceDataManagerObservableObject
    func refreshCgmAndPumpDataFromUI() async
    func checkCgmDataAndLoop() async
    
    // for the delegate classes to use
    func setLastError(error: Error)
    
    func updateCgmManager(to manager: CGMManager?)
    func newCgmDataAvailable(readingResult: CGMReadingResult) async
    func updateRawCgmManager(to rawValue: [String: Any]?)
    func updateCgm(hasValidSensorSession: Bool)
    
    func updatePumpManager(to manager: PumpManagerUI?)
    func updateRawPumpManager(to rawValue: [String: Any]?)
    func updatePumpIsAllowingAutomation(status: PumpManagerStatus)
    func update(insulinOnBoard: Double, pumpAlarm: PumpAlarmType?)
    func update(activeAlert: LoopKit.Alert?)
    func update(glucoseChartData: [GlucoseChartPoint])
    func update(totalAmount: Double, bolusProgressReporter: DoseProgressReporter)
    
    func cgmPumpMetadata() async -> CgmPumpMetadata
}

@MainActor
public class DeviceDataManagerObservableObject: ObservableObject {
    @Published public var pumpManager: PumpManagerUI?
    @Published public var cgmManager: CGMManager?
    @Published public var insulinOnBoard: Double = 0.0
    @Published public var pumpAlarm: PumpAlarmType?
    @Published public var lastGlucoseReading: NewGlucoseSample? = nil
    @Published public var displayGlucoseUnit: DisplayGlucoseUnitObservable = DisplayGlucoseUnitObservable(displayGlucoseUnit: .milligramsPerDeciliter)
    @Published public var lastClosedLoopRun: ClosedLoopResult? = nil
    @Published public var activeAlert: LoopKit.Alert? = nil
    @Published public var glucoseChartData: [GlucoseChartPoint] = []
    @Published public var doseProgress: DoseProgress = DoseProgress()
    
    public init() {

    }
    
    func digestionCalibrated() -> Double? {
        guard let lastRun = lastClosedLoopRun else { return nil }
        
        let tooOld = Date() - 16.minutesToSeconds()
        guard lastRun.at > tooOld else { return nil }
        
        guard let addedGlucose = lastRun.shadowPredictedAddedGlucose else { return nil }
        guard let basalRate = lastRun.basalRate else { return nil }
        guard let insulinSensitivity = lastRun.insulinSensitivity else { return nil }
        
        // added glucose is for an hour, so the basalRate = basalInsulin
        let basalGlucose = insulinSensitivity * basalRate
        
        // assume that 200 mg/dl is the max added glucose, aim for 0 -> 100
        return 100 * (addedGlucose - basalGlucose) / 200
    }
}

let omniBLEManagerIdentifier: String = "Omnipod-Dash"
let omniBLELocalizedTitle = "Omnipod DASH"
let staticPumpManagersByIdentifier: [String: PumpManagerUI.Type] = [
    MockPumpManager.managerIdentifier : MockPumpManager.self,
    omniBLEManagerIdentifier: OmniBLEPumpManager.self
]

var availableStaticPumpManagers: [PumpManagerDescriptor] {
    return [PumpManagerDescriptor(identifier: MockPumpManager.managerIdentifier,
                                  localizedTitle: MockPumpManager.localizedTitle),
            PumpManagerDescriptor(identifier: omniBLEManagerIdentifier,
                                  localizedTitle: omniBLELocalizedTitle)]
}

@MainActor
class LocalDeviceDataManager: DeviceDataManager {
    static let shared = LocalDeviceDataManager()
    
    /*private*/ let log = DiagnosticLog(category: "DeviceDataManager")
    /*private*/ let delegateQueue = DispatchQueue(label: "com.getgrowthmetrics.DeviceManagerQueue", qos: .userInitiated)
    var pumpIsAllowingAutomation: Bool = true
    
    /*private*/ let bluetoothProvider = getBluetoothProvider()
    /*private*/ let allowDebugFeatures = true
    /*private*/ let allowedInsulinTypes: [InsulinType] = [.apidra, .fiasp, .humalog, .lyumjev, .novolog]
    var cgmHasValidSensorSession: Bool = false
    var lastLoopCompleted: Date = .distantPast
    
    // These are non isolated because we use a dispatch queue to synchronize
    // access to them outside of the actor abstraction
    nonisolated let cgmManagerDelegate = MosCgmManagerDelegate()
    nonisolated let pumpManagerDelegate = MosPumpManagerDelegate()
    
    /// The last error recorded by a device manager
    /// Should be accessed only on the main queue
    private(set) var lastError: (date: Date, error: Error)?
    
    init() {
        setupPumpManager()
        setupCgmManager()
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func pumpManagerDescriptors() -> [PumpManagerDescriptor] {
        return availableStaticPumpManagers
    }
    
    func cgmManagerDescriptors() -> [CGMManagerDescriptor] {
        return availableStaticCGMManagers
    }
    
    func setupPumpManager() {
        guard let pumpManagerRawValue = rawPumpManager else {
            return
        }
        pumpManager = pumpManagerFromRawValue(pumpManagerRawValue)
    }
    
    func updateCgmManager(to manager: CGMManager?) {
        self.cgmManager = manager
    }
    
    func updateRawCgmManager(to rawValue: [String: Any]?) {
        self.rawCGMManager = rawValue
    }
    
    func updateCgm(hasValidSensorSession: Bool) {
        self.cgmHasValidSensorSession = hasValidSensorSession
    }
    
    func setupCgmManager() {
        guard let cgmManagerRawValue = rawCGMManager else {
            return
        }
        cgmManager = CGMManagerFromRawValue(cgmManagerRawValue)
    }
    
    func cgmPumpMetadata() async -> CgmPumpMetadata {
        let cgmStartedAt = (cgmManager as? G7CGMManager)?.sensorActivatedAt
        let cgmExpiresAt = (cgmManager as? G7CGMManager)?.sensorExpiresAt
        let pumpStartedAt = (pumpManager as? OmniBLEPumpManager)?.podActivatedAt
        let pumpExpiresAt = (pumpManager as? OmniBLEPumpManager)?.podExpiresAt
        let pumpPercentRemaining = (pumpManager as? OmniBLEPumpManager)?.reservoirLevel?.percentage
        return CgmPumpMetadata(cgmStartedAt: cgmStartedAt, cgmExpiresAt: cgmExpiresAt, pumpStartedAt: pumpStartedAt, pumpExpiresAt: pumpExpiresAt, pumpResevoirPercentRemaining: pumpPercentRemaining)
    }
    
    // MARK: - CGM

    var cgmManager: CGMManager? {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            setupCGM()
            rawCGMManager = cgmManager?.rawValue
            
            let pumpMustProvideBLEHeartbeat = pumpManagerMustProvideBLEHeartbeat
            
            DispatchQueue.main.async {
                Task { @MainActor in
                    self.localObservableObject.cgmManager = self.cgmManager
                    let lastGlucoseReading = await getGlucoseStorage().lastReading()
                    self.localObservableObject.lastGlucoseReading = lastGlucoseReading
                    self.delegateQueue.async {
                        self.cgmManagerDelegate.lastGlucoseReading = lastGlucoseReading
                        self.pumpManagerDelegate.pumpManagerMustProvideBLEHeartbeat = pumpMustProvideBLEHeartbeat
                    }
                }
            }
        }
    }

    @PersistedProperty(key: "CGMManagerState")
    var rawCGMManager: CGMManager.RawValue?
    
    // MARK: - Pump
    var localObservableObject = DeviceDataManagerObservableObject()
    func observableObject() -> DeviceDataManagerObservableObject {
        return localObservableObject
    }
    
    @PersistedProperty(key: "PumpManagerState")
    var rawPumpManager: PumpManager.RawValue?
    
    var pumpManager: PumpManagerUI? {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            setupPump()
            print("Setting pump manager: \(pumpManager?.managerIdentifier ?? "nil"), old value: \(oldValue?.managerIdentifier ?? "nil")")
            rawPumpManager = pumpManager?.rawValue
            
            // we'll set the pump manager later because this propery can be set directly from a SwiftUI
            // view, which causes issues. Be aware of race conditions and make sure to return this
            // directly if you need it rather than relying on the observable object value
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.localObservableObject.pumpManager = self.pumpManager
            }
        }
    }

    func updateRawPumpManager(to rawValue: [String: Any]?) {
        rawPumpManager = rawValue
    }
    
    func updatePumpManager(to manager: PumpManagerUI?) {
        self.pumpManager = manager
    }
    
    func updatePumpIsAllowingAutomation(status: PumpManagerStatus) {
        if case .tempBasal(let dose) = status.basalDeliveryState, !(dose.automatic ?? true), dose.endDate > Date() {
            pumpIsAllowingAutomation = false
        } else {
            pumpIsAllowingAutomation = true
        }
    }
    
    func update(insulinOnBoard: Double, pumpAlarm: PumpAlarmType?) {
        DispatchQueue.main.async {
            self.localObservableObject.insulinOnBoard = insulinOnBoard
            self.localObservableObject.pumpAlarm = pumpAlarm
        }
    }
    
    func update(activeAlert: LoopKit.Alert?) {
        DispatchQueue.main.async {
            self.localObservableObject.activeAlert = activeAlert
        }
    }
    
    func update(glucoseChartData: [GlucoseChartPoint]) {
        DispatchQueue.main.async {
            self.localObservableObject.glucoseChartData = glucoseChartData
        }
    }
    
    func update(totalAmount: Double, bolusProgressReporter: DoseProgressReporter) {
        DispatchQueue.main.async {
            self.localObservableObject.doseProgress.update(totalUnits: totalAmount, doseProgressReporter: bolusProgressReporter)
        }
    }
    
    func setupCGM() {
        dispatchPrecondition(condition: .onQueue(.main))

        cgmManager?.cgmManagerDelegate = cgmManagerDelegate
        cgmManager?.delegateQueue = delegateQueue

        updatePumpManagerBLEHeartbeatPreference()
    }
    
    func setupPump() {
        dispatchPrecondition(condition: .onQueue(.main))

        pumpManager?.pumpManagerDelegate = pumpManagerDelegate
        pumpManager?.delegateQueue = delegateQueue
        
        if let pumpRecordsBasalProfileStartEvents = pumpManager?.pumpRecordsBasalProfileStartEvents {
            Task {
                await getInsulinStorage().setPumpRecordsBasalProfileStartEvents(pumpRecordsBasalProfileStartEvents)
            }
        }
    }
    
    func setLastError(error: Error) {
        DispatchQueue.main.async {
            self.lastError = (date: Date(), error: error)
        }
    }
    
    struct UnknownPumpManagerIdentifierError: Error {}
    struct UnknownCGMManagerIdentifierError: Error {}

    public func pumpManagerTypeByIdentifier(_ identifier: String) -> PumpManagerUI.Type? {
        return staticPumpManagersByIdentifier[identifier]
    }

    public func cgmManagerTypeByIdentifier(_ identifier: String) -> CGMManagerUI.Type? {
        return staticCGMManagersByIdentifier[identifier] as? CGMManagerUI.Type
    }
    
    private func pumpManagerTypeFromRawValue(_ rawValue: [String: Any]) -> PumpManager.Type? {
        guard let managerIdentifier = rawValue["managerIdentifier"] as? String else {
            return nil
        }

        return pumpManagerTypeByIdentifier(managerIdentifier)
    }

    func pumpManagerFromRawValue(_ rawValue: [String: Any]) -> PumpManagerUI? {
        guard let rawState = rawValue["state"] as? PumpManager.RawStateValue,
            let Manager = pumpManagerTypeFromRawValue(rawValue)
            else {
                return nil
        }

        return Manager.init(rawState: rawState) as? PumpManagerUI
    }
    
    /*private*/ var pumpManagerMustProvideBLEHeartbeat: Bool {
        /// Controls the management of the RileyLink timer tick, which is a reliably-changing BLE
        /// characteristic which can cause the app to wake. For most users, the G5 Transmitter and
        /// G4 Receiver are reliable as hearbeats, but users who find their resources extremely constrained
        /// due to greedy apps or older devices may choose to always enable the timer by always setting `true`
        return !(cgmManager?.providesBLEHeartbeat == true)
    }
    
    func updatePumpManagerBLEHeartbeatPreference() {
        pumpManager?.setMustProvideBLEHeartbeat(pumpManagerMustProvideBLEHeartbeat)
    }
    
    // MARK: - core looping functions
    func newCgmDataAvailable(readingResult: CGMReadingResult) async {
        let now = currentTime()
        await processCGMReadingResult(readingResult: readingResult)
        await self.checkPumpDataAndLoop(now: now)
    }
    
    func refreshCgmAndPumpDataFromUI() async {
        print("checkCgmDataAndLoop call")
        await checkCgmDataAndLoop()
        
        print("refreshCgmAndPumpDataFromUI")
        guard let pumpManager = self.pumpManager, pumpManager.isOnboarded else {
            return
        }
        
        // I'm not sure why Loop has this extra call to ensureCurrentPumpData but
        // since this method comes from the UI it shouldn't happen too often
        // and should be fine
        print("ensureCurrentPumpData call")
        let _ = await pumpManager.ensureCurrentPumpData()
        print("return")
    }
    
    // This method is invoked by either the UI or from a pump BLE heartbeat
    // so we need to make sure that we wait at least 6 minutes between runs
    func checkCgmDataAndLoop() async {
        guard let cgmManager = cgmManager else {
            return
        }

        let now = currentTime()
        
        let result = await cgmManager.fetchNewDataIfNeeded()
        await self.processCGMReadingResult(readingResult: result)
        
        // 4.2 minutes comes from Loop, for consistency (they changed it from 6 recently)
        guard now.timeIntervalSince(lastLoopCompleted) > 4.2.minutesToSeconds() else {
            print("wait for enough time to elapse before running again")
            return
        }
        await self.checkPumpDataAndLoop(now: now)
    }
    
    private func currentTime() -> Date {
        // FIXME: move to dependency injection once we figure out our time story
        return Date()
    }
    
    private func checkPumpDataAndLoop(now: Date) async {
        guard let pumpManager = pumpManager else {
            return
        }

        let lastPumpSync = await pumpManager.ensureCurrentPumpData()
        print("Last pump sync: \(String(describing: lastPumpSync))")
        let success = await getClosedLoopService().loop(at: now)
        if success {
            lastLoopCompleted = now
        }

        Task {
            let lastRun = await getClosedLoopService().latestClosedLoopResult()
            DispatchQueue.main.async { [weak self] in
                self?.localObservableObject.lastClosedLoopRun = lastRun
            }
        }
    }
    
    func processCGMReadingResult(readingResult: CGMReadingResult) async {
        switch readingResult {
        case .newData(let values):
            log.default("CGMManager: did update with %d values", values.count)
            
            await getGlucoseStorage().addCgmEvents(glucoseReadings: values)
            let lastReading = await getGlucoseStorage().lastReading()
            await MainActor.run {
                self.localObservableObject.lastGlucoseReading = lastReading
                self.delegateQueue.async {
                    self.cgmManagerDelegate.lastGlucoseReading = lastReading
                }
            }
        case .unreliableData:
            //loopManager.receivedUnreliableCGMReading()
            log.error("CGMManager: unreliable data, do something")
        case .noData:
            log.default("CGMManager: did update with no data")
        case .error(let error):
            log.default("CGMManager: did update with error: %{public}@", String(describing: error))
            self.setLastError(error: error)
        }
        updatePumpManagerBLEHeartbeatPreference()
    }
    
    func pumpSettingsUI(for pumpManager: PumpManagerUI) -> PumpManagerViewController {
        var settingsViewController = pumpManager.settingsViewController(bluetoothProvider: self.bluetoothProvider, colorPalette: .default, allowDebugFeatures: true, allowedInsulinTypes: allowedInsulinTypes)
        settingsViewController.pumpManagerOnboardingDelegate = pumpManagerDelegate
        
        return settingsViewController
    }
    func pumpSettingsUI() -> PumpManagerViewController? {
        guard let pumpManager = pumpManager else { return nil }
        return pumpSettingsUI(for: pumpManager)
    }
    
    func setupPumpManagerUI(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<PumpManagerViewController, PumpManagerUI>, Error> {
        guard let pumpManagerUIType = pumpManagerTypeByIdentifier(identifier) else {
            return .failure(UnknownPumpManagerIdentifierError())
        }

        let settings = getSettingsStorage().snapshot()
        let unitsPerHour = settings.pumpBasalRateUnitsPerHour
        let maxBasal = settings.maxBasalRateUnitsPerHour
        let maxBolus = settings.maxBolusUnits
        let schedule = RepeatingScheduleValue(startTime: 0.0, value: unitsPerHour)
        let rateSchedule = BasalRateSchedule(dailyItems: [schedule])!
        let initialSettings = PumpManagerSetupSettings(maxBasalRateUnitsPerHour: maxBasal, maxBolusUnits: maxBolus, basalSchedule: rateSchedule)
        
        let result = pumpManagerUIType.setupViewController(initialSettings: initialSettings, bluetoothProvider: bluetoothProvider, colorPalette: .default, allowDebugFeatures: allowDebugFeatures, allowedInsulinTypes: allowedInsulinTypes)
        switch result {
        case .userInteractionRequired(var setupViewController):
            setupViewController.pumpManagerOnboardingDelegate = pumpManagerDelegate
        case .createdAndOnboarded(let pumpManagerUI):
            pumpManagerDelegate.pumpManagerOnboarding(didCreatePumpManager: pumpManagerUI)
            pumpManagerDelegate.pumpManagerOnboarding(didOnboardPumpManager: pumpManagerUI)
        }

        return .success(result)
    }
    
    func cgmSettingsUI(for cgmManager: CGMManagerUI) -> CGMManagerViewController {
        let displayGlucoseUnit = observableObject().displayGlucoseUnit
        var settingsViewController = cgmManager.settingsViewController(bluetoothProvider: bluetoothProvider, displayGlucoseUnitObservable: displayGlucoseUnit, colorPalette: .default, allowDebugFeatures: allowDebugFeatures)
        settingsViewController.cgmManagerOnboardingDelegate = cgmManagerDelegate
        return settingsViewController
    }
    
    func cgmSettingsUI() -> CGMManagerViewController? {
        guard let cgmManager = cgmManager, let cgmManagerUI = cgmManager as? CGMManagerUI else { return nil }
        return cgmSettingsUI(for: cgmManagerUI)
    }
    
    func setupCGMManagerUI(withIdentifier identifier: String) -> Swift.Result<SetupUIResult<CGMManagerViewController, CGMManagerUI>, Error> {
        guard let cgmManagerUIType = cgmManagerTypeByIdentifier(identifier) else {
            return .failure(UnknownCGMManagerIdentifierError())
        }
        
        let displayGlucoseUnit = observableObject().displayGlucoseUnit
        let result = cgmManagerUIType.setupViewController(bluetoothProvider: bluetoothProvider, displayGlucoseUnitObservable: displayGlucoseUnit, colorPalette: .default, allowDebugFeatures: allowDebugFeatures)
        switch result {
        case .userInteractionRequired(var setupViewController):
            setupViewController.cgmManagerOnboardingDelegate = cgmManagerDelegate
        case .createdAndOnboarded(let cgmManagerUI):
            cgmManagerDelegate.cgmManagerOnboarding(didCreateCGMManager: cgmManagerUI)
            cgmManagerDelegate.cgmManagerOnboarding(didOnboardCGMManager: cgmManagerUI)
        }
        
        return .success(result)
    }
}
