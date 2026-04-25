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
}

protocol ClosedLoopService {
    func loop(at: Date, pumpManager: PumpManager?, cgmPumpMetadata: CgmPumpMetadata) async -> Bool
    func latestClosedLoopResult() async -> ClosedLoopResult?
    func registerClosedLoopChartDataDelegate(delegate: ClosedLoopChartDataUpdate) async -> [ClosedLoopResult]
}

actor LoopRunner: ClosedLoopService {
    var closedLoopResults: [ClosedLoopResult] = []
    var storage: StoredObject
    var lastClosedLoopRun: ClosedLoopResult? = nil
    var isRunningLoop = false
    weak var delegate: (any ClosedLoopChartDataUpdate)? = nil

    /// Derived from persisted results, so it survives app restart with zero new mutable state.
    /// Returns the timestamp of the most recent `.dosed` outcome whose decision was a micro-bolus.
    var lastMicroBolus: Date? {
        for result in closedLoopResults.reversed() {
            guard case .dosed(let snapshot) = result.outcome else { continue }
            if case .microBolus = snapshot.outputs.decision {
                return result.at
            }
        }
        return nil
    }

    private let glucoseStorage: GlucoseStorage
    private let insulinStorage: InsulinStorage
    private let safetyService: SafetyService
    private let settingsStorage: () -> SettingsStorage
    private let observableState: AppObservableState
    private let pipeline: DosingPipeline

    init(
        storedObjectFactory: StoredObject.Type,
        glucoseStorage: GlucoseStorage,
        insulinStorage: InsulinStorage,
        physiologicalModels: PhysiologicalModels,
        targetGlucoseService: TargetGlucoseService,
        machineLearning: MachineLearning,
        safetyService: SafetyService,
        settingsStorage: @escaping () -> SettingsStorage,
        observableState: AppObservableState,
        startBackgroundTask: Bool = true
    ) {
        self.storage = storedObjectFactory.create(fileName: "closed_loop_results.json")
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.safetyService = safetyService
        self.settingsStorage = settingsStorage
        self.observableState = observableState
        self.pipeline = DosingPipeline(
            physiological: physiologicalModels,
            machineLearning: machineLearning,
            safety: safetyService,
            target: targetGlucoseService
        )
        closedLoopResults = (try? storage.read()) ?? []
        if startBackgroundTask {
            Task { await updateFilteredGlucoseChartData() }
        }
    }
    
    func updateFilteredGlucoseChartData() async {
        let filteredGlucose: [FilteredGlucose] = closedLoopResults.compactMap { closedLoop in
            guard let snapshot = closedLoop.outcome.snapshot else { return nil }
            let pid = snapshot.outputs.pidTempBasalResult
            return FilteredGlucose(glucose: pid.filteredGlucose, at: pid.at)
        }
        let sorted = filteredGlucose.sorted { $0.at < $1.at }
        await MainActor.run { [observableState] in observableState.filteredGlucoseChartData = sorted }
    }
    
    func latestClosedLoopResult() async -> ClosedLoopResult? {
        return lastClosedLoopRun
    }

    func registerClosedLoopChartDataDelegate(delegate: ClosedLoopChartDataUpdate) -> [ClosedLoopResult] {
        self.delegate = delegate
        return closedLoopResults
    }
    
    func storeClosedLoopResult(_ result: ClosedLoopResult) async {
        let at = result.at
        closedLoopResults.append(result)
        closedLoopResults = closedLoopResults.filter { $0.at >= (at - 24.hoursToSeconds()) }
        do {
            try storage.write(closedLoopResults)
        } catch {
            print("Failed to write closed loop results: \(error)")
        }
        await updateFilteredGlucoseChartData()
        delegate?.update(result: result)
    }
    
    func loop(at: Date, pumpManager: PumpManager?, cgmPumpMetadata: CgmPumpMetadata) async -> Bool {
        guard !isRunningLoop else {
            return false
        }
        isRunningLoop = true

        let lastRun: ClosedLoopResult = await runLoop(at: at, pumpManager: pumpManager, cgmPumpMetadata: cgmPumpMetadata)
        await storeClosedLoopResult(lastRun)
        lastClosedLoopRun = lastRun

        isRunningLoop = false
        if case .dosed = lastRun.outcome { return true }
        return false
    }

    func runLoop(at: Date, pumpManager: PumpManager?, cgmPumpMetadata: CgmPumpMetadata) async -> ClosedLoopResult {
        let settings = await settingsStorage().snapshot()
        let freshnessInterval = settings.freshnessIntervalInSeconds

        print("Looping!")
        guard settings.closedLoopEnabled else {
            print("Open loop mode, bailing")
            return .skipped(at: at, reason: .openLoop, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        guard let glucoseReading = await glucoseStorage.lastReading(), at.timeIntervalSince(glucoseReading.date) < freshnessInterval else {
            print("Unable to get fresh glucose reading")
            return .skipped(at: at, reason: .glucoseReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        guard let lastPumpSync = await insulinStorage.lastPumpSync(), at.timeIntervalSince(lastPumpSync) < freshnessInterval else {
            print("Unable to get fresh insulin data from the pump")
            return .skipped(at: at, reason: .pumpReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        // FIXME: should we care if data is from the future???

        guard let pumpManager = pumpManager else {
            print("no pump manager")
            return .skipped(at: at, reason: .noPumpManager, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        let glucoseInMgDl = glucoseReading.quantity.doubleValue(for: .milligramsPerDeciliter)
        let insulinOnBoard = await insulinStorage.insulinOnBoard(at: at)

        let dataFrame = await AddedGlucoseDataFrame.createDataFrame(at: at, numberOfRows: 24, minNumberOfGlucoseSamples: 20, glucoseStorage: glucoseStorage, insulinStorage: insulinStorage)
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
            outputs: outputs
        )
        print("Looping, glucose: \(glucoseInMgDl) mg/dl, iob: \(insulinOnBoard), decision: \(outputs.decision)")

        let tempBasalToProgram = outputs.decision.tempBasalUnitsPerHour ?? 0

        let correctionDuration = settings.correctionDurationInSeconds
        if let pumpError = await pumpManager.enactTempBasal(unitsPerHour: tempBasalToProgram, for: correctionDuration) {
            print("Pump error: \(String(describing: pumpError))")
            return .pumpError(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot)
        }

        if case .microBolus(let rawUnits) = outputs.decision {
            let units = pumpManager.roundToSupportedBolusVolume(units: rawUnits)
            if let pumpError = await pumpManager.enactBolus(units: units, activationType: .automatic, observableState: observableState) {
                print("Pump error: \(String(describing: pumpError))")
                return .pumpError(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot)
            }
        }

        // if we got here the pump commands were sent successfully
        let safetyAnalysis = outputs.safetyAnalysis
        let biologicalInvariantViolation: Bool = if case .suspendForBiologicalInvariant = outputs.decision { true } else { false }
        await safetyService.updateAfterProgrammingPump(
            at: at,
            programmedTempBasalUnitsPerHour: outputs.decision.tempBasalUnitsPerHour ?? 0,
            safetyTempBasalUnitsPerHour: safetyAnalysis.physiologicalTempBasal,
            machineLearningTempBasalUnitsPerHour: safetyAnalysis.machineLearningTempBasal,
            duration: settings.correctionDurationInSeconds,
            programmedMicroBolus: outputs.decision.microBolusUnits ?? 0,
            safetyMicroBolus: safetyAnalysis.physiologicalMicroBolus,
            machineLearningMicroBolus: safetyAnalysis.machineLearningMicroBolus,
            biologicalInvariantViolation: biologicalInvariantViolation
        )

        // FIXME: I think I got the beeping to stop
        // podExpiring

        pumpManager.acknowledgeAlert(alertIdentifier: "userPodExpiration") { error in
            print("alert acknowledged \(String(describing: error))")
        }
        pumpManager.acknowledgeAlert(alertIdentifier: "podExpiring") { error in
            print("alert acknowledged \(String(describing: error))")
        }

        return .dosed(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot)
    }
    
}

