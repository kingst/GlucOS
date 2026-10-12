//
//  GlucoseStorage.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import HealthKit
import LoopKit

public protocol GlucoseStorage {
    func addCgmEvents(glucoseReadings: [NewGlucoseSample]) async
    func lastReading() async -> NewGlucoseSample?
    func readingsBetween(startDate: Date, endDate: Date) async -> [NewGlucoseSample]
}

public struct GlucoseChartPoint {
    let created: Date
    let readingInMgDl: Double
}

/// The app-facing glucose seam: everything that has to *happen* when a reading
/// arrives.
///
/// Storage itself lives in `GlucoseRecordStore` — this type holds no readings.
/// The split is the point: the side effects here (a low alert, a HealthKit write,
/// a watch update, the chart) are all keyed to readings the store had not already
/// seen, and a CGM re-reports the last several hours on every connection.
///
/// Nothing here reads `glucose.json` any more. The 24-hour JSON log this replaced
/// was imported into the store once, by hand, and the import path is gone rather
/// than kept as a no-op for a migration that has already happened.
actor LocalGlucoseStorage: GlucoseStorage {
    private let recordStore: GlucoseRecordStore?
    private let healthKitStorage: HealthKitStorage
    private let aiInterfaceStorage: AiInterfaceStorage?
    private let glucoseAlertsService: @MainActor () -> GlucoseAlertStorage
    private let backgroundService: @MainActor () -> BackgroundService
    private let watchComms: @MainActor () -> WatchComms
    private let observableState: AppObservableState
    private let log = DiagnosticLog(category: "GlucoseStorage")

    /// How far back the AI interface export re-offers readings on every pass.
    ///
    /// Recovery only. Everything the store accepts is offered to the exporter the
    /// moment it lands, whatever its measurement time, so this window has no job
    /// in covering a CGM backfill — it exists so that an append which failed, or
    /// a process killed between the store write and the append, is retried on the
    /// next reading instead of leaving a hole in a file nothing revisits.
    static let aiInterfaceCatchUpWindow = 6.hoursToSeconds()

    init(
        healthKitStorage: HealthKitStorage,
        recordStore: GlucoseRecordStore?,
        aiInterfaceStorage: AiInterfaceStorage? = nil,
        glucoseAlertsService: @MainActor @escaping () -> GlucoseAlertStorage,
        backgroundService: @MainActor @escaping () -> BackgroundService,
        watchComms: @MainActor @escaping () -> WatchComms,
        observableState: AppObservableState,
        startBackgroundTask: Bool = true
    ) {
        self.healthKitStorage = healthKitStorage
        self.recordStore = recordStore
        self.aiInterfaceStorage = aiInterfaceStorage
        self.glucoseAlertsService = glucoseAlertsService
        self.backgroundService = backgroundService
        self.watchComms = watchComms
        self.observableState = observableState
        if startBackgroundTask {
            Task {
                await updateGlucoseChartData()
            }
        }
    }

    func lastReading() async -> NewGlucoseSample? {
        guard let recordStore else {
            log.error("no glucose record store: reporting no reading")
            return nil
        }
        do {
            return try await recordStore.lastReading()
        } catch {
            // nil is the safe direction: `LoopRunner` refuses to dose without a
            // fresh reading, so a failed read stops the loop rather than dosing
            // off stale glucose.
            log.error("could not read the last glucose reading: %{public}@", String(describing: error))
            return nil
        }
    }

    func readingsBetween(startDate: Date, endDate: Date) async -> [NewGlucoseSample] {
        guard let recordStore else {
            log.error("no glucose record store: reporting no readings")
            return []
        }
        do {
            return try await recordStore.readingsBetween(startDate: startDate, endDate: endDate)
        } catch {
            log.error("could not read glucose readings: %{public}@", String(describing: error))
            return []
        }
    }

    func addCgmEvents(glucoseReadings: [NewGlucoseSample]) async {
        guard let recordStore else {
            log.error("no glucose record store: dropping %d CGM reading(s)", glucoseReadings.count)
            return
        }

        // One instant for the whole call, so the store and the AI interface export
        // can't disagree about when this batch arrived.
        let at = Date()

        let result: GlucoseIngestResult
        do {
            result = try await recordStore.ingest(glucoseReadings, at: at)
        } catch {
            log.error("could not store %d CGM reading(s): %{public}@", glucoseReadings.count, String(describing: error))
            return
        }
        if result.prunedByRetention > 0 {
            log.default("glucose retention pruned %d reading(s)", result.prunedByRetention)
        }

        // Nothing new means nothing to react to: this is the CGM re-reporting
        // history it has already given us.
        guard !result.inserted.isEmpty else { return }

        // Ahead of the alert and HealthKit work below rather than after it: this
        // is detached, so it starts here and runs alongside them.
        publishToAiInterface(inserted: result.inserted, at: at)

        // The store is written before any of this runs, so the alert path — which
        // reads back through `lastReading()` — sees the reading it is alerting on.
        if let mostRecent = result.inserted.max(by: { $0.date < $1.date }) {
            let timeSinceLastReading = Date().timeIntervalSince(mostRecent.date)
            print("app refresh time: \(timeSinceLastReading)")
            if timeSinceLastReading < 5.minutesToSeconds() {
                let alerts = await MainActor.run { glucoseAlertsService() }
                await alerts.onNewGlucoseValue()
                print("resetting app refresh from CGM reading")
                // we have recent data so we can reset our background task
                await MainActor.run { backgroundService().scheduleAppRefresh() }
            }
        }

        let comms = await MainActor.run { watchComms() }
        await comms.updateAppContext()
        await updateGlucoseChartData()

        Task { [healthKitStorage] in
            await healthKitStorage.save(glucoseSamples: result.inserted)
        }
    }

    /// Hands new readings to the AI interface exporter, plus a recent window from
    /// the store on top of them.
    ///
    /// The two serve different purposes and neither replaces the other:
    /// `inserted` is the guarantee that every reading is offered once, whatever
    /// its measurement time, so a CGM backfilling further back than the window
    /// still gets published in full; the window is the retry for an append that
    /// failed or never happened. The exporter's ledger collapses the overlap.
    ///
    /// Detached, and never awaited, for the same reason the insulin export is:
    /// publishing for an AI app must not delay a low alert.
    private func publishToAiInterface(inserted: [NewGlucoseSample], at: Date) {
        guard let aiInterfaceStorage, let recordStore else { return }
        Task {
            var readings = inserted
            do {
                readings += try await recordStore.readingsBetween(
                    startDate: at - Self.aiInterfaceCatchUpWindow,
                    endDate: at
                )
            } catch {
                // The new readings still go out; only the retry is lost, and the
                // next reading tries again.
                log.error("could not read the glucose catch-up window: %{public}@", String(describing: error))
            }
            await aiInterfaceStorage.exportGlucose(readings: readings, at: at)
        }
    }

    /// Republishes the chart's 24-hour window.
    ///
    /// Bounded by `chartWindow` rather than by everything held, which the JSON
    /// path could get away with when everything held *was* a day.
    private func updateGlucoseChartData() async {
        guard let recordStore else { return }
        let now = Date()
        do {
            // Already ordered oldest-first by the store, which is the order the
            // chart draws in.
            let readings = try await recordStore.readingsBetween(
                startDate: now - GlucoseRecordStorePolicy.chartWindow,
                endDate: now
            )
            let chartData = readings.map { reading in
                let glucoseInMgDl = reading.quantity.doubleValue(for: .milligramsPerDeciliter, withRounding: true)
                return GlucoseChartPoint(created: reading.date, readingInMgDl: glucoseInMgDl)
            }
            await MainActor.run { [observableState] in observableState.glucoseChartData = chartData }
        } catch {
            log.error("could not read glucose readings for the chart: %{public}@", String(describing: error))
        }
    }
}
