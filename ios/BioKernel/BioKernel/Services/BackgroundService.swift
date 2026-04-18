//
//  BackgroundService.swift
//  BioKernel
//
//  Created by Sam King on 7/9/24.
//

import BackgroundTasks
import G7SensorKit

@MainActor protocol BackgroundService {
    func registerBackgroundTask()
    func scheduleAppRefresh()
}

// Todo:
//  - Reset 30 minute timer on successful CGM readings
//  - Show a notification if we're disconnected for too long

@MainActor
class LocalBackgroundService: BackgroundService {
    let backgroundTaskId = "com.getgrowthmetrics.BioKernel.background"
    let maxBackgroundWaitTime = 30.minutesToSeconds()
    static let shared = LocalBackgroundService()
    var printFirstMessage = true
    
    func checkForCgmConnectivity() async {
        print("\(Date()): Running in background")
        guard let cgmManager = getDeviceDataManager().cgmManager else {
            print("\(Date()): No CGM manager")
            return
        }
        print("\(Date()): fetchNewDataIfNeeded")
        if let g7CgmManager = cgmManager as? G7CGMManager {
            print("\(Date()): G7 connected -> \(g7CgmManager.isConnected) scanning -> \(g7CgmManager.isScanning)")
        }
        let _ = await cgmManager.fetchNewDataIfNeeded()
        if let g7CgmManager = cgmManager as? G7CGMManager {
            print("\(Date()): post call G7 connected -> \(g7CgmManager.isConnected) scanning -> \(g7CgmManager.isScanning)")
        }
    }

    func registerBackgroundTask() {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown build"
        print("\(Date()): registerBackgroundTask for \(appVersion) (\(buildNumber))")
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskId, using: nil) { [weak self] task in
            guard let self = self else {
                task.setTaskCompleted(success: true)
                return
            }
            Task { @MainActor in
                await self.checkForCgmConnectivity()
                self.scheduleAppRefresh()
                task.setTaskCompleted(success: true)
            }
        }
        scheduleAppRefresh()
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskId)
        let deadline = Date(timeIntervalSinceNow: maxBackgroundWaitTime)
        request.earliestBeginDate = deadline

        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled app refresh")
            if printFirstMessage {
                print("\(Date()): submitted app refresh")
                printFirstMessage = false
            }
        } catch {
            print("Could not schedule app refresh: \(error)")
            if printFirstMessage {
                print("\(Date()): Could not schedule app refresh: \(error)")
                printFirstMessage = false
            }
        }
    }
}
