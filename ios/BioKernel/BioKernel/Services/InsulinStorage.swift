//
//  InsulinStorage.swift
//  BioKernel
//
//  Created by Sam King on 11/7/23.
//
//  The purpose of this service is to maintain the current state of the insulin pump
//  to calculate IoB. As an input, it takes a stream of `NewPumpEvent` events and
//  uses this stream to infer the current state.
//
//  Correct pump state is:
//    - The pump can be either suspended or running.
//        - If it is suspended, it is not delivering any insulin
//        - If it is running, it is delivering basal insulin either at the pre defined
//          rate or using a temp basal (which can be 0)
//    - Any immutable doses were already delivered and will be included in the IoB calculation
//    - Any currently delivering bolus doses will be included. There can be at most one.
//    - Any currently delivering basal will be included. There will always be one for a running pump.
//
//  The OmniPod does _not_ include explicit default basal events, so we have to infer them
//
//  To stay consistent with Loop we also make two assumptions:
//    - Any doses with a duration of less than or equal to 1.05 * 5.minutes duration are delivered
//      in full at the `startDate`
//    - Any doses greater than 1.05 * 5.minutes duration are broken into 5 minute segments starting
//      at the `startDate` and the pump delivers each segment in full at the beginning of the segment
//
//  We treat alarms as separate -- they don't impact IoB but maybe they should???

import Foundation

import LoopKit
import HealthKit

public protocol InsulinStorage {
    func addPumpEvents(_ events: [NewPumpEvent], lastReconciliation: Date?, insulinType: InsulinType) async -> Error?
    func insulinOnBoard(at: Date) async -> Double
    func insulinDelivered(startDate: Date, endDate: Date) async -> Double
    func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double
    func pumpAlarm() async -> PumpAlarmType?
    func setPumpRecordsBasalProfileStartEvents(_ flag: Bool) async
    func lastPumpSync() async -> Date?
    func currentInsulinType() async -> InsulinType
    func activeBolus(at: Date) async -> DoseEntry?
}

enum InsulinStorageError: Error {
    case failedToStoreData
    case fileSystemWriteError
    case encodingError
}

actor LocalInsulinStorage: InsulinStorage {
    struct PumpEventStorage: Codable {
        let eventLog: [NewPumpEvent]
        let lastPumpReconciliation: Date?
    }
    
    static let shared = LocalInsulinStorage()
    
    let storage = getStoredObject().create(fileName: "pump_events.v2.json")
    var hasDoneInitialReadFromDisk = false
    let replayLogger = getEventLogger()
    
    init() {
        Task {
            await readFromDisk()
        }
    }
    
    // we store these on disk
    var eventLog: [NewPumpEvent] = []
    // we don't use this so we can ignore it for now
    var lastPumpReconciliation: Date?
    
    var pumpRecordsBasalProfileStartEvents = false
    
    func lastPumpSync() -> Date? {
        return lastPumpReconciliation
    }
    
    func currentInsulinType() async -> InsulinType {
        // use the most recent dose to determine the insulin type we're using
        await readFromDisk()
        
        for event in eventLog.reversed() {
            if let dose = event.dose, let insulinType = dose.insulinType {
                return insulinType
            }
        }
        
        return .humalog
    }
    
    func setPumpRecordsBasalProfileStartEvents(_ flag: Bool) {
        pumpRecordsBasalProfileStartEvents = flag
    }

    
    func pumpAlarm() async -> PumpAlarmType? {
        await readFromDisk()
        let alarmEvents = eventLog.filter { $0.type == .alarmClear || $0.type == .alarm }
        guard let lastAlarmEvent = alarmEvents.last else { return nil }
        if lastAlarmEvent.type == .alarmClear { return nil }
        return lastAlarmEvent.alarmType
    }
    
    func addPumpEvents(_ events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, insulinType: InsulinType) async -> Error? {
        await readFromDisk() // just in case the init task hasn't finished yet
        await replayLogger.add(events: events)
        self.lastPumpReconciliation = lastReconciliation
        eventLog.append(contentsOf: events)
        let ret = syncDataToDisk()
        await getWatchComms().updateAppContext()
        return ret
    }
    
    private func readFromDisk() async {
        guard !hasDoneInitialReadFromDisk else { return }
        
        if let pumpStorage: PumpEventStorage = try? storage.read() {
            eventLog = pumpStorage.eventLog
            lastPumpReconciliation = pumpStorage.lastPumpReconciliation
        } else {
            // try to read from the old version
            let oldStorage = getStoredObject().create(fileName: "pump_events.json")
            eventLog = (try? oldStorage.read()) ?? []
            lastPumpReconciliation = nil
            
            // XXX FIXME we should clean up old pump events
        }
        
        hasDoneInitialReadFromDisk = true
    }
    
    func removeStaleMutableDoses(events: [NewPumpEvent]) -> [NewPumpEvent] {
        let immutableSyncIds = events.compactMap { event -> String? in
            guard let dose = event.dose, !dose.isMutable else { return nil }
            return dose.syncIdentifier
        }
        let immutableSet = Set(immutableSyncIds)
        
        let reducedEvents = events.filter { event in
            guard let dose = event.dose, let syncId = dose.syncIdentifier else { return true }
            guard dose.isMutable else { return true }
            return !immutableSet.contains(syncId)
        }
        
        return reducedEvents
    }
    
    func removeOldEvents(events: [NewPumpEvent], cutOff: Date) -> [NewPumpEvent] {
        return events.filter { $0.date >= cutOff }
    }
    
    func getMostRecentStatefulOldEvents(events: [NewPumpEvent], cutOff: Date) -> [NewPumpEvent] {
        var mostRecentBasal: NewPumpEvent? = nil
        var mostRecentSuspendResume: NewPumpEvent? = nil
        var mostRecentAlarm: NewPumpEvent? = nil
        
        for event in events.filter({ $0.date < cutOff }) {
            switch event.type {
            case .alarm, .alarmClear:
                mostRecentAlarm = event
            case .tempBasal, .basal:
                mostRecentBasal = event
            case .suspend, .resume:
                mostRecentSuspendResume = event
            case .rewind, .prime:
                // FIXME: Figure out if we need to deal with rewind / prime (I don't think so for OmniPod)
                break
            case .bolus:
                // bolus events are short -- no need to keep old ones around
                break
            case .none:
                // FIXME: I'm not sure when this would happen???
                break
            }
        }
        
        let mostRecentEvents = [mostRecentBasal, mostRecentAlarm, mostRecentSuspendResume]
        return mostRecentEvents.compactMap({ $0 }).sorted { $0.date < $1.date }
    }
    
    private func syncDataToDisk() -> InsulinStorageError? {
        // trim the logs before storing it to disk
        if let mostRecentTime = eventLog.last?.date {
            let cutOff = mostRecentTime - 9.hoursToSeconds()
            let cleanedEvents = removeStaleMutableDoses(events: eventLog)
            let recentEvents = removeOldEvents(events: cleanedEvents, cutOff: cutOff)
            let mostRecentOldEvents = getMostRecentStatefulOldEvents(events: cleanedEvents, cutOff: cutOff)
            eventLog = mostRecentOldEvents + recentEvents
        }
        do {
            let pumpData = PumpEventStorage(eventLog: eventLog, lastPumpReconciliation: lastPumpReconciliation)
            try storage.write(pumpData)
        } catch {
            return .fileSystemWriteError
        }
        
        return nil
    }
    
    func insulinOnBoard(at: Date) async -> Double {
        await readFromDisk() // just in case the init task hasn't finished yet
        return await insulinOnBoard(events: eventLog, at: at)
    }
    
    func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double {
        await readFromDisk()
        return await insulinDeliveredFromAutomaticTempBasal(events: eventLog, startDate: startDate, endDate: endDate)
    }
    
    func insulinDelivered(startDate: Date, endDate: Date) async -> Double {
        await readFromDisk()
        return await insulinDelivered(events: eventLog, startDate: startDate, endDate: endDate)
    }
    
    func activeBolus(at: Date) async -> DoseEntry? {
        await readFromDisk()
        let doses = deduplicatedDoses(events: eventLog, at: at).filter { $0.startDate < at && $0.endDate >= at && $0.type == .bolus }
        return doses.last
    }
    
    private func deduplicatedDoses(events: [NewPumpEvent], at: Date) -> [DoseEntry] {
        // get all of the events that start before `at`
        let doseEvents = events.compactMap { event -> (String, DoseEntry)? in
            guard let dose = event.dose, let syncId = dose.syncIdentifier, dose.startDate < at else {
                return nil
            }
            return (syncId, dose)
        }
        
        // convert to a dict in event order so that we have the latest state for the event.
        // Add the immutable entries first so that we can add mutable doses iff the immutable
        // dose doesn't exist
        var doses: [String: DoseEntry] = [:]
        for doseEvent in doseEvents.filter({ !$0.1.isMutable }) {
            doses[doseEvent.0] = doseEvent.1
        }
        for doseEvent in doseEvents {
            if !doses.keys.contains(doseEvent.0) {
                doses[doseEvent.0] = doseEvent.1
            }
        }
        
        return doses.values.sorted { $0.startDate < $1.startDate }
    }
    
    func inferBasalDoses(doses: [DoseEntry], at: Date) async -> [DoseEntry] {
        let basalDoses = doses.filter({ $0.type == .tempBasal || $0.type == .resume || $0.type == .suspend }).sorted(by: { $0.startDate < $1.startDate })
        
        let insulinType = doses.filter({ $0.type == .tempBasal || $0.type == .bolus }).sorted(by: { $0.startDate < $1.startDate }).last?.insulinType ?? .humalog
        
        var inferredBasalDoses: [DoseEntry] = []
        for (curr, next) in zip(basalDoses, basalDoses.dropFirst()) {
            if curr.type != .suspend, let basalDose = await createBasalDose(insulinType: insulinType, start: curr.endDate, end: next.startDate) {
                inferredBasalDoses.append(basalDose)
            }
        }
        
        if let lastDose = basalDoses.last, lastDose.type != .suspend {
            if let basalDose = await createBasalDose(insulinType: insulinType, start: lastDose.endDate, end: at) {
                inferredBasalDoses.append(basalDose)
            }
        }
        
        return inferredBasalDoses
    }
    
    func insulinDeliveredFromAutomaticTempBasal(events: [NewPumpEvent], startDate: Date, endDate: Date) async -> Double {
        let doses = deduplicatedDoses(events: events, at: endDate).filter { !$0.manuallyEntered && $0.type == .tempBasal}
        return doses.map({ $0.insulinDeliveredBetween(startDate: startDate, endDate: endDate) }).reduce(0, +)
    }
    
    func insulinDelivered(events: [NewPumpEvent], startDate: Date, endDate: Date) async -> Double {
        let doses = deduplicatedDoses(events: events, at: endDate)
        let insulin = doses.map({ $0.insulinDeliveredBetween(startDate: startDate, endDate: endDate) }).reduce(0, +)

        // for pumps that don't record basal start events we need to infer when the pump is running
        // at the basal rate
        guard !pumpRecordsBasalProfileStartEvents else {
            return insulin
        }
        
        let basalDoses = await inferBasalDoses(doses: doses, at: endDate)
        let basalInsulin = basalDoses.map({ $0.insulinDeliveredBetween(startDate: startDate, endDate: endDate) }).reduce(0, +)
        return insulin + basalInsulin
    }
    
    func insulinOnBoard(events: [NewPumpEvent], at: Date) async -> Double {
        let doses = deduplicatedDoses(events: events, at: at)        
        let iob = doses.map({ $0.insulinOnBoard(at: at) }).reduce(0, +)

        // for pumps that don't record basal start events we need to infer when the pump is running
        // at the basal rate
        guard !pumpRecordsBasalProfileStartEvents else {
            return iob
        }
        
        let basalDoses = await inferBasalDoses(doses: doses, at: at)
        let basalIob = basalDoses.map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        return iob + basalIob
    }
    
    private func createBasalDose(insulinType: InsulinType, start: Date, end: Date) async -> DoseEntry? {
        let gap = end.timeIntervalSince(start)
        // we want to filter out any inferred basal doses that run
        // for less than one second. Loop uses .ulpOfOne but it
        // adds a bunch of noise
        guard gap > 1.0 else { return nil }

        let basalRate = await MainActor.run { getSettingsStorage().snapshot().pumpBasalRateUnitsPerHour }
        let basalRatePerSecond = basalRate / 1.hoursToSeconds()
        let unitsDelivered = basalRatePerSecond * gap
        return DoseEntry(type: .basal, startDate: start, endDate: end, value: basalRate, unit: .unitsPerHour, deliveredUnits: unitsDelivered, insulinType: insulinType, isMutable: false)
    }
}

extension NewPumpEvent: @retroactive Encodable, @retroactive Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let date = try container.decode(Date.self, forKey: .date)
        let dose = try container.decodeIfPresent(DoseEntry.self, forKey: .dose)
        let raw = try container.decode(Data.self, forKey: .raw)
        let title = try container.decode(String.self, forKey: .title)
        let alarmType = try container.decodeIfPresent(PumpAlarmType.self, forKey: .alarmType)
        let rawType = try container.decodeIfPresent(String.self, forKey: .type)
        let type = PumpEventType(rawValue: rawType ?? "")

        self.init(date: date, dose: dose, raw: raw, title: title, type: type, alarmType: alarmType)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encodeIfPresent(dose, forKey: .dose)
        try container.encode(raw, forKey: .raw)
        try container.encodeIfPresent(type?.rawValue, forKey: .type)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(alarmType, forKey: .alarmType)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case dose
        case raw
        case type
        case title
        case alarmType
    }
}

struct InsulinDelivered {
    let at: Date
    let units: Double
    let insulinType: InsulinType
    
    func insulinOnBoard(at: Date) -> Double {
        guard at > self.at else { return 0.0 }
        
        let model = PresetInsulinModelProvider(defaultRapidActingModel: nil).model(for: insulinType)
        return units * model.percentEffectRemaining(at: at.timeIntervalSince(self.at))
    }
}

// this insulinOnBoard function is logically identical to Loop's formulation
// but uses absolute insulin amounts vs relative to the basal rate
extension DoseEntry {
    func insulinDeliveryQuantized() -> [InsulinDelivered] {
        switch self.type {
        case .bolus, .basal, .tempBasal:
            let delta = 5.minutesToSeconds()
                        
            // For small intervals, deliver it all at once
            // note: this check is critical for correctness because it
            // eliminates a bunch of corner cases, like endDate < startDate
            // or segment sizes that are so small they'll cause floating point
            // math problems
            //
            // I don't know where the 1.05 comes from, this fudge factor how Loop
            // does it so we'll use it as well for consistency
            guard endDate.timeIntervalSince(startDate) > 1.05 * delta else {
                let units = deliveredUnits ?? programmedUnits
                let insulinType = self.insulinType ?? .humalog
                return [InsulinDelivered(at: startDate, units: units, insulinType: insulinType)]
            }
            
            // break down an entry into 5 minute segments and deliver the amount of insulin
            // in a segment at the beginning of a segment
            var delivered: [InsulinDelivered] = []
            var start = startDate
            while start < endDate {
                let end = start + delta
                let units = insulinDeliveredForSegment(startDate: start, endDate: end)
                let insulinType = self.insulinType ?? .humalog
                delivered.append(InsulinDelivered(at: start, units: units, insulinType: insulinType))
                start += delta
            }
            return delivered
        default:
            return []
        }
    }
    
    func insulinOnBoard(at: Date) -> Double {
        return insulinDeliveryQuantized().map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
    }
    
    func insulinDeliveredBetween(startDate: Date, endDate: Date) -> Double {
        let delivered = insulinDeliveryQuantized().filter { $0.at >= startDate && $0.at < endDate }
        return delivered.map({ $0.units }).reduce(0, +)
    }
    
    func insulinDeliveredForSegment(startDate: Date, endDate: Date) -> Double {
        // Find the intersection between the passed-in segment and the dose segment
        // and return the amount of insulin delivered during the overlap
        let intersectionStart = max(self.startDate, startDate)
        let intersectionEnd = min(self.endDate, endDate)
    
        // Ensure valid intersection
        guard intersectionStart <= intersectionEnd else { return 0.0 }
    
        let doseDuration = self.endDate.timeIntervalSince(self.startDate)
    
        // Prevent division by zero by checking if doseDuration is zero
        guard doseDuration > 0 else { return 0.0 }
    
        let intersectionDuration = intersectionEnd.timeIntervalSince(intersectionStart).clamp(low: 0, high: doseDuration)
    
        let units = deliveredUnits ?? programmedUnits
        return units * intersectionDuration / doseDuration
    }
}
