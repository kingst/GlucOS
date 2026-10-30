//
//  CheckCgmConnectionIntent.swift
//  BioKernel
//

import AppIntents
import Foundation

/// The Shortcuts action behind the overnight watchdog (dev/backlog/shortcuts-wake.md).
///
/// The launch is the point, not the work. Running this from a Time of Day
/// automation launches BioKernel in the background, `BioKernelApp.init` builds
/// `AppComposition`, and that creates the CGM and pump centrals with their
/// restore identifiers, so bluetoothd has restorable sessions again even after
/// it reaped the old ones (the 2026-10-29 userspace reboot). `perform()` only
/// adds a G7 re-scan and a fresh app refresh request on top of that.
///
/// Keep this in the app target. App Intents run in the process that compiled
/// them, and the widget extension and watch app have no composition.
struct CheckCgmConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Check CGM Connection"
    static let description = IntentDescription(
        "Wakes GlucOS in the background and re-arms its sensor and pump connections."
    )
    static let openAppWhenRun = false
    /// Run on a locked phone. Our files are `NSFileProtectionNone`
    /// (`AppComposition.migrateExistingFilesToNoFileProtection`), so even a
    /// launch before first unlock can read them.
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    /// Registered in `BioKernelApp.init`; the system builds intents itself,
    /// so there is no constructor to inject through. Nil under tests.
    @Dependency private var composition: AppComposition?

    @MainActor
    func perform() async throws -> some IntentResult {
        let log = DiagnosticLog(category: "CheckCgmConnectionIntent")
        log.default("perform: start")

        guard let composition else {
            log.error("perform: no composition")
            throw CheckCgmConnectionError.notReady
        }

        // Not `refreshCgmAndPumpDataFromUI`: that adds a pod round trip we
        // don't want inside an intent's time budget. For the G7 this is just
        // `resumeScanning()` and returns `.noData` right away.
        await composition.deviceDataManager.checkCgmData()
        composition.backgroundService.scheduleAppRefresh()

        // Diagnostics only: lets a log archive tell a wake that found a live
        // store from one that found a stale one.
        if let lastReading = await composition.glucoseStorage.lastReading() {
            let minutes = Date().timeIntervalSince(lastReading.date) / 60
            log.default("perform: done, last reading %{public}.1f min ago", minutes)
        } else {
            log.default("perform: done, no readings")
        }

        // Nothing the shortcut can branch on, by design: no stale-data alert.
        return .result()
    }
}

enum CheckCgmConnectionError: Error, CustomLocalizedStringResourceConvertible {
    case notReady

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady:
            return "GlucOS is not ready to check its CGM connection."
        }
    }
}
