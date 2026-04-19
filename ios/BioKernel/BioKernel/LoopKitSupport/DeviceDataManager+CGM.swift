//
//  DeviceDataManager+CGM.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//
// This class acts as a bridge between LoopKit and the BioKernel. It is a delegate
// for CGM events from LoopKit and uses these events to update state and act
// using our BioKernel abstractions. Since we use actors and async/await for
// our abstractions we need to use an InOrderTaskQueue to make sure that
// we handle all messages in order. This implementation is a bit different then
// Loop because we will return from a delegate function before state updates
// are complete, but by ordering them properly it should still maintain correctness
// even if state updates might happen after the message handler finishes.

import LoopKit
import LoopKitUI

// MARK: - CGMManagerDelegate
class MosCgmManagerDelegate: CGMManagerDelegate {
    weak var deviceDataManager: DeviceDataManager?

    func cgmManager(_ manager: any LoopKit.CGMManager, hasNew events: [LoopKit.PersistedCgmEvent]) {
        // figure this out later
    }

    let dispatchQueue = InOrderTaskQueue.dispatchQueue

    // This value is a cache set by the DeviceManager after getting new glucose readings
    var lastGlucoseReading: NewGlucoseSample? = nil
    let storagePrefix = UUID().uuidString

    // FIXME: Fill these in later
    func deviceManager(_ manager: LoopKit.DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: LoopKit.DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {

    }

    func issueAlert(_ alert: LoopKit.Alert) {

    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {

    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Result<Bool, Error>) -> Void) {

    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Result<[LoopKit.PersistedAlert], Error>) -> Void) {

    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Result<[LoopKit.PersistedAlert], Error>) -> Void) {

    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {

    }

    let log = DiagnosticLog(category: "MosCgmManagerDelegate")
    func cgmManagerWantsDeletion(_ manager: CGMManager) {
        log.default("CGM manager with identifier '%{public}@' wants deletion", manager.pluginIdentifier)
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updateCgmManager(to: nil) }
    }

    func cgmManager(_ manager: CGMManager, hasNew readingResult: CGMReadingResult) {
        log.default("CGM manager has new readings")
        // put this in a task instead of our dispatchQueue because it's going to run the
        // closed loop algorithm
        let deviceDataManager = self.deviceDataManager
        Task {
            await dispatchQueue.waitForEventsToRun()
            await deviceDataManager?.newCgmDataAvailable(readingResult: readingResult)
        }
    }

    func startDateToFilterNewData(for manager: CGMManager) -> Date? {
        return lastGlucoseReading?.date
    }

    func cgmManagerDidUpdateState(_ manager: CGMManager) {
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updateRawCgmManager(to: manager.rawValue) }
    }

    func credentialStoragePrefix(for manager: CGMManager) -> String {
        // return string unique to this instance of the CGMManager
        return storagePrefix
    }

    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updateCgm(hasValidSensorSession: status.hasValidSensorSession) }
    }
}

// MARK: - CGMManagerOnboardingDelegate

extension MosCgmManagerDelegate: CGMManagerOnboardingDelegate {
    func cgmManagerOnboarding(didCreateCGMManager cgmManager: CGMManagerUI) {
        log.default("CGM manager with identifier '%{public}@' created", cgmManager.pluginIdentifier)
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updateCgmManager(to: cgmManager) }
    }

    func cgmManagerOnboarding(didOnboardCGMManager cgmManager: CGMManagerUI) {
        precondition(cgmManager.isOnboarded)
        log.default("CGM manager with identifier '%{public}@' onboarded", cgmManager.pluginIdentifier)
        let deviceDataManager = self.deviceDataManager
        Task {
            await dispatchQueue.waitForEventsToRun()
            await deviceDataManager?.refreshCgmAndPumpDataFromUI()
        }
    }
}
