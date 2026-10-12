//
//  AlertStorage.swift
//  BioKernel
//
//  Created by Sam King on 11/12/23.
//
//  The app-facing alert seam, and LoopKit's `PersistedAlertStore` in everything
//  but name — `DeviceDataManager+Pump` forwards each delegate callback straight
//  through to it.
//
//  Storage itself lives in `AlertRecordStore`; this type holds no alerts. It
//  owns two things the store deliberately does not: the decision about how the
//  app degrades when there is no store, and the conversion from `throws` to the
//  `Result` shape LoopKit's completion handlers want.
//
//  Nothing here reads `alerts.json` any more, and nothing imported it — see
//  `GRDBAlertRecordStore`'s v1 migration for why starting empty was the right
//  cutover for this store in particular.
//

import Foundation
import LoopKit

protocol AlertStorage {
    func issueAlert(_ alert: LoopKit.Alert) async
    func retractAlert(identifier: LoopKit.Alert.Identifier) async
    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async -> Result<Bool, Error>
    func lookupAllUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error>
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error>
    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) async

    func activeAlert() async -> LoopKit.Alert?
}

actor LocalAlertStorage: AlertStorage {
    private let recordStore: AlertRecordStore?
    private let log = DiagnosticLog(category: "AlertStorage")

    init(recordStore: AlertRecordStore?) {
        self.recordStore = recordStore
    }

    // MARK: - Writes
    //
    // These three have no error channel — LoopKit's `AlertIssuer` and
    // `PersistedAlertStore` declare them as fire-and-forget — so a failure can
    // only be logged. That is the same contract the JSON path had, which
    // swallowed its write errors by design; the difference is that it is now
    // said out loud.

    func issueAlert(_ alert: LoopKit.Alert) async {
        guard let recordStore else {
            log.error("no alert record store: dropping an issued alert")
            return
        }
        do {
            try await recordStore.issue(alert, at: Date())
        } catch {
            log.error("could not store an issued alert: %{public}@", String(describing: error))
        }
    }

    func retractAlert(identifier: LoopKit.Alert.Identifier) async {
        guard let recordStore else {
            log.error("no alert record store: dropping a retraction")
            return
        }
        do {
            try await recordStore.retract(identifier: identifier, at: Date())
        } catch {
            log.error("could not retract an alert: %{public}@", String(describing: error))
        }
    }

    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) async {
        guard let recordStore else {
            log.error("no alert record store: dropping an already-retracted alert")
            return
        }
        do {
            try await recordStore.recordRetracted(alert, at: date)
        } catch {
            log.error("could not store an already-retracted alert: %{public}@", String(describing: error))
        }
    }

    // MARK: - Reads
    //
    // These do have an error channel, so a failure is reported rather than
    // dressed up as an empty result. A caller told "no outstanding alerts" by a
    // store that is actually broken would stop re-issuing them; a caller told
    // the read failed can decide for itself. Nothing in the vendored pump and
    // CGM kits calls these today, which is what makes reporting honestly the
    // cheap option rather than a risky one.

    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async -> Result<Bool, Error> {
        guard let recordStore else {
            return .failure(AlertRecordStoreError.readFailed("no alert record store"))
        }
        do {
            return .success(try await recordStore.issuedAlertExists(identifier: identifier))
        } catch {
            log.error("could not look up an alert: %{public}@", String(describing: error))
            return .failure(error)
        }
    }

    func lookupAllUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error> {
        guard let recordStore else {
            return .failure(AlertRecordStoreError.readFailed("no alert record store"))
        }
        do {
            return .success(try await recordStore.unretracted(managerIdentifier: managerIdentifier))
        } catch {
            log.error("could not look up unretracted alerts: %{public}@", String(describing: error))
            return .failure(error)
        }
    }

    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error> {
        guard let recordStore else {
            return .failure(AlertRecordStoreError.readFailed("no alert record store"))
        }
        do {
            return .success(try await recordStore.unacknowledgedUnretracted(managerIdentifier: managerIdentifier))
        } catch {
            log.error("could not look up unacknowledged alerts: %{public}@", String(describing: error))
            return .failure(error)
        }
    }

    /// Drives `observableState.activeAlert`, which is a banner. nil is what "no
    /// banner" looks like, so a failed read degrades to nil rather than to a
    /// `Result` the caller has no way to render.
    func activeAlert() async -> LoopKit.Alert? {
        guard let recordStore else {
            log.error("no alert record store: reporting no active alert")
            return nil
        }
        do {
            return try await recordStore.mostRecentActive()
        } catch {
            log.error("could not read the active alert: %{public}@", String(describing: error))
            return nil
        }
    }
}
