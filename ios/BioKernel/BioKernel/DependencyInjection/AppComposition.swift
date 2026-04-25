//
//  AppComposition.swift
//  BioKernel
//
//  Composition root: builds every service in dependency order and owns the
//  graph. Replaces the global `Dependency` registry.
//

import Foundation
import SwiftUI
import LoopKit
import LoopKitUI

@MainActor
final class AppComposition {
    // Tier 0 — no deps
    let storedObjectFactory: StoredObject.Type
    let http: Http
    let bluetoothProvider: BluetoothProvider

    // Tier 1 — storage / pure services
    let healthKitStorage: HealthKitStorage
    let settingsStorage: SettingsStorage
    let alertStorage: AlertStorage
    let safetyService: SafetyService
    let targetGlucoseService: TargetGlucoseService
    let machineLearning: MachineLearning
    let pushNotificationService: PushNotificationService

    // Tier 2 — physiology
    let physiologicalModels: PhysiologicalModels

    // Tier 3 — storage with notifier dependency
    let glucoseStorage: GlucoseStorage
    let insulinStorage: InsulinStorage

    // Tier 4 — watch + alerts
    let watchComms: WatchComms
    let glucoseAlertsService: GlucoseAlertStorage

    // Tier 5 — background
    let backgroundService: BackgroundService

    // Tier 6 — closed loop
    let closedLoopService: ClosedLoopService

    // Tier 7 — device (pump + CGM integration)
    let deviceDataManager: DeviceDataManager

    // UI-observable shared state
    let observableState: AppObservableState

    init() {
        // The app may be woken by CGM Bluetooth before first unlock (e.g. after
        // an OS update overnight). Downgrade every existing file in our
        // documents directory to FileProtectionType.none so reads on that wake
        // path don't fail. Files written from this build forward are already
        // .noFileProtection via StoredJsonObject / PersistedProperty; this
        // migration only matters for files left over from prior installs.
        AppComposition.migrateExistingFilesToNoFileProtection()

        // Late-bound boxes resolve cyclic dependencies. The storages need
        // WatchComms, alerts, and background-service references that don't
        // exist yet at storage-construction time; they're set before init
        // returns and read only when the storages later notify the rest of
        // the app.
        let watchCommsBox = LateBound<WatchComms>()
        let alertsBox = LateBound<GlucoseAlertStorage>()
        let backgroundBox = LateBound<BackgroundService>()
        let closedLoopBox = LateBound<ClosedLoopService>()

        // Tier 0 — leaves
        let storedObjectFactory: StoredObject.Type = StoredJsonObject.self
        let http = JsonHttp()
        let bluetoothProvider = BluetoothStateManager()
        let observableState = AppObservableState()
        let healthKitStorage = LocalHealthKitStorage(storedObjectFactory: storedObjectFactory)
        let targetGlucoseService = LocalTargetGlucoseService()
        let machineLearning = AIDosing()
        let pushNotificationService = LocalPushNotificationService()

        // Tier 1 — only Tier 0 deps
        let settingsStorage = LocalSettingsStorage(storedObjectFactory: storedObjectFactory)
        let alertStorage = LocalAlertStorage(storedObjectFactory: storedObjectFactory)
        let safetyService = LocalSafetyService(storedObjectFactory: storedObjectFactory)

        // Tier 3 — storages with forward-ref closures for the cyclic deps
        let glucoseStorage = LocalGlucoseStorage(
            storedObjectFactory: storedObjectFactory,
            healthKitStorage: healthKitStorage,
            glucoseAlertsService: { alertsBox.resolve() },
            backgroundService: { backgroundBox.resolve() },
            watchComms: { watchCommsBox.resolve() },
            observableState: observableState
        )
        let insulinStorage = LocalInsulinStorage(
            storedObjectFactory: storedObjectFactory,
            healthKitStorage: healthKitStorage,
            watchComms: { watchCommsBox.resolve() },
            settingsStorage: { settingsStorage }
        )

        // Tier 2 — physiology depends on storages
        let physiologicalModels = LocalPhysiologicalModels(
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage
        )

        // Tier 4 — alerts (concrete refs); fills in the box for storages
        let glucoseAlertsService = PredictiveGlucoseAlertStorage(
            storedObjectFactory: storedObjectFactory,
            glucoseStorage: glucoseStorage,
            physiologicalModels: physiologicalModels
        )
        alertsBox.set(glucoseAlertsService)

        // Tier 4 — watch comms (concrete refs); fills in the box for storages
        let watchComms = LocalWatchComms(
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: physiologicalModels,
            glucoseAlertsService: { alertsBox.resolve() }
        )
        watchCommsBox.set(watchComms)

        // Tier 6 — closed loop
        let closedLoopService = LoopRunner(
            storedObjectFactory: storedObjectFactory,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: physiologicalModels,
            targetGlucoseService: targetGlucoseService,
            machineLearning: machineLearning,
            safetyService: safetyService,
            settingsStorage: { settingsStorage },
            observableState: observableState
        )
        closedLoopBox.set(closedLoopService)

        // Tier 7 — device data manager (needs closed loop)
        let deviceDataManager = LocalDeviceDataManager(
            bluetoothProvider: bluetoothProvider,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            settingsStorage: settingsStorage,
            alertStorage: alertStorage,
            observableState: observableState,
            closedLoopService: { closedLoopBox.resolve() }
        )

        // Tier 5 — background service (depends on device data manager); fills
        // in the box for glucose storage's CGM-refresh notifications.
        let backgroundService = LocalBackgroundService(deviceDataManager: deviceDataManager)
        backgroundBox.set(backgroundService)

        // Assign to self
        self.storedObjectFactory = storedObjectFactory
        self.http = http
        self.bluetoothProvider = bluetoothProvider
        self.observableState = observableState
        self.healthKitStorage = healthKitStorage
        self.targetGlucoseService = targetGlucoseService
        self.machineLearning = machineLearning
        self.pushNotificationService = pushNotificationService
        self.settingsStorage = settingsStorage
        self.alertStorage = alertStorage
        self.safetyService = safetyService
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.physiologicalModels = physiologicalModels
        self.glucoseAlertsService = glucoseAlertsService
        self.watchComms = watchComms
        self.closedLoopService = closedLoopService
        self.deviceDataManager = deviceDataManager
        self.backgroundService = backgroundService
    }
}

// MARK: - BFU file-protection migration

extension AppComposition {
    fileprivate static func migrateExistingFilesToNoFileProtection() {
        let fileManager = FileManager.default
        guard let documents = try? fileManager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            print("BFU migration: could not resolve documents directory")
            return
        }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: documents, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        } catch {
            print("BFU migration: could not enumerate documents: \(error)")
            return
        }

        for url in contents {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let currentProtection = (try? fileManager.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType)?.rawValue ?? "unknown"
            print("BFU migration: \(url.lastPathComponent) current protection: \(currentProtection)")
            do {
                try fileManager.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
            } catch {
                print("BFU migration: failed to downgrade \(url.lastPathComponent): \(error)")
            }
        }
    }
}

// MARK: - Late binding for cyclic deps

private final class LateBound<T> {
    private var stored: T?
    func set(_ value: T) { stored = value }
    func resolve() -> T {
        guard let stored else { fatalError("LateBound resolved before being set") }
        return stored
    }
}

// MARK: - Environment injection

private struct AppCompositionKey: EnvironmentKey {
    static let defaultValue: AppComposition? = nil
}

extension EnvironmentValues {
    var composition: AppComposition? {
        get { self[AppCompositionKey.self] }
        set { self[AppCompositionKey.self] = newValue }
    }
}
