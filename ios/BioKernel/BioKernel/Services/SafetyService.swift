//
//  SafetyService.swift
//  BioKernel
//
//  Created by Sam King on 1/18/24.
//

import Foundation
import LoopKit

public protocol SafetyService {
    func tempBasal(at: Date, settings: CodableSettings, reactiveSafeTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async -> SafetyTempBasal
    func record(at: Date, decision: DosingDecision, candidates: DoseCandidates, duration: TimeInterval) async
}

public struct SafetyTempBasal {
    let tempBasal: Double
    let machineLearningInsulinLastThreeHours: Double
    public init(tempBasal: Double, machineLearningInsulinLastThreeHours: Double) {
        self.tempBasal = tempBasal
        self.machineLearningInsulinLastThreeHours = machineLearningInsulinLastThreeHours
    }
}

public struct SafetyState: Codable {
    let at: Date
    let duration: TimeInterval
    let kind: Kind

    /// Mirrors `DosingDecision`: exactly one branch fires per tick. Each non-suspended
    /// case carries the programmed delivery and the physiological candidate it deviated
    /// from; that's all `deltaUnitsDeliveredByMachineLearning` needs for the budget tally.
    public enum Kind: Codable {
        case tempBasal(programmed: Double, physiological: Double)   // U/hr
        case microBolus(programmed: Double, physiological: Double)  // U
        case suspended
    }

    func deltaUnitsDeliveredByMachineLearning(from: Date, to: Date) -> Double {
        switch kind {
        case .tempBasal(let programmed, let physiological):
            guard !physiological.roughlyEqual(to: programmed) else { return 0.0 }
            let start = max(at, from)
            let end = min(at + duration, to)
            // make sure that this temp basal command ran for at least 1 second
            guard end > (start + 1) else { return 0.0 }
            let durationInSeconds = end.timeIntervalSince(start)
            return (programmed - physiological) * durationInSeconds / 1.hoursToSeconds()
        case .microBolus(let programmed, let physiological):
            guard !physiological.roughlyEqual(to: programmed) else { return 0.0 }
            guard at >= from, at < to else { return 0.0 }
            return programmed - physiological
        case .suspended:
            return 0
        }
    }
}

actor LocalSafetyService: SafetyService {
    let timeHorizon: TimeInterval = 3.hoursToSeconds()

    var safetyStates: [SafetyState]
    private let storage: StoredObject

    init(storedObjectFactory: StoredObject.Type) {
        let storage = storedObjectFactory.create(fileName: "safety_states.json")
        self.storage = storage
        self.safetyStates = (try? storage.read()) ?? []
    }
    
    // Note: we ignore actual insulin delivered and use the
    // programmed values for the safety service
    func tempBasal(at: Date, settings: CodableSettings, reactiveSafeTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async ->  SafetyTempBasal {

        let start = at - timeHorizon
        let events = safetyStates.filter { $0.at >= (start - duration) && $0.at < at }

        let nextTimes = events.dropFirst().map { $0.at } + [at]
        var historicalMlInsulin = 0.0
        for (event, nextTime) in zip(events, nextTimes) {
            historicalMlInsulin += event.deltaUnitsDeliveredByMachineLearning(from: start, to: nextTime)
        }

        // convert tempBasal rates to units of insulin, assuming it runs for the entire duration
        let mlTempBasalUnits = machineLearningTempBasalUnitsPerHour * duration / 1.hoursToSeconds()
        let reactiveSafeTempBasalUnits = reactiveSafeTempBasalUnitsPerHour * duration / 1.hoursToSeconds()

        // calculate our bounds based on the basal rate
        let safetyBounds = settings.maxBasalRate() * timeHorizon / 1.hoursToSeconds()
        let upperBoundInsulinUnits = safetyBounds
        let lowerBoundInsulinUnits = -safetyBounds

        // make sure that the upperBound doesn't go below 0
        // and that the lowerBound doesn't go above 0
        let upperBound = max(upperBoundInsulinUnits - historicalMlInsulin, 0)
        let lowerBound = min(lowerBoundInsulinUnits - historicalMlInsulin, 0)
        let deltaUnits = (mlTempBasalUnits - reactiveSafeTempBasalUnits).clamp(low: lowerBound, high: upperBound)

        // avoid divide by 0 possibility by falling back to the reactive safe model
        guard duration > 0 else {
            return SafetyTempBasal(tempBasal: reactiveSafeTempBasalUnitsPerHour, machineLearningInsulinLastThreeHours: historicalMlInsulin)
        }
        
        // now convert units back to tempBasal and add it to our safety value
        let deltaTempBasal = deltaUnits * 1.hoursToSeconds() / duration

        return SafetyTempBasal(tempBasal: reactiveSafeTempBasalUnitsPerHour + deltaTempBasal, machineLearningInsulinLastThreeHours: historicalMlInsulin)
    }
    
    func record(at: Date, decision: DosingDecision, candidates: DoseCandidates, duration: TimeInterval) async {
        let kind: SafetyState.Kind
        switch decision {
        case .tempBasal(let unitsPerHour):
            kind = .tempBasal(programmed: unitsPerHour, physiological: candidates.physiologicalTempBasal)
        case .microBolus(let units):
            kind = .microBolus(programmed: units, physiological: candidates.physiologicalMicroBolus)
        case .suspendForBiologicalInvariant:
            kind = .suspended
        }

        safetyStates.append(SafetyState(at: at, duration: duration, kind: kind))

        // Only keep 24 hours worth of data
        safetyStates = safetyStates.sorted { $0.at < $1.at }
        if let mostRecent = safetyStates.last {
            safetyStates = safetyStates.filter { $0.at >= (mostRecent.at - 24.hoursToSeconds()) }
        }

        try? storage.write(safetyStates)
    }
}
