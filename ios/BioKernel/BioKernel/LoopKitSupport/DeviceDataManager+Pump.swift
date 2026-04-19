//
//  DeviceDataManager+Pump.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import LoopKit
import LoopKitUI

// MARK: - PumpManagerDelegate
class MosPumpManagerDelegate: PumpManagerDelegate {
    let insulinStorage: InsulinStorage
    let alertStorage: AlertStorage
    let observableState: AppObservableState
    weak var deviceDataManager: DeviceDataManager?

    init(insulinStorage: InsulinStorage, alertStorage: AlertStorage, observableState: AppObservableState) {
        self.insulinStorage = insulinStorage
        self.alertStorage = alertStorage
        self.observableState = observableState
    }

    func pumpManager(_ pumpManager: any LoopKit.PumpManager, hasNewPumpEvents events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, completion: @escaping ((any Error)?) -> Void) {

        log.default("PumpManager:%{public}@ hasNewPumpEvents (lastReconciliation = %{public}@)", String(describing: type(of: pumpManager)), String(describing: lastReconciliation))

        let insulinType = pumpManager.status.insulinType ?? .humalog
        let insulinStorage = self.insulinStorage
        let observableState = self.observableState
        dispatchQueue.async {
            let error = await insulinStorage.addPumpEvents(events, lastReconciliation: lastReconciliation, insulinType: insulinType)
            if let error = error {
                self.log.error("Failed to addPumpEvents to InsulinStorage: %{public}@", String(describing: error))
            }

            let insulinOnBoard = await insulinStorage.insulinOnBoard(at: Date())
            let pumpAlarm = await insulinStorage.pumpAlarm()
            await MainActor.run {
                observableState.insulinOnBoard = insulinOnBoard
                observableState.pumpAlarm = pumpAlarm
            }

            completion(error)
        }
    }

    func pumpManager(_ pumpManager: any LoopKit.PumpManager, didRequestBasalRateScheduleChange basalRateSchedule: LoopKit.BasalRateSchedule, completion: @escaping ((any Error)?) -> Void) {
        // figure this out later
    }

    var automaticDosingEnabled: Bool = false

    let dispatchQueue = InOrderTaskQueue.dispatchQueue
    let log = DiagnosticLog(category: "MosPumpManagerDelegate")
    var pumpManagerMustProvideBLEHeartbeat = true

    // protocol stubs that I'm leaving blank for now
    var detectedSystemTimeOffset: TimeInterval {
        return 0.0
    }

    func deviceManager(_ manager: LoopKit.DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: LoopKit.DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        print("!!!! logEventForDeviceIdentifier: \(type): \(message)")
        completion?(nil)
    }

    func issueAlert(_ alert: LoopKit.Alert) {
        let observableState = self.observableState
        dispatchQueue.async {
            await self.alertStorage.issueAlert(alert)
            let activeAlert = await self.alertStorage.activeAlert()
            await MainActor.run { observableState.activeAlert = activeAlert }
        }
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        let observableState = self.observableState
        dispatchQueue.async {
            await self.alertStorage.retractAlert(identifier: identifier)
            let activeAlert = await self.alertStorage.activeAlert()
            await MainActor.run { observableState.activeAlert = activeAlert }
        }
    }

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier, completion: @escaping (Result<Bool, Error>) -> Void) {
        dispatchQueue.async {
            let alertExists = await self.alertStorage.doesIssuedAlertExist(identifier: identifier)
            completion(alertExists)
        }
    }

    func lookupAllUnretracted(managerIdentifier: String, completion: @escaping (Result<[LoopKit.PersistedAlert], Error>) -> Void) {
        dispatchQueue.async {
            let unretractedAlerts = await self.alertStorage.lookupAllUnretracted(managerIdentifier: managerIdentifier)
            completion(unretractedAlerts)
        }
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String, completion: @escaping (Result<[LoopKit.PersistedAlert], Error>) -> Void) {
        dispatchQueue.async {
            let unacknowledgedUnretractedAlerts = await self.alertStorage.lookupAllUnacknowledgedUnretracted(managerIdentifier: managerIdentifier)
            completion(unacknowledgedUnretractedAlerts)
        }
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) {
        dispatchQueue.async {
            await self.alertStorage.recordRetractedAlert(alert, at: date)
        }
    }
    ///

    func pumpManager(_ pumpManager: PumpManager, didAdjustPumpClockBy adjustment: TimeInterval) {
        log.default("PumpManager:%{public}@ did adjust pump clock by %fs", String(describing: type(of: pumpManager)), adjustment)
    }

    func pumpManagerDidUpdateState(_ pumpManager: PumpManager) {
        log.default("PumpManager:%{public}@ did update state", String(describing: type(of: pumpManager)))
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updateRawPumpManager(to: pumpManager.rawValue) }
    }

    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {
        log.default("PumpManager:%{public}@ did fire heartbeat", String(describing: type(of: pumpManager)))
        let deviceDataManager = self.deviceDataManager
        Task {
            await dispatchQueue.waitForEventsToRun()
            await deviceDataManager?.checkCgmDataAndLoop()
        }
    }

    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool {
        return pumpManagerMustProvideBLEHeartbeat
    }

    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        log.default("PumpManager:%{public}@ did update status: %{public}@", String(describing: type(of: pumpManager)), String(describing: status))
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updatePumpIsAllowingAutomation(status: status) }
    }

    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {
        // PumpManagers should report a continuous dosing history, across pump changes
    }

    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        log.default("Pump manager with identifier '%{public}@' will deactivate", pumpManager.pluginIdentifier)
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.updatePumpManager(to: nil) }
    }

    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {
        log.default("PumpManager:%{public}@ did update pumpRecordsBasalProfileStartEvents to %{public}@", String(describing: type(of: pumpManager)), String(describing: pumpRecordsBasalProfileStartEvents))

        let insulinStorage = self.insulinStorage
        dispatchQueue.async {
            await insulinStorage.setPumpRecordsBasalProfileStartEvents(pumpRecordsBasalProfileStartEvents)
        }
    }

    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        log.error("PumpManager:%{public}@ did error: %{public}@", String(describing: type(of: pumpManager)), String(describing: error))

        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async { await deviceDataManager?.setLastError(error: error) }
    }
    
    func pumpManager(_ pumpManager: PumpManager, didReadReservoirValue units: Double, at date: Date, completion: @escaping (_ result: Swift.Result<(newValue: ReservoirValue, lastValue: ReservoirValue?, areStoredValuesContinuous: Bool), Error>) -> Void) {
        log.default("PumpManager:%{public}@ did read reservoir value", String(describing: type(of: pumpManager)))
        
        /*
         loopManager.addReservoirValue(units, at: date) { (result) in
         switch result {
         case .failure(let error):
         self.log.error("Failed to addReservoirValue: %{public}@", String(describing: error))
         completion(.failure(error))
         case .success(let (newValue, lastValue, areStoredValuesContinuous)):
         completion(.success((newValue: newValue, lastValue: lastValue, areStoredValuesContinuous: areStoredValuesContinuous)))
         }
         }*/
    }
    
    func startDateToFilterNewPumpEvents(for manager: PumpManager) -> Date {
        return Date(timeIntervalSinceNow: -24.hoursToSeconds())
    }
}

// MARK: - PumpManagerOnboardingDelegate
// These will all run on the Main queue
extension MosPumpManagerDelegate: PumpManagerOnboardingDelegate {
    func pumpManagerOnboarding(didCreatePumpManager pumpManager: PumpManagerUI) {
        log.default("Pump manager with identifier '%{public}@' created", pumpManager.pluginIdentifier)
        let deviceDataManager = self.deviceDataManager
        dispatchQueue.async {
            await deviceDataManager?.updatePumpManager(to: pumpManager)
        }
    }

    func pumpManagerOnboarding(didOnboardPumpManager pumpManager: PumpManagerUI) {
        precondition(pumpManager.isOnboarded)
        log.default("Pump manager with identifier '%{public}@' onboarded", pumpManager.pluginIdentifier)

        // FIXME: I would love analysis that shows when to use Task vs dispatchQueue.async
        // We're using Task here because the refreshCgmAndPumpDataFromUI call is complex
        // can calls out into a bunch of other services so we don't want it to occupy
        // the dispatchQueue that we use for ordering.
        //
        // Because we're using a task we might get more events that process before we
        // run but we're guarenteed to finish any currently pending tasks before running
        let deviceDataManager = self.deviceDataManager
        Task {
            await dispatchQueue.waitForEventsToRun()
            await deviceDataManager?.refreshCgmAndPumpDataFromUI()
        }
    }

    func pumpManagerOnboarding(didPauseOnboarding pumpManager: PumpManagerUI) {
        
    }
}
