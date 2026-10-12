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
    @Environment(\.scenePhase) private var scenePhase
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
                    .environmentObject(composition.doseProgress)
                    .environmentObject(composition.glucoseAlertsService.viewModel())
                    // Launch. `onChange` below only fires on a *change*, and
                    // the first `.active` can be in place before the observer
                    // attaches, so a cold start needs its own call.
                    .task { await ingestMealAnnouncements() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await ingestMealAnnouncements() }
        }
    }

    /// Copy any meal announcements AI apps have published into our store.
    ///
    /// Also done at the top of every loop tick, which is where the *deadline*
    /// is met — the interface files retain two days, so ingestion is the only
    /// thing standing between an announcement and being lost. This is about
    /// *freshness* instead, and it exists because the loop is not a schedule we
    /// can lean on for it: `DeviceDataManager.checkPumpDataAndLoop` returns
    /// early with no pump manager and throttles to one run per 4.2 minutes, so
    /// on a phone with no pump paired the loop path ingests nothing at all, and
    /// even with one the Meals view could sit minutes behind the file.
    ///
    /// Deliberately **not** debounced. A redundant ingest is two small file
    /// reads and a pass of no-op upserts, while a debounce would break the
    /// handoff: an AI app appends an announcement and opens our universal link
    /// immediately, and `MainView` ingests before resolving it. Skipping that
    /// call because another had just run is how the link fails to find its meal.
    private func ingestMealAnnouncements() async {
        guard let composition else { return }
        await composition.mealStorage.ingest(at: Date())
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
