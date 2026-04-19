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
    let composition: AppComposition?

    init() {
        //G7CGMManager.debugLogger = getDebugLogger()
        if isRunningTests {
            self.composition = nil
        } else {
            let composition = AppComposition()
            self.composition = composition
            composition.backgroundService.registerBackgroundTask()
        }
        appDelegate.composition = self.composition
    }
    var body: some Scene {
        WindowGroup {
            // This check is because our persisted properties run on HomeView and trigger
            // a bunch of code before our unit tests run. I don't know how to avoid
            // this but for now it's ok.
            if isRunningTests {
                Text("Running tests")
            } else if let composition {
                MainView()
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .environment(\.composition, composition)
                    .environmentObject(composition.observableState)
                    .environmentObject(composition.glucoseAlertsService.viewModel())
            }
        }
    }
}

@MainActor
class MyAppDelegate: NSObject, UIApplicationDelegate {
    var composition: AppComposition?
    var sessionDelegator: SessionDelegator = SessionDelegator()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {

        guard !isRunningTests else { return true }

        assert(WCSession.isSupported())
        WCSession.default.delegate = sessionDelegator
        WCSession.default.activate()

        composition?.pushNotificationService.register(application: application)

        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        composition?.pushNotificationService.didFailToRegister(error: error)
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !isRunningTests else { return }
        composition?.pushNotificationService.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any]) async -> UIBackgroundFetchResult {

        guard !isRunningTests else { return .failed }

        print("\(Date()): PUSH Running in background")
        guard let cgmManager = composition?.deviceDataManager.cgmManager else {
            print("\(Date()): PUSH No CGM manager")
            return .failed
        }
        print("\(Date()): PUSH fetchNewDataIfNeeded")
        if let g7CgmManager = cgmManager as? G7CGMManager {
            print("\(Date()): PUSH G7 connected -> \(g7CgmManager.isConnected) scanning -> \(g7CgmManager.isScanning)")
        }
        let _ = await cgmManager.fetchNewDataIfNeeded()
        if let g7CgmManager = cgmManager as? G7CGMManager {
            print("\(Date()): PUSH post call G7 connected -> \(g7CgmManager.isConnected) scanning -> \(g7CgmManager.isScanning)")
        }

        return .newData
    }

}
