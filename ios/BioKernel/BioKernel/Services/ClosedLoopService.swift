//
//  ClosedLoopService.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//
// We try to copy the logic from Loop, which means:
//    - if we get a pump heartbeat, get the latest CGM readings and run at most every 4.2 minutes
//    - if we get a CGM event, get the latest pump readings and run (it'll only happen every 5 minutes)
//    - if the UI requests a refresh, refresh the CGM data, loop if at least 4.2 minutes since the last run, then get pump data

import Foundation
import LoopKit

public struct FilteredGlucose {
    public let glucose: Double
    public let at: Date
    /// The target this tick dosed toward, and why, so the main glucose chart can
    /// draw the target as a step line off the same read that feeds the
    /// filtered-glucose line (dev/backlog/meal-soon.md §7.4). Both nil on rows
    /// written before schema v2.
    public let targetMgDl: Double?
    public let targetSource: TargetGlucoseSource?

    public init(glucose: Double, at: Date, targetMgDl: Double? = nil, targetSource: TargetGlucoseSource? = nil) {
        self.glucose = glucose
        self.at = at
        self.targetMgDl = targetMgDl
        self.targetSource = targetSource
    }
}

protocol ClosedLoopService {
    func loop(at: Date, pumpManager: PumpManager?, cgmPumpMetadata: CgmPumpMetadata) async -> Bool
    func latestLoopRecord() async -> LoopRecord?
    func registerClosedLoopChartDataDelegate(delegate: ClosedLoopChartDataUpdate) async -> [LoopRecord]
}

/// Everything one pass of `runLoop` produced, before any of it is durable.
///
/// `runLoop` used to write the safety ledger itself, partway through, and return
/// only the result — so the two records describing one tick landed in two files
/// at two different times with no transaction between them. It now enacts pump
/// commands and returns; `loop` decides what becomes durable and in what order.
struct LoopRun {
    let result: ClosedLoopResult
    /// The ledger entry this tick earned, or nil when it never programmed a dose
    /// — `.skipped` and `.pumpError` both return before the pump was set.
    let safetyState: SafetyState?
    /// The CGM reading this run consumed. Carried out so the AI interface marker
    /// can be published *after* the transaction commits rather than mid-loop.
    let cgmReadingAt: Date?

    init(result: ClosedLoopResult, safetyState: SafetyState? = nil, cgmReadingAt: Date? = nil) {
        self.result = result
        self.safetyState = safetyState
        self.cgmReadingAt = cgmReadingAt
    }
}

actor LoopRunner: ClosedLoopService {
    var lastClosedLoopRun: LoopRecord? = nil
    var isRunningLoop = false
    weak var delegate: (any ClosedLoopChartDataUpdate)? = nil

    private let glucoseStorage: GlucoseStorage
    private let insulinStorage: InsulinStorage
    private let safetyService: SafetyService
    private let settingsStorage: () -> SettingsStorage
    private let observableState: AppObservableState
    private let doseProgress: DoseProgress
    private let pipeline: DosingPipeline
    private let log = DiagnosticLog(category: "ClosedLoopService")
    /// nil when the store could not be opened. The loop still runs — it has to,
    /// it is the thing that keeps insulin flowing — but nothing it does is
    /// recorded, the throttle opens, and the safety service refuses the ML
    /// budget. See LoopRecordStore §7.
    private let recordStore: LoopRecordStore?
    /// Only ever told that a loop finished issuing pump commands, so an AI app
    /// polling the shared container knows the file it is reading describes this
    /// CGM reading rather than the one before it. Nothing here reads back from it
    /// and nothing it does can change a dose.
    private let aiInterfaceStorage: AiInterfaceStorage?
    /// Copies AI meal announcements out of the shared container and into the
    /// 90-day store, once per tick, before anything else happens.
    ///
    /// The loop is the only clock in the app that runs whether or not anyone is
    /// looking, which is what this needs: the announcement files retain two
    /// days, so an announcement is only ever a couple of days from being lost,
    /// and waiting for a view to open is not a schedule. Nothing it copies
    /// reaches dosing — see `loop`.
    private let mealStorage: MealStorage?

    init(
        glucoseStorage: GlucoseStorage,
        insulinStorage: InsulinStorage,
        physiologicalModels: PhysiologicalModels,
        targetGlucoseService: TargetGlucoseService,
        machineLearning: MachineLearning,
        safetyService: SafetyService,
        settingsStorage: @escaping () -> SettingsStorage,
        observableState: AppObservableState,
        doseProgress: DoseProgress,
        recordStore: LoopRecordStore?,
        aiInterfaceStorage: AiInterfaceStorage? = nil,
        mealStorage: MealStorage? = nil,
        startBackgroundTask: Bool = true
    ) {
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.safetyService = safetyService
        self.settingsStorage = settingsStorage
        self.observableState = observableState
        self.doseProgress = doseProgress
        self.recordStore = recordStore
        self.aiInterfaceStorage = aiInterfaceStorage
        self.mealStorage = mealStorage
        self.pipeline = DosingPipeline(
            physiological: physiologicalModels,
            machineLearning: machineLearning,
            safety: safetyService,
            target: targetGlucoseService
        )

        // **This initializer performs no I/O, and that is the point.**
        //
        // It used to read `closed_loop_results.json` synchronously — `(try?
        // storage.read()) ?? []` — from an `@MainActor` composition root that
        // constructs this eagerly. So every launch paid a full decode of up to a
        // day of loop results before any device manager existed, including the
        // before-first-unlock Bluetooth wakes the CGM generates. On 2026-08-15 at
        // 22:44 that decode used the whole 30-second process-launch allowance and
        // the watchdog killed the app.
        //
        // Chart population moved into the task below, off the launch path.
        if startBackgroundTask {
            Task { await updateFilteredGlucoseChartData(at: Date()) }
        }
    }

    /// The PID's filtered-glucose series for the chart, over the stated window.
    ///
    /// Re-projected on every loop, same as before. At ~288 rows that is not worth
    /// turning into an incremental append.
    func updateFilteredGlucoseChartData(at: Date) async {
        guard let recordStore else { return }
        do {
            let sorted = try await recordStore.filteredGlucose(since: at - LoopRecordStorePolicy.chartWindow)
            await MainActor.run { [observableState] in observableState.filteredGlucoseChartData = sorted }
        } catch {
            log.error("could not read filtered glucose: %{public}@", String(describing: error))
        }
    }

    /// The newest tick, for the digestion gauge.
    ///
    /// Falls back to the store when nothing has run in this process yet. Without
    /// that fallback the gauge was blank after every relaunch even though the
    /// data was on disk — `lastClosedLoopRun` only ever held what *this* process
    /// had looped. `digestionCalibrated()` still refuses anything older than 16
    /// minutes, so hydrating cannot produce a stale reading, only a fresh one
    /// that would otherwise have been thrown away.
    func latestLoopRecord() async -> LoopRecord? {
        if let lastClosedLoopRun { return lastClosedLoopRun }
        guard let recordStore else { return nil }
        do {
            let record = try await recordStore.latestRecord()
            lastClosedLoopRun = record
            return record
        } catch {
            log.error("could not read the latest loop record: %{public}@", String(describing: error))
            return nil
        }
    }

    func registerClosedLoopChartDataDelegate(delegate: ClosedLoopChartDataUpdate) async -> [LoopRecord] {
        self.delegate = delegate
        guard let recordStore else { return [] }
        do {
            return try await recordStore.records(since: Date() - LoopRecordStorePolicy.chartWindow)
        } catch {
            // A blank chart is honest. Nothing downstream doses off this.
            log.error("could not read loop records for the chart: %{public}@", String(describing: error))
            return []
        }
    }

    /// The instant of the most recent `.dosed` tick whose decision was a
    /// micro-bolus, or nil when there is none.
    ///
    /// Was a reverse scan over the in-memory array; is now one indexed query, and
    /// survives an app restart for the same reason it did before — it is derived
    /// from what was recorded rather than from new mutable state.
    ///
    /// A failed read returns nil, which opens the throttle. That is the honest
    /// direction for this particular read: the window is 252 s against ~300 s
    /// loop spacing, so it only binds when a pump heartbeat and a CGM reading
    /// land within 4.2 minutes of each other, and losing it lets one extra
    /// micro-bolus through rather than changing any dose amount.
    private func lastMicroBolus() async -> Date? {
        guard let recordStore else { return nil }
        do {
            return try await recordStore.lastMicroBolus()
        } catch {
            log.error("could not read the last micro bolus, opening the throttle: %{public}@", String(describing: error))
            return nil
        }
    }

    func loop(at: Date, pumpManager: PumpManager?, cgmPumpMetadata: CgmPumpMetadata) async -> Bool {
        guard !isRunningLoop else {
            return false
        }
        isRunningLoop = true

        // 0. Copy any new AI meal announcements into the meal store.
        //
        //    First, and outside everything below, because it is the only thing
        //    in this method with a deadline: the interface files retain two
        //    days, so an announcement not copied out within them is gone. Every
        //    other step here is about this tick.
        //
        //    It cannot fail the loop and it cannot change a dose. Meals are not
        //    an input to insulin delivery — the pipeline below never reads them
        //    — so an ingest that throws is logged inside `MealStorage.ingest`
        //    and we go on to dose exactly as we would have.
        await mealStorage?.ingest(at: at)

        // 1. Enact pump commands and build what this tick produced.
        let run = await runLoop(at: at, pumpManager: pumpManager, cgmPumpMetadata: cgmPumpMetadata)
        let record = LoopRecord(run.result)

        // 2. One transaction. The loop result and the ledger entry land together
        //    or neither does.
        //
        //    Note what this does *not* fix: the pump commands were already
        //    enacted inside `runLoop`, so a crash between there and here still
        //    leaves a delivered dose the ledger has not counted — an
        //    over-generous ML budget for the next three hours. Closing that would
        //    mean reserving budget before dosing and reconciling after, which
        //    counts insulin that may never be delivered. Out of scope; noted so
        //    it is not mistaken for something this change fixed.
        let recorded = await store(record, safetyState: run.safetyState, at: at)

        // 3. Only now the AI interface marker. It says "GlucOS is done with this
        //    reading", so it can only be written once that is true in every sense
        //    a reader should act on: the commands were sent *and* what we did with
        //    them is durable. Previously it ran between the two writes; the
        //    invariant its comment claimed is now actually enforced.
        //
        //    A failed or absent store therefore publishes nothing. That is
        //    deliberate — a dose the ledger has not accounted for is exactly when
        //    advertising completion is worst.
        if recorded, case .dosed = record.outcome, let cgmReadingAt = run.cgmReadingAt {
            await aiInterfaceStorage?.recordCgmTickHandled(cgmReadingAt: cgmReadingAt, at: at)
        }

        // 4. UI state, which reflects what happened whether or not it was stored.
        lastClosedLoopRun = record
        await updateFilteredGlucoseChartData(at: at)
        delegate?.update(record: record)

        isRunningLoop = false
        if case .dosed = record.outcome { return true }
        return false
    }

    /// - Returns: whether both records are durable.
    private func store(_ record: LoopRecord, safetyState: SafetyState?, at: Date) async -> Bool {
        guard let recordStore else {
            log.error("no loop record store; this tick goes unrecorded")
            return false
        }
        do {
            try await recordStore.record(record, safetyState: safetyState, at: at)
            return true
        } catch {
            // The dose already happened and cannot be un-enacted. All we can do
            // is say so loudly.
            log.error("could not record a loop tick: %{public}@", String(describing: error))
            return false
        }
    }

    func runLoop(at: Date, pumpManager: PumpManager?, cgmPumpMetadata: CgmPumpMetadata) async -> LoopRun {
        let settings = await settingsStorage().snapshot()
        let freshnessInterval = settings.freshnessIntervalInSeconds

        print("Looping!")
        guard settings.closedLoopEnabled else {
            print("Open loop mode, bailing")
            return LoopRun(result: .skipped(at: at, reason: .openLoop, settings: settings, cgmPumpMetadata: cgmPumpMetadata))
        }

        guard let glucoseReading = await glucoseStorage.lastReading(), at.timeIntervalSince(glucoseReading.date) < freshnessInterval else {
            print("Unable to get fresh glucose reading")
            return LoopRun(result: .skipped(at: at, reason: .glucoseReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata))
        }

        guard let lastPumpSync = await insulinStorage.lastPumpSync(), at.timeIntervalSince(lastPumpSync) < freshnessInterval else {
            print("Unable to get fresh insulin data from the pump")
            return LoopRun(result: .skipped(at: at, reason: .pumpReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata))
        }

        // FIXME: should we care if data is from the future???

        guard let pumpManager = pumpManager else {
            print("no pump manager")
            return LoopRun(result: .skipped(at: at, reason: .noPumpManager, settings: settings, cgmPumpMetadata: cgmPumpMetadata))
        }

        let glucoseInMgDl = glucoseReading.quantity.doubleValue(for: .milligramsPerDeciliter)
        let insulinOnBoard = await insulinStorage.insulinOnBoard(at: at)

        let dataFrame = await AddedGlucoseDataFrame.createDataFrame(at: at, numberOfRows: 24, minNumberOfGlucoseSamples: 20, glucoseStorage: glucoseStorage, insulinStorage: insulinStorage)
        let lastMicroBolus = await lastMicroBolus()
        let inputs = LoopInputs(
            at: at,
            settings: settings,
            glucoseInMgDl: glucoseInMgDl,
            insulinOnBoard: insulinOnBoard,
            dataFrame: dataFrame,
            lastMicroBolus: lastMicroBolus,
            roundToSupportedBasalRate: { pumpManager.roundToSupportedBasalRate(unitsPerHour: $0) },
            roundToSupportedBolusVolume: { pumpManager.roundToSupportedBolusVolume(units: $0) }
        )
        let outputs = await pipeline.run(inputs)
        let snapshot = LoopSnapshot(
            inputs: LoopSnapshotInputs(glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard),
            outputs: outputs,
            replay: LoopReplayInputs(dataFrame: dataFrame, lastMicroBolus: lastMicroBolus)
        )
        print("Looping, glucose: \(glucoseInMgDl) mg/dl, iob: \(insulinOnBoard), decision: \(outputs.decision)")

        let tempBasalToProgram = outputs.decision.tempBasalUnitsPerHour ?? 0

        let correctionDuration = settings.correctionDurationInSeconds
        if let pumpError = await pumpManager.enactTempBasal(unitsPerHour: tempBasalToProgram, for: correctionDuration) {
            print("Pump error: \(String(describing: pumpError))")
            return LoopRun(result: .pumpError(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot))
        }

        if case .microBolus(let rawUnits) = outputs.decision {
            let units = pumpManager.roundToSupportedBolusVolume(units: rawUnits)
            if let pumpError = await pumpManager.enactBolus(units: units, activationType: .automatic, doseProgress: doseProgress) {
                print("Pump error: \(String(describing: pumpError))")
                return LoopRun(result: .pumpError(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot))
            }
        }

        // if we got here the pump commands were sent successfully

        // FIXME: I think I got the beeping to stop
        // podExpiring

        pumpManager.acknowledgeAlert(alertIdentifier: "userPodExpiration") { error in
            print("alert acknowledged \(String(describing: error))")
        }
        pumpManager.acknowledgeAlert(alertIdentifier: "podExpiring") { error in
            print("alert acknowledged \(String(describing: error))")
        }

        // Built here, written by the caller. This is the ledger entry the safety
        // service used to append to `safety_states.json` from inside this method.
        let safetyState = SafetyState(
            at: at,
            decision: outputs.decision,
            candidates: outputs.candidates,
            duration: settings.correctionDurationInSeconds
        )

        return LoopRun(
            result: .dosed(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot),
            safetyState: safetyState,
            cgmReadingAt: glucoseReading.date
        )
    }

}
