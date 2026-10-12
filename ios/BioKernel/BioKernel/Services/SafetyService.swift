//
//  SafetyService.swift
//  BioKernel
//
//  Created by Sam King on 1/18/24.
//

import Foundation
import LoopKit

/// Read-only. Writing the ledger used to live here, which meant it happened
/// inside `runLoop` while the loop result was written after `runLoop` returned —
/// two separate atomic file writes describing one tick, with no transaction
/// between them. Both now go to `LoopRecordStore.record` together. See
/// dev/backlog/loop-record-store-grdb.md §1.3 and §5.1.
public protocol SafetyService {
    func tempBasal(at: Date, settings: CodableSettings, reactiveSafeTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async -> SafetyTempBasal
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

    /// Spelled out because the initializer below suppresses the implicit
    /// memberwise one, and the store's row decoder needs this shape to rebuild a
    /// state it has already shredded into columns.
    init(at: Date, duration: TimeInterval, kind: Kind) {
        self.at = at
        self.duration = duration
        self.kind = kind
    }

    /// Projects a decision onto the matching `Kind`, dropping the unused form's
    /// candidates.
    ///
    /// This was `LocalSafetyService.record`'s first half. It is a pure mapping
    /// with no state and no I/O, so it belongs on the type rather than on the
    /// service — and moving it here is what lets `runLoop` build the state it
    /// *would* have recorded and hand it to the store, instead of writing it
    /// mid-loop through a side channel.
    init(at: Date, decision: DosingDecision, candidates: DoseCandidates, duration: TimeInterval) {
        let kind: Kind
        switch decision {
        case .tempBasal(let unitsPerHour):
            kind = .tempBasal(programmed: unitsPerHour, physiological: candidates.physiologicalTempBasal)
        case .microBolus(let units):
            kind = .microBolus(programmed: units, physiological: candidates.physiologicalMicroBolus)
        case .suspendForBiologicalInvariant:
            kind = .suspended
        }
        self.init(at: at, duration: duration, kind: kind)
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
    let timeHorizon: TimeInterval = LoopRecordStorePolicy.safetyTimeHorizon

    /// nil when the store could not be opened. Every read below then takes the
    /// conservative branch — see `fallback`.
    private let recordStore: LoopRecordStore?
    private let log = DiagnosticLog(category: "SafetyService")

    init(recordStore: LoopRecordStore?) {
        self.recordStore = recordStore
    }

    // Note: we ignore actual insulin delivered and use the
    // programmed values for the safety service
    func tempBasal(at: Date, settings: CodableSettings, reactiveSafeTempBasalUnitsPerHour: Double, machineLearningTempBasalUnitsPerHour: Double, duration: TimeInterval) async ->  SafetyTempBasal {

        let start = at - timeHorizon

        // The rule this file exists to enforce: **a ledger read that cannot be
        // answered returns the reactive-safe temp basal, never an empty tally.**
        //
        // `historicalMlInsulin` is subtracted from the budget below, so an empty
        // ledger does not read as "unknown" — it reads as *no ML insulin has
        // been delivered*, which grants the maximum deviation. The old
        // `(try? storage.read()) ?? []` produced exactly that on any decode
        // failure, silently. `SafetyServiceTests` pins all three ways of getting
        // here.
        //
        // A zero deviation hands `DoseSelector` the physiological PID's number
        // whether or not `useMachineLearningClosedLoop` is set. That is the same
        // conservative branch the divide-by-zero guard below already takes, so
        // this reuses an existing behavior rather than inventing one. The
        // reported tally of 0 is display-only and is a lie in the "we don't
        // know" case, which is worth a log line and not worth a new optional in
        // the return type.
        let fallback = SafetyTempBasal(
            tempBasal: reactiveSafeTempBasalUnitsPerHour,
            machineLearningInsulinLastThreeHours: 0
        )

        guard let recordStore else {
            log.error("no loop record store; refusing the ML budget and using the reactive-safe temp basal")
            return fallback
        }

        let events: [SafetyState]
        do {
            events = try await recordStore.safetyStates(from: start - duration, to: at)
        } catch LoopRecordStoreError.historyIncomplete(let detail) {
            // Expected, and temporary: the window reaches back further than the
            // store has existed. Happens after the cutover from
            // `safety_states.json`, after a reinstall, and after a restore from a
            // backup that predates the database. Stops on its own once the store
            // covers the whole span the tally reads — `timeHorizon + duration`
            // after creation, since the query reaches back a correction duration
            // past the horizon to catch a temp basal that began before it.
            log.default("safety ledger incomplete, refusing the ML budget: %{public}@", detail)
            return fallback
        } catch {
            log.error("safety ledger unreadable, refusing the ML budget: %{public}@", String(describing: error))
            return fallback
        }

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
}
