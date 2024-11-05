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
    let dispatchQueue = InOrderTaskQueue.dispatchQueue
    let log = DiagnosticLog(category: "MosPumpManagerDelegate")
    var pumpManagerMustProvideBLEHeartbeat = true
    let alertStorage = getAlertStorage()
    
    // protocol stubs that I'm leaving blank for now
    var detectedSystemTimeOffset: TimeInterval {
        return 0.0
    }
    
    func deviceManager(_ manager: LoopKit.DeviceManager, logEventForDeviceIdentifier deviceIdentifier: String?, type: LoopKit.DeviceLogEntryType, message: String, completion: ((Error?) -> Void)?) {
        print("!!!! logEventForDeviceIdentifier: \(type): \(message)")
        completion?(nil)
    }
    
    func issueAlert(_ alert: LoopKit.Alert) {
        dispatchQueue.async {
            await self.alertStorage.issueAlert(alert)
            let activeAlert = await self.alertStorage.activeAlert()
            await getDeviceDataManager().update(activeAlert: activeAlert)
        }
    }
    
    func retractAlert(identifier: LoopKit.Alert.Identifier) {
        dispatchQueue.async {
            await self.alertStorage.retractAlert(identifier: identifier)
            let activeAlert = await self.alertStorage.activeAlert()
            await getDeviceDataManager().update(activeAlert: activeAlert)
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
        dispatchQueue.async { await getDeviceDataManager().updateRawPumpManager(to: pumpManager.rawValue) }
    }
    
    func pumpManagerBLEHeartbeatDidFire(_ pumpManager: PumpManager) {
        log.default("PumpManager:%{public}@ did fire heartbeat", String(describing: type(of: pumpManager)))
        Task {
            await dispatchQueue.waitForEventsToRun()
            await getDeviceDataManager().checkCgmDataAndLoop()
        }
    }
    
    func pumpManagerMustProvideBLEHeartbeat(_ pumpManager: PumpManager) -> Bool {
        return pumpManagerMustProvideBLEHeartbeat
    }
    
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        log.default("PumpManager:%{public}@ did update status: %{public}@", String(describing: type(of: pumpManager)), String(describing: status))
        dispatchQueue.async { await getDeviceDataManager().updatePumpIsAllowingAutomation(status: status) }
    }
    
    func pumpManagerPumpWasReplaced(_ pumpManager: PumpManager) {
        // PumpManagers should report a continuous dosing history, across pump changes
    }
    
    func pumpManagerWillDeactivate(_ pumpManager: PumpManager) {
        log.default("Pump manager with identifier '%{public}@' will deactivate", pumpManager.managerIdentifier)
        dispatchQueue.async { await getDeviceDataManager().updatePumpManager(to: nil) }
    }
    
    func pumpManager(_ pumpManager: PumpManager, didUpdatePumpRecordsBasalProfileStartEvents pumpRecordsBasalProfileStartEvents: Bool) {
        log.default("PumpManager:%{public}@ did update pumpRecordsBasalProfileStartEvents to %{public}@", String(describing: type(of: pumpManager)), String(describing: pumpRecordsBasalProfileStartEvents))
        
        dispatchQueue.async {
            await getInsulinStorage().setPumpRecordsBasalProfileStartEvents(pumpRecordsBasalProfileStartEvents)
        }
    }
    
    func pumpManager(_ pumpManager: PumpManager, didError error: PumpManagerError) {
        log.error("PumpManager:%{public}@ did error: %{public}@", String(describing: type(of: pumpManager)), String(describing: error))
        
        dispatchQueue.async { await getDeviceDataManager().setLastError(error: error) }
    }
    
    func pumpManager(_ pumpManager: PumpManager, hasNewPumpEvents events: [NewPumpEvent], lastReconciliation: Date?, completion: @escaping (_ error: Error?) -> Void) {
        log.default("PumpManager:%{public}@ hasNewPumpEvents (lastReconciliation = %{public}@)", String(describing: type(of: pumpManager)), String(describing: lastReconciliation))
        
        let insulinType = pumpManager.status.insulinType ?? .humalog
        dispatchQueue.async {
            let error = await getInsulinStorage().addPumpEvents(events, lastReconciliation: lastReconciliation, insulinType: insulinType)
            if let error = error {
                self.log.error("Failed to addPumpEvents to InsulinStorage: %{public}@", String(describing: error))
            }
            
            let insulinOnBoard = await getInsulinStorage().insulinOnBoard(at: Date())
            let pumpAlarm = await getInsulinStorage().pumpAlarm()
            await getDeviceDataManager().update(insulinOnBoard: insulinOnBoard, pumpAlarm: pumpAlarm)
            
            completion(error)
        }
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
        log.default("Pump manager with identifier '%{public}@' created", pumpManager.managerIdentifier)
        dispatchQueue.async {
            await getDeviceDataManager().updatePumpManager(to: pumpManager)
        }
    }

    func pumpManagerOnboarding(didOnboardPumpManager pumpManager: PumpManagerUI) {
        precondition(pumpManager.isOnboarded)
        log.default("Pump manager with identifier '%{public}@' onboarded", pumpManager.managerIdentifier)

        // FIXME: I would love analysis that shows when to use Task vs dispatchQueue.async
        // We're using Task here because the refreshCgmAndPumpDataFromUI call is complex
        // can calls out into a bunch of other services so we don't want it to occupy
        // the dispatchQueue that we use for ordering.
        //
        // Because we're using a task we might get more events that process before we
        // run but we're guarenteed to finish any currently pending tasks before running
        Task {
            await dispatchQueue.waitForEventsToRun()
            await getDeviceDataManager().refreshCgmAndPumpDataFromUI()
        }
    }

    func pumpManagerOnboarding(didPauseOnboarding pumpManager: PumpManagerUI) {
        
    }
}
