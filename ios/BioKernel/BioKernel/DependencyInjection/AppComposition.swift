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
    let aiInterfaceStorage: AiInterfaceStorage
    let mealAnnouncementStorage: MealAnnouncementStorage
    let mealStorage: MealStorage
    /// The complete record of pump-reported events, and the only thing insulin
    /// arithmetic derives from. See dev/backlog/insulin-storage-grdb.md.
    let insulinRecordStore: InsulinRecordStore?
    /// What each loop tick decided, plus the machine-learning insulin budget
    /// ledger, in one database and one transaction per tick. Replaced
    /// `closed_loop_results.json` and `safety_states.json`. See
    /// dev/backlog/loop-record-store-grdb.md.
    let loopRecordStore: LoopRecordStore?

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
    let doseProgress: DoseProgress

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
        let doseProgress = DoseProgress()
        let healthKitStorage = LocalHealthKitStorage(storedObjectFactory: storedObjectFactory)
        let targetGlucoseService = LocalTargetGlucoseService()
        let machineLearning = AIDosing()
        let pushNotificationService = LocalPushNotificationService()

        // Tier 1 — only Tier 0 deps
        let settingsStorage = LocalSettingsStorage(storedObjectFactory: storedObjectFactory)
        let alertStorage = LocalAlertStorage(recordStore: AppComposition.makeAlertRecordStore())

        // Built here rather than beside the closed loop service in Tier 6,
        // because the safety service reads the ledger out of it and is a Tier 1
        // dependency of the pipeline.
        let loopRecordStore = AppComposition.makeLoopRecordStore()
        let safetyService = LocalSafetyService(recordStore: loopRecordStore)

        // Tier 3 — storages with forward-ref closures for the cyclic deps
        //
        // 90 days of CGM readings, indexed. Unlike the insulin store there is no
        // parallel run and no cutover: glucose has no dose lifecycle to reconcile
        // and nothing is inferred between two readings, so the store has been
        // authoritative from its first launch. The old `glucose.json` log was
        // imported once and nothing reads it now.
        // Publishes insulin delivery and CGM readings into the shared app-group
        // container for AI apps. Constructed before the storages that feed it
        // because it has no dependency back on any of them — they push to it,
        // never the other way round. A nil container (app group missing from the
        // signed profile) makes every export a logged no-op.
        let aiInterfaceStorage = LocalAiInterfaceStorage(
            container: AiInterfaceContainer.appGroupContainer(),
            stateStorage: storedObjectFactory.create(fileName: "ai_export_state.json")
        )

        let glucoseRecordStore = AppComposition.makeGlucoseRecordStore()
        let glucoseStorage = LocalGlucoseStorage(
            healthKitStorage: healthKitStorage,
            recordStore: glucoseRecordStore,
            aiInterfaceStorage: aiInterfaceStorage,
            glucoseAlertsService: { alertsBox.resolve() },
            backgroundService: { backgroundBox.resolve() },
            watchComms: { watchCommsBox.resolve() },
            observableState: observableState
        )

        // The other direction across the same container: what AI apps publish
        // for us. Read-only and display-only — no service depends on it, and
        // nothing it returns reaches the loop.
        let mealAnnouncementStorage = LocalMealAnnouncementStorage(
            aiDirectoryURL: AiInterfaceContainer.sharedAiDirectoryURL()
        )

        // The complete, indexed store of pump-reported events, and the only
        // source insulin arithmetic derives from. A store that fails to open
        // leaves this nil, which is the dosing outage §8 says it is: there is no
        // longer a JSON log to fall back to, so `LocalInsulinStorage` reports
        // stale pump data and the loop skips rather than dosing off nothing.
        let insulinRecordStore = AppComposition.makeInsulinRecordStore(
            // dev/backlog/scheduled-basal-history.md §4.2: the rate to stamp on
            // resumes that predate the `scheduled_basal` table. Read once here, at
            // migration time, and a no-op on any store with no existing resumes.
            backfillRateUnitsPerHour: settingsStorage.snapshot().pumpBasalRateUnitsPerHour
        )

        let insulinStorage = LocalInsulinStorage(
            healthKitStorage: healthKitStorage,
            watchComms: { watchCommsBox.resolve() },
            settingsStorage: { settingsStorage },
            aiInterfaceStorage: aiInterfaceStorage,
            recordStore: insulinRecordStore
        )

        // Tier 2 — physiology depends on storages
        let physiologicalModels = LocalPhysiologicalModels(
            storedObjectFactory: storedObjectFactory,
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

        // Tier 5 — meals. Needs glucose (for the run-to-run window), settings
        // (for the cold-start dose) and the low alert level, so it lands after
        // the alerts box is filled in. Nothing depends back on it: the loop
        // calls `ingest` and the views read it, and neither the pipeline nor
        // the safety service knows it exists.
        let mealStorage = LocalMealStorage(
            announcementStorage: mealAnnouncementStorage,
            recordStore: AppComposition.makeMealRecordStore(),
            glucoseStorage: glucoseStorage,
            settingsStorage: { settingsStorage },
            glucoseAlertsService: { alertsBox.resolve() }
        )

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
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: physiologicalModels,
            targetGlucoseService: targetGlucoseService,
            machineLearning: machineLearning,
            safetyService: safetyService,
            settingsStorage: { settingsStorage },
            observableState: observableState,
            doseProgress: doseProgress,
            recordStore: loopRecordStore,
            aiInterfaceStorage: aiInterfaceStorage,
            mealStorage: mealStorage
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
        self.doseProgress = doseProgress
        self.healthKitStorage = healthKitStorage
        self.targetGlucoseService = targetGlucoseService
        self.machineLearning = machineLearning
        self.pushNotificationService = pushNotificationService
        self.settingsStorage = settingsStorage
        self.alertStorage = alertStorage
        self.safetyService = safetyService
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.aiInterfaceStorage = aiInterfaceStorage
        self.mealAnnouncementStorage = mealAnnouncementStorage
        self.mealStorage = mealStorage
        self.insulinRecordStore = insulinRecordStore
        self.loopRecordStore = loopRecordStore
        self.physiologicalModels = physiologicalModels
        self.glucoseAlertsService = glucoseAlertsService
        self.watchComms = watchComms
        self.closedLoopService = closedLoopService
        self.deviceDataManager = deviceDataManager
        self.backgroundService = backgroundService
    }
}

// MARK: - Glucose record store

extension AppComposition {
    /// nil when the store cannot be opened, which leaves the app glucose-blind:
    /// no readings, no alerts, and — because `LoopRunner` refuses to dose without
    /// a fresh reading — no dosing. That is the safe direction rather than a good
    /// outcome, and `LocalGlucoseStorage` logs every read that lands on it.
    fileprivate static func makeGlucoseRecordStore() -> GlucoseRecordStore? {
        guard let url = GRDBGlucoseRecordStore.defaultURL() else {
            print("glucose record store: could not resolve a documents directory")
            return nil
        }
        do {
            // `createdAt` only takes effect the first time the store is opened;
            // `INSERT OR IGNORE` keeps the original on every launch after that.
            return try GRDBGlucoseRecordStore(url: url, createdAt: Date())
        } catch {
            print("glucose record store: could not open: \(error)")
            return nil
        }
    }
}

// MARK: - Alert record store

extension AppComposition {
    /// nil when the store cannot be opened, which leaves the app unable to
    /// persist alerts. `LocalAlertStorage` logs every call that lands on it and
    /// the app keeps looping — an alert is a notification about the pump, not an
    /// input to dosing, so unlike the glucose store there is nothing here that
    /// should stop insulin delivery.
    fileprivate static func makeAlertRecordStore() -> AlertRecordStore? {
        guard let url = GRDBAlertRecordStore.defaultURL() else {
            print("alert record store: could not resolve a documents directory")
            return nil
        }
        do {
            return try GRDBAlertRecordStore(url: url)
        } catch {
            print("alert record store: could not open: \(error)")
            return nil
        }
    }
}

// MARK: - Loop record store

extension AppComposition {
    /// nil when the store cannot be opened, which is a degraded app rather than
    /// a stopped one: the loop still runs and still doses, because insulin
    /// delivery does not depend on being able to write down what it did. What is
    /// lost is the chart, the micro-bolus throttle, and — most importantly — the
    /// machine-learning insulin budget, which `LocalSafetyService` then refuses
    /// entirely rather than treating an unreadable ledger as an empty one.
    ///
    /// Contrast the glucose store, whose absence *does* stop dosing: the loop
    /// refuses to run without a fresh reading, and that is the right direction
    /// there. Here the conservative direction is to keep delivering the
    /// physiological model's number.
    fileprivate static func makeLoopRecordStore() -> LoopRecordStore? {
        guard let url = GRDBLoopRecordStore.defaultURL() else {
            print("loop record store: could not resolve a documents directory")
            return nil
        }
        do {
            // `createdAt` only takes effect the first time the store is opened —
            // `INSERT OR IGNORE` keeps the original — so passing the current
            // instant on every launch does not re-open the fail-closed window
            // that `safety_history_complete_since` guards.
            return try GRDBLoopRecordStore(url: url, createdAt: Date())
        } catch {
            print("loop record store: could not open: \(error)")
            return nil
        }
    }
}

// MARK: - Insulin record store (phase 1)

extension AppComposition {
    fileprivate static func makeInsulinRecordStore(backfillRateUnitsPerHour: Double) -> InsulinRecordStore? {
        guard let url = GRDBInsulinRecordStore.defaultURL() else {
            print("insulin record store: could not resolve a documents directory")
            return nil
        }
        do {
            // `createdAt` is only used the first time the store is opened —
            // `INSERT OR IGNORE` keeps the original — so passing the current
            // instant on every launch does not move I4's left edge. The backfill
            // rate is likewise only consumed by the migration that introduces
            // `scheduled_basal`, and that migration selects existing resume rows,
            // so it is a no-op on a store with none.
            return try GRDBInsulinRecordStore(
                url: url,
                createdAt: Date(),
                backfillRateUnitsPerHour: backfillRateUnitsPerHour
            )
        } catch {
            print("insulin record store: could not open: \(error)")
            return nil
        }
    }

}

// MARK: - Meal record store

extension AppComposition {
    /// nil when the store cannot be opened, which costs the meal features and
    /// nothing else: `LocalMealStorage` logs every call that lands on it, the
    /// Meals view is empty, and the announcement view falls back to the
    /// cold-start dose because there is no history to adapt from.
    ///
    /// Closest in spirit to the alert store — the loop still runs and still
    /// doses, because meal announcements have never been an input to insulin
    /// delivery. What is lost is a record of what the user was told, and one
    /// repeat's worth of learning per meal.
    fileprivate static func makeMealRecordStore() -> MealRecordStore? {
        guard let url = GRDBMealRecordStore.defaultURL() else {
            print("meal record store: could not resolve a documents directory")
            return nil
        }
        do {
            return try GRDBMealRecordStore(url: url)
        } catch {
            print("meal record store: could not open: \(error)")
            return nil
        }
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
