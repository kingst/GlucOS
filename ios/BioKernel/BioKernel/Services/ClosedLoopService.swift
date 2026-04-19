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
    func loop(at: Date) async -> Bool
    func latestClosedLoopResult() async -> ClosedLoopResult?
    func registerClosedLoopChartDataDelegate(delegate: ClosedLoopChartDataUpdate) async -> [ClosedLoopResult]
}

actor LocalClosedLoopService: ClosedLoopService {
    static let shared = LocalClosedLoopService()

    // Suspend insulin delivery when biological-invariant error drops below this.
    let biologicalInvariantThresholdMgDlPerHour: Double = -35

    // Below this the bolus rounds to zero on supported pumps (Omnipod delivers in 0.05U increments).
    let minimumMicroBolusUnits: Double = 0.025

    // 4.2 minutes — copied from the Loop project's micro-bolus cadence.
    let microBolusThrottleInSeconds: TimeInterval = 252

    // Only consider a micro-bolus when glucose is at least this far above target.
    let microBolusGlucoseMarginMgDl: Double = 20

    var closedLoopResults: [ClosedLoopResult] = []
    var storage = getStoredObject().create(fileName: "closed_loop_results.json")
    var lastClosedLoopRun: ClosedLoopResult? = nil
    var lastMicroBolus: Date? = nil
    var isRunningLoop = false
    weak var delegate: (any ClosedLoopChartDataUpdate)? = nil
    
    init(startBackgroundTask: Bool = true) {
        closedLoopResults = (try? storage.read()) ?? []
        if startBackgroundTask {
            Task { await updateFilteredGlucoseChartData() }
        }
    }
    
    func updateFilteredGlucoseChartData() async {
        let filteredGlucose: [FilteredGlucose] = closedLoopResults.compactMap { closedLoop in
            guard let snapshot = closedLoop.outcome.snapshot else { return nil }
            let pid = snapshot.pidTempBasalResult
            return FilteredGlucose(glucose: pid.filteredGlucose, at: pid.at)
        }
        await getDeviceDataManager().update(filteredGlucoseChartData: filteredGlucose.sorted{ $0.at < $1.at })
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
    
    func loop(at: Date) async -> Bool {
        guard !isRunningLoop else {
            return false
        }
        isRunningLoop = true
        
        let lastRun: ClosedLoopResult = await runLoop(at: at)
        await storeClosedLoopResult(lastRun)
        lastClosedLoopRun = lastRun
        
        isRunningLoop = false
        if case .dosed = lastRun.outcome { return true }
        return false
    }
    
    func microBolusAmount(tempBasal: Double, settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, at: Date) async -> Double? {
        guard lastMicroBolus.map({ at.timeIntervalSince($0) > microBolusThrottleInSeconds }) ?? true else { return nil }

        let glucoseThreshold = targetGlucoseInMgDl + microBolusGlucoseMarginMgDl
        guard glucoseInMgDl >= glucoseThreshold else { return nil }
        
        // convert the temp basal to the amount of insulin the closed loop algorithm
        // decided to deliver, subtracting off the basal rate so that we're
        // only delivering the correction
        // Calculate the insulin amount based on temp basal and basal rate
        let correctionDurationHours = settings.correctionDurationInSeconds / 60.minutesToSeconds()
        
        // Note: We hard code the duration in settings so this can't trigger
        guard correctionDurationHours > 0 else {
            return nil
        }

        // convert the temp basal to the amount of insulin the closed loop algorithm
        // decided to deliver over the correctionDurationHours period
        // Note: The micro bolus includes any insulin for basal glucose
        let insulin = tempBasal * correctionDurationHours
        guard insulin > 0 else { return nil } // Ensure insulin amount is positive
    
        // Calculate the micro-bolus amount and clamp within valid bounds
        let maxBolus = settings.maxBasalRateUnitsPerHour * correctionDurationHours
        
        // Deliver part for now so that if nothing changes we deliver the full amount over 15-30 minutes
        let amount = (settings.getMicroBolusDoseFactor() * insulin).clamp(low: 0, high: min(insulin, maxBolus))
    
        // Round to the nearest supported bolus volume
        return await getDeviceDataManager().pumpManager?.roundToSupportedBolusVolume(units: amount) ?? amount
    }
    
    func runLoop(at: Date) async -> ClosedLoopResult {
        let settings = await getSettingsStorage().snapshot()
        let freshnessInterval = settings.freshnessIntervalInSeconds
        let cgmPumpMetadata = await getDeviceDataManager().cgmPumpMetadata()

        print("Looping!")
        guard settings.closedLoopEnabled else {
            print("Open loop mode, bailing")
            return .skipped(at: at, reason: .openLoop, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        guard let glucoseReading = await getGlucoseStorage().lastReading(), at.timeIntervalSince(glucoseReading.date) < freshnessInterval else {
            print("Unable to get fresh glucose reading")
            return .skipped(at: at, reason: .glucoseReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        guard let lastPumpSync = await getInsulinStorage().lastPumpSync(), at.timeIntervalSince(lastPumpSync) < freshnessInterval else {
            print("Unable to get fresh insulin data from the pump")
            return .skipped(at: at, reason: .pumpReadingStale, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        // FIXME: should we care if data is from the future???

        guard let pumpManager = await getDeviceDataManager().pumpManager else {
            print("no pump manager")
            return .skipped(at: at, reason: .noPumpManager, settings: settings, cgmPumpMetadata: cgmPumpMetadata)
        }

        let glucoseInMgDl = glucoseReading.quantity.doubleValue(for: .milligramsPerDeciliter)
        let insulinOnBoard = await getInsulinStorage().insulinOnBoard(at: at)

        let round = { (tempBasal: Double) -> Double in
            pumpManager.roundToSupportedBasalRate(unitsPerHour: tempBasal)
        }

        let snapshot = await closedLoopAlgorithm(settings: settings, glucoseInMgDl: glucoseInMgDl, insulinOnBoard: insulinOnBoard, at: at, roundToSupportedBasalRate: round)
        print("Looping, glucose: \(glucoseInMgDl) mg/dl, iob: \(insulinOnBoard), decision: \(snapshot.decision)")

        let tempBasalToProgram = snapshot.decision.tempBasalUnitsPerHour ?? 0

        let correctionDuration = settings.correctionDurationInSeconds
        if let pumpError = await pumpManager.enactTempBasal(unitsPerHour: tempBasalToProgram, for: correctionDuration) {
            print("Pump error: \(String(describing: pumpError))")
            return .pumpError(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot)
        }

        if case .microBolus(let rawUnits) = snapshot.decision {
            let units = pumpManager.roundToSupportedBolusVolume(units: rawUnits)
            if let pumpError = await pumpManager.enactBolus(units: units, activationType: .automatic) {
                print("Pump error: \(String(describing: pumpError))")
                return .pumpError(at: at, settings: settings, cgmPumpMetadata: cgmPumpMetadata, snapshot: snapshot)
            }
            lastMicroBolus = Date()
        }

        // if we got here the pump commands were sent successfully
        let safetyResult = snapshot.safetyResult
        await getSafetyService().updateAfterProgrammingPump(
            at: at,
            programmedTempBasalUnitsPerHour: safetyResult.actualTempBasal,
            safetyTempBasalUnitsPerHour: safetyResult.physiologicalTempBasal,
            machineLearningTempBasalUnitsPerHour: safetyResult.machineLearningTempBasal,
            duration: settings.correctionDurationInSeconds,
            programmedMicroBolus: safetyResult.actualMicroBolus,
            safetyMicroBolus: safetyResult.physiologicalMicroBolus,
            machineLearningMicroBolus: safetyResult.machineLearningMicroBolus,
            biologicalInvariantViolation: safetyResult.biologicalInvariantViolation
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
    
    /// Pre conditions:
    ///  - targetGlucose >= 75
    ///  - insulinSensitivity > 0
    ///  - maxBasalRate > 0
    /// Post conditions:
    ///  - return is between 0 and maxBasalRate
    ///  Invariants:
    ///  - no numerical underflow or overflow
    func closedLoopAlgorithm(settings: CodableSettings, glucoseInMgDl: Double, insulinOnBoard: Double, at: Date, roundToSupportedBasalRate: (Double) -> Double) async -> LoopSnapshot {

        // create a dataframe to pass to all of the callers
        let dataFrame = await AddedGlucoseDataFrame.createDataFrame(at: at, numberOfRows: 24, minNumberOfGlucoseSamples: 20)
        let basalRate = settings.learnedBasalRate(at: at)
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: at)
        let predictedGlucoseInMgDl = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: at) ?? glucoseInMgDl
        let targetGlucoseInMgDl = await getTargetGlucoseService().targetGlucoseInMgDl(at: at, settings: settings)

        let proportionalControllerStart = Date()
        let pidTempBasal = await getPhysiologicalModels().tempBasal(settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, insulinOnBoard: insulinOnBoard, dataFrame: dataFrame, at: at)

        let physiologicalTempBasal = applyGuardrails(glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: predictedGlucoseInMgDl, newBasalRateRaw: pidTempBasal.tempBasal, settings: settings, roundToSupportedBasalRate: roundToSupportedBasalRate)
        let proportionalControllerDuration = Date().timeIntervalSince(proportionalControllerStart)

        // calculate the ML-based tempBasal
        let mlStart = Date()
        let mlTempBasalRaw = await getMachineLearning().tempBasal(settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, insulinOnBoard: insulinOnBoard, dataFrame: dataFrame, at: at, pidTempBasal: pidTempBasal) ?? physiologicalTempBasal
        let mlTempBasal = applyGuardrails(glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: predictedGlucoseInMgDl, newBasalRateRaw: mlTempBasalRaw, settings: settings, roundToSupportedBasalRate: roundToSupportedBasalRate)
        let mlDuration = Date().timeIntervalSince(mlStart)

        // run it through the safety service
        let safetyStart = Date()
        let safetyTempBasalResult = await getSafetyService().tempBasal(at: at, settings: settings, safetyTempBasalUnitsPerHour: physiologicalTempBasal, machineLearningTempBasalUnitsPerHour: mlTempBasal, duration: settings.correctionDurationInSeconds)
        let safetyTempBasal = applyGuardrails(glucoseInMgDl: glucoseInMgDl, predictedGlucoseInMgDl: predictedGlucoseInMgDl, newBasalRateRaw: safetyTempBasalResult.tempBasal, settings: settings, roundToSupportedBasalRate: roundToSupportedBasalRate)
        let safetyDuration = Date().timeIntervalSince(safetyStart)

        // calculate the micro bolus candidates and the biological invariant
        // IMPORTANT: you must run the mlTempBasal through the safety logic and use only
        // that temp basal for micro bolus calculations, or you can use the physiological temp basal
        let microBolusSafety = await microBolusAmount(tempBasal: safetyTempBasal, settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, at: at) ?? 0.0
        let microBolusPhysiological = await microBolusAmount(tempBasal: physiologicalTempBasal, settings: settings, glucoseInMgDl: glucoseInMgDl, targetGlucoseInMgDl: targetGlucoseInMgDl, at: at) ?? 0.0
        let biologicalInvariant = await getPhysiologicalModels().deltaGlucoseError(settings: settings, dataFrame: dataFrame, at: at)

        let decision = determineDose(settings: settings, physiologicalTempBasal: physiologicalTempBasal, mlTempBasal: mlTempBasal, safetyTempBasal: safetyTempBasal, microBolusPhysiological: microBolusPhysiological, microBolusSafety: microBolusSafety, biologicalInvariant: biologicalInvariant)

        let machineLearningInsulinLastThreeHours = safetyTempBasalResult.machineLearningInsulinLastThreeHours
        let safetyResult: SafetyResult
        switch decision {
        case .tempBasal(let unitsPerHour):
            safetyResult = SafetyResult(
                machineLearningTempBasal: mlTempBasal,
                physiologicalTempBasal: physiologicalTempBasal,
                actualTempBasal: unitsPerHour,
                machineLearningMicroBolus: 0.0,
                physiologicalMicroBolus: 0.0,
                actualMicroBolus: 0.0,
                machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours,
                biologicalInvariantMgDlPerHour: biologicalInvariant,
                biologicalInvariantViolation: false
            )
        case .microBolus(let units):
            safetyResult = SafetyResult(
                machineLearningTempBasal: 0.0,
                physiologicalTempBasal: 0.0,
                actualTempBasal: 0.0,
                machineLearningMicroBolus: microBolusSafety,
                physiologicalMicroBolus: microBolusPhysiological,
                actualMicroBolus: units,
                machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours,
                biologicalInvariantMgDlPerHour: biologicalInvariant,
                biologicalInvariantViolation: false
            )
        case .suspendForBiologicalInvariant(let mgDlPerHour):
            safetyResult = SafetyResult(
                machineLearningTempBasal: 0.0,
                physiologicalTempBasal: 0.0,
                actualTempBasal: 0.0,
                machineLearningMicroBolus: 0.0,
                physiologicalMicroBolus: 0.0,
                actualMicroBolus: 0.0,
                machineLearningInsulinLastThreeHours: machineLearningInsulinLastThreeHours,
                biologicalInvariantMgDlPerHour: mgDlPerHour,
                biologicalInvariantViolation: true
            )
        }

        // just for logging for now
        let addedGlucose = dataFrame?.addedGlucosePerHour30m(insulinSensitivity: insulinSensitivity) ?? 0

        return LoopSnapshot(
            glucoseInMgDl: glucoseInMgDl,
            predictedGlucoseInMgDl: predictedGlucoseInMgDl,
            insulinOnBoard: insulinOnBoard,
            targetGlucoseInMgDl: targetGlucoseInMgDl,
            insulinSensitivity: insulinSensitivity,
            basalRate: basalRate,
            decision: decision,
            safetyResult: safetyResult,
            pidTempBasalResult: pidTempBasal,
            mlDurationInSeconds: mlDuration,
            safetyDurationInSeconds: safetyDuration,
            proportionalControllerDurationInSeconds: proportionalControllerDuration,
            predictedAddedGlucoseInMgDlPerHour: addedGlucose
        )
    }

    /// post condition: exactly one dosing branch is selected per tick
    func determineDose(settings: CodableSettings, physiologicalTempBasal: Double, mlTempBasal: Double, safetyTempBasal: Double, microBolusPhysiological: Double, microBolusSafety: Double, biologicalInvariant: Double?) -> DosingDecision {
        let tempBasalCandidate: Double
        let microBolusCandidate: Double

        if settings.useMachineLearningClosedLoop {
            tempBasalCandidate = safetyTempBasal
            microBolusCandidate = microBolusSafety
        } else {
            tempBasalCandidate = physiologicalTempBasal
            microBolusCandidate = microBolusPhysiological
        }

        if settings.isBiologicalInvariantEnabled(), let biologicalInvariant = biologicalInvariant, biologicalInvariant < biologicalInvariantThresholdMgDlPerHour {
            return .suspendForBiologicalInvariant(mgDlPerHour: biologicalInvariant)
        }

        if settings.isMicroBolusEnabled(), microBolusCandidate > minimumMicroBolusUnits {
            return .microBolus(units: microBolusCandidate)
        }

        return .tempBasal(unitsPerHour: tempBasalCandidate)
    }
    
    func applyGuardrails(glucoseInMgDl: Double, predictedGlucoseInMgDl: Double, newBasalRateRaw: Double, settings: CodableSettings, roundToSupportedBasalRate: (Double) -> Double) -> Double {
        // now get it ready to send to the pump
        var newBasalRate = roundToSupportedBasalRate(newBasalRateRaw)
        
        if newBasalRate > settings.maxBasalRateUnitsPerHour {
            newBasalRate = settings.maxBasalRateUnitsPerHour
        }
        
        if newBasalRate < 0.0 {
            newBasalRate = 0.0
        }
        
        let shutOffGlucose = settings.shutOffGlucoseInMgDl
        if glucoseInMgDl <= shutOffGlucose || predictedGlucoseInMgDl <= shutOffGlucose {
            newBasalRate = 0.0
        }
        
        return newBasalRate
    }
}

extension LocalClosedLoopService {
    #if DEBUG
    func setLastMicroBolusForTesting(date: Date?) async {
        self.lastMicroBolus = date
    }
    #endif
}
