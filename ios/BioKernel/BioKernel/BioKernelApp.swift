//
//  BioKernelApp.swift
//  BioKernel
//
//  Created by Sam King on 11/2/23.
//

import SwiftUI
import G7SensorKit
import WatchConnectivity

@main
struct BioKernelApp: App {
    @UIApplicationDelegateAdaptor(MyAppDelegate.self) var appDelegate
    
    init() {
        //G7CGMManager.debugLogger = getDebugLogger()
        guard !isRunningTests else { return }
        getBackgroundService().registerBackgroundTask()
        appDelegate.sessionDelegator.delegate = getWorkoutStatusService()
    }
    var body: some Scene {
        WindowGroup {
            // This check is because our persisted properties run on HomeView and trigger
            // a bunch of code before our unit tests run. I don't know how to avoid
            // this but for now it's ok.
            if isRunningTests {
                Text("Running tests")
            } else {
                MainView()
                    .toolbarColorScheme(.dark, for: .navigationBar)
            }
        }
    }
}

@MainActor
class MyAppDelegate: NSObject, UIApplicationDelegate {
    var sessionDelegator: SessionDelegator = SessionDelegator()
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        guard !isRunningTests else { return true }
        
        assert(WCSession.isSupported())
        WCSession.default.delegate = sessionDelegator
        WCSession.default.activate()
        
        print("BACK: registering for remote notifications")
        application.registerForRemoteNotifications()
        return true
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        print("BACK: failed to register \(error)")
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !isRunningTests else { return }
        
        let hexToken = deviceToken.map { String(format: "%02hhx", $0) }.joined()
        print("BACK: didRegisterForRemoteNotifications, hextoken: \(hexToken)")
        Task {
            await getEventLogger().update(deviceToken: hexToken)
            await getEventLogger().add(debugMessage: "\(Date()) didRegisterForRemoteNotifications, hextoken: \(hexToken)")
        }
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any]) async -> UIBackgroundFetchResult {

        guard !isRunningTests else { return .failed }
        
        await getEventLogger().add(debugMessage: "\(Date()): PUSH Running in background")
        guard let cgmManager = getDeviceDataManager().cgmManager else {
            await getEventLogger().add(debugMessage: "\(Date()): PUSH No CGM manager")
            return .failed
        }
        await getEventLogger().add(debugMessage: "\(Date()): PUSH fetchNewDataIfNeeded")
        if let g7CgmManager = cgmManager as? G7CGMManager {
            await getEventLogger().add(debugMessage: "\(Date()): PUSH G7 connected -> \(g7CgmManager.isConnected) scanning -> \(g7CgmManager.isScanning)")
        }
        let _ = await cgmManager.fetchNewDataIfNeeded()
        if let g7CgmManager = cgmManager as? G7CGMManager {
            await getEventLogger().add(debugMessage: "\(Date()): PUSH post call G7 connected -> \(g7CgmManager.isConnected) scanning -> \(g7CgmManager.isScanning)")
        }

        return .newData
    }

}
