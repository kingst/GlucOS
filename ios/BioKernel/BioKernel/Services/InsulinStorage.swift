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
//  It no longer holds that state itself. Events go to `InsulinRecordStore`, every
//  read derives from `InsulinRecordTimeline` over a window the store answers, and
//  what is left here is the boundary: turning a driver batch into a write, and
//  turning a failed read into a refusal to dose rather than a wrong number. The
//  24-hour JSON log this actor used to own, and the verifier that ran beside it,
//  were deleted at phase 3 of dev/backlog/insulin-storage-grdb.md §7.5.
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

public protocol PumpEventUpdate: AnyObject {
    /// The pump event log changed.
    ///
    /// Deliberately carries nothing (decision 11). A delegate that is handed the
    /// whole log is a delegate that has to *keep* being handed the whole log,
    /// which puts a ceiling on how much history the store is allowed to hold —
    /// the exact ceiling this work exists to remove. Ask for a bounded window
    /// instead, on demand.
    func pumpEventsDidChange()
}

public protocol InsulinStorage {
    /// - Parameter replacePendingEvents: *this batch is the driver's complete
    ///   current set of pending (mutable) doses.* Per call, and both values occur
    ///   in one driver, so it may not be treated as always-on: a pod change
    ///   passes false and asserts nothing about pending doses.
    /// - Parameter pump: what the pump and insulin were at the moment these
    ///   events arrived. Captured per call because people change pumps and
    ///   insulins over a history, and the published record is the only place
    ///   that pairing survives.
    func addPumpEvents(_ events: [NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, pump: PumpMetadata) async -> Error?
    func insulinOnBoard(at: Date) async -> Double
    func insulinDelivered(startDate: Date, endDate: Date) async -> Double
    func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double
    func pumpAlarm() async -> PumpAlarmType?
    func setPumpRecordsBasalProfileStartEvents(_ flag: Bool) async
    func lastPumpSync() async -> Date?
    func currentInsulinType() async -> InsulinType
    func activeBolus(at: Date) async -> DoseEntry?
    func registerForPumpEntryUpdates(delegate: PumpEventUpdate) async
    /// Pump events over a bounded recent window, for the diagnostics view.
    ///
    /// The other half of decision 11, and it means what it says: the record store
    /// answers for any window inside retention, so `since` is not silently capped
    /// at 24 hours the way the old JSON log capped it.
    func recentPumpEvents(since: Date) async -> [NewPumpEvent]

    /// Pump events inside a closed window.
    ///
    /// The bounded sibling of `recentPumpEvents`, which always reads through to
    /// now. A meal window is a closed interval that can sit anywhere inside 90
    /// days of retention, so reading it through to the present would pull every
    /// event since — months of them, to render three and a half hours.
    func pumpEvents(from: Date, to: Date) async -> [NewPumpEvent]

    /// A basal schedule we just successfully pushed to the pod.
    ///
    /// See dev/backlog/scheduled-basal-history.md §4. **Call on success only** —
    /// never before it, never on failure. The setting is what the user asked for;
    /// the pod's resume is what it accepted, and per §2 that resume is also the
    /// instant the new rate begins running.
    ///
    /// This does not write a rate record. It enqueues a pending program that a
    /// resume later consumes, so a program the pod never took never reaches a
    /// lookup.
    func recordScheduledBasalProgram(rateUnitsPerHour: Double, at: Date) async
}

actor LocalInsulinStorage: InsulinStorage {
    let healthKitStorage: HealthKitStorage
    private let watchComms: @MainActor () -> WatchComms
    private let settingsStorage: @MainActor () -> SettingsStorage
    private let aiInterfaceStorage: AiInterfaceStorage?

    /// The only source of insulin history. See
    /// dev/backlog/insulin-storage-grdb.md.
    ///
    /// Optional because a database that will not open leaves `AppComposition`
    /// nothing to inject, and that is a dosing outage rather than a
    /// configuration: §8's rule is that it must be loud. Every read below
    /// reports "we do not know" instead of a number, and `lastPumpSync` reporting
    /// nil is what makes the loop skip the tick rather than dose off nothing.
    private let recordStore: InsulinRecordStore?

    init(
        healthKitStorage: HealthKitStorage,
        watchComms: @MainActor @escaping () -> WatchComms,
        settingsStorage: @MainActor @escaping () -> SettingsStorage,
        aiInterfaceStorage: AiInterfaceStorage? = nil,
        recordStore: InsulinRecordStore? = nil
    ) {
        self.healthKitStorage = healthKitStorage
        self.watchComms = watchComms
        self.settingsStorage = settingsStorage
        self.aiInterfaceStorage = aiInterfaceStorage
        self.recordStore = recordStore
        Task {
            // Publish once at launch so an AI app has a current picture before
            // the first pump sync of the session. No pump is connected yet, so
            // the exporter falls back to the last metadata it saw.
            await exportToAiInterface(pump: nil, at: Date())
        }
    }

    /// Recorded from LoopKit and deliberately not read (decision 14).
    ///
    /// The JSON path branched on it to decide whether to infer scheduled basal at
    /// all. The record store needs no branch: a pump that *does* report basal
    /// profile starts delivers them as `.basal` doses, which are already boundaries
    /// in `derive`, so there is no gap left for inference to fill. The flag became
    /// unnecessary rather than unsupported, which is why the setter stays — it is
    /// LoopKit's delegate contract, and dropping it would make
    /// `DeviceDataManager+Pump` lie about having handled the callback.
    var pumpRecordsBasalProfileStartEvents = false

    weak var updateDelegate: PumpEventUpdate? = nil

    private let log = DiagnosticLog(category: "InsulinStorage")
    
    /// When the pump last reconciled, or nil if we cannot find out.
    ///
    /// **nil is the app's fail-closed path and the reason none of these reads had
    /// to grow an error channel.** `ClosedLoopService` gates every tick on this
    /// being both present and fresh, so a store that cannot be read stops the loop
    /// at that guard — before any IOB number is consulted — and the tick is
    /// recorded as `.pumpReadingStale`. Refusing to dose is the only safe answer
    /// when the history is unreadable; §8's alternative, returning 0 for IOB, is
    /// the one that makes the loop dose *more*.
    func lastPumpSync() async -> Date? {
        guard let recordStore else {
            log.error("no record store; reporting no pump sync so the loop skips")
            return nil
        }
        do {
            return try await recordStore.lastReconciliation()
        } catch {
            log.error(
                "record store read failed for lastReconciliation; reporting no pump sync so the loop skips: %{public}@",
                String(describing: error)
            )
            return nil
        }
    }

    func registerForPumpEntryUpdates(delegate: any PumpEventUpdate) async {
        updateDelegate = delegate
    }

    func recentPumpEvents(since: Date) async -> [NewPumpEvent] {
        guard let recordStore else { return [] }
        do {
            return try await recordStore
                .records(from: since, to: Date(), includeRevoked: false)
                .map { $0.newPumpEvent() }
        } catch {
            log.error(
                "record store read failed for recentPumpEvents: %{public}@",
                String(describing: error)
            )
            return []
        }
    }

    func pumpEvents(from: Date, to: Date) async -> [NewPumpEvent] {
        guard let recordStore else { return [] }
        do {
            return try await recordStore
                .records(from: from, to: to, includeRevoked: false)
                .map { $0.newPumpEvent() }
        } catch {
            log.error(
                "record store read failed for pumpEvents: %{public}@",
                String(describing: error)
            )
            return []
        }
    }

    func currentInsulinType() async -> InsulinType {
        // use the most recent dose to determine the insulin type we're using
        guard let recordStore else { return .humalog }
        do {
            // nil means the store has never seen a dose carrying a type, which is
            // "we do not know" rather than a read failure, so it takes the same
            // default a failure does.
            return try await recordStore.currentInsulinType(at: Date()) ?? .humalog
        } catch {
            log.error(
                "record store read failed for currentInsulinType: %{public}@",
                String(describing: error)
            )
            return .humalog
        }
    }

    func setPumpRecordsBasalProfileStartEvents(_ flag: Bool) {
        pumpRecordsBasalProfileStartEvents = flag
    }


    func pumpAlarm() async -> PumpAlarmType? {
        guard let recordStore else { return nil }
        do {
            return try await recordStore.pumpAlarm(at: Date())
        } catch {
            log.error(
                "record store read failed for pumpAlarm: %{public}@",
                String(describing: error)
            )
            return nil
        }
    }

    func addPumpEvents(_ events: [LoopKit.NewPumpEvent], lastReconciliation: Date?, replacePendingEvents: Bool, pump: PumpMetadata) async -> Error? {
        // One instant for the whole call. Two `Date()` reads here would let the
        // export and the record store disagree about when this batch arrived.
        let at = Date()

        let storeError = await writeToRecordStore(
            events: events,
            lastReconciliation: lastReconciliation,
            replacePendingEvents: replacePendingEvents,
            pump: pump,
            at: at
        )

        updateDelegate?.pumpEventsDidChange()
        let comms = await MainActor.run { watchComms() }
        await comms.updateAppContext()

        Task { [healthKitStorage] in
            await healthKitStorage.save(pumpEvents: events)
        }

        // Publishing for AI apps must never delay the pump manager's completion
        // handler, so this is deliberately not awaited. Passes carry their own
        // `at` and the exporter drops any that arrives out of order.
        await exportToAiInterface(pump: pump, at: at)

        // §8's authority rule, and the one place a write can fail a dose: a lost
        // row is a dose the loop will never see again, so the driver has to
        // re-deliver the batch rather than clear it.
        return storeError
    }

    /// The write. §8.
    ///
    /// Returns the ingest error rather than throwing so `addPumpEvents` still
    /// notifies its delegate, the watch, and the exporter about the events it did
    /// receive — the batch is re-delivered, not dropped, so what is published now
    /// is a prefix of the truth rather than a contradiction of it.
    private func writeToRecordStore(
        events: [NewPumpEvent],
        lastReconciliation: Date?,
        replacePendingEvents: Bool,
        pump: PumpMetadata,
        at: Date
    ) async -> Error? {
        // The database could not be opened, which §8 calls a dosing outage.
        // Returning an error here would put the driver into an unbounded
        // redelivery loop against a store that will not exist until relaunch, so
        // this is loud and not fatal — and `lastPumpSync` returning nil is what
        // actually stops the loop from dosing.
        guard let recordStore else {
            log.error("no record store; this batch is lost and the loop will skip until relaunch")
            return nil
        }

        do {
            let ingest = try await recordStore.ingest(PumpEventBatch(
                events: events,
                lastReconciliation: lastReconciliation,
                replacePendingEvents: replacePendingEvents,
                pump: pump,
                at: at
            ))

            // §4.3's backstop. Retention falling back to the nominal cutoff means
            // the driver has stopped minting the resumes the boundary anchors on.
            if ingest.retention.pruned > 0 && !ingest.retention.isAnchored {
                log.error(
                    "retention pruned %d row(s) with no anchoring resume; the store is back to a clamped left edge",
                    ingest.retention.pruned
                )
            }

            return nil
        } catch {
            log.error(
                "record store ingest failed; failing the batch so the driver re-delivers: %{public}@",
                String(describing: error)
            )
            return error
        }
    }

    func recordScheduledBasalProgram(rateUnitsPerHour: Double, at: Date) async {
        guard let recordStore else { return }
        do {
            try await recordStore.enqueueScheduledBasalProgram(rateUnitsPerHour: rateUnitsPerHour, at: at)
        } catch {
            // Deliberately not fatal. `derive` prices inferred basal off this
            // history, and losing a program means the next resume is attributed to
            // the *previous* rate — a bounded, one-directional error that
            // self-corrects at the next successful enqueue, rather than a wrong or
            // fabricated rate. And this is called from the basal schedule sync's
            // completion handler, where the pod has *already* accepted the new
            // rate, so failing here would report an error for a change that did
            // happen.
            log.error(
                "could not enqueue a scheduled basal program; inferred basal keeps the old rate: %{public}@",
                String(describing: error)
            )
        }
    }

    /// How much pump history the AI interface exporter is offered per pass.
    ///
    /// The span the old JSON log happened to retain, kept deliberately rather than
    /// widened to the store's 90 days. The exporter's ids are anchored to a
    /// segment's start instant and its ledger keys on them, so the window decides
    /// which segments get published and offering a different one would republish
    /// history under new ids. The ledger makes re-offering the same span a no-op,
    /// so this only ever needs to be wide enough to cover the gap between passes.
    private static let aiExportWindow = 24.hoursToSeconds()

    /// Hands the dose timeline to the AI interface exporter.
    ///
    /// The read happens here, inside the actor, so the exporter always gets a
    /// consistent snapshot even though the export itself runs detached.
    private func exportToAiInterface(pump: PumpMetadata?, at: Date) async {
        guard let aiInterfaceStorage else { return }
        guard let recordStore else { return }

        let events: [NewPumpEvent]
        do {
            events = try await recordStore
                .records(from: at - Self.aiExportWindow, to: at, includeRevoked: false)
                .map { $0.newPumpEvent() }
        } catch {
            // Publishing is never allowed to be load-bearing, and a pass that
            // publishes nothing loses nothing permanently: the ledger only records
            // what was written, so the next pass re-offers this span.
            log.error(
                "record store read failed for the AI interface export; skipping this pass: %{public}@",
                String(describing: error)
            )
            return
        }

        let doses = InsulinTimeline.deduplicatedDoses(events: events, at: at)
        let scheduledRate = await MainActor.run { settingsStorage().snapshot().pumpBasalRateUnitsPerHour }
        Task {
            await aiInterfaceStorage.exportInsulinDosing(
                doses: doses,
                scheduledBasalRateUnitsPerHour: scheduledRate,
                pump: pump,
                at: at
            )
        }
    }

    /// The derivation every insulin number comes from.
    ///
    /// `nil` means the store could not answer, which §8 calls a dosing outage. It
    /// is loud in the log, and the callers below turn it into zero because a
    /// `-> Double` signature has nowhere else to go.
    ///
    /// **What actually keeps the loop safe here is `lastPumpSync`, not this
    /// value.** Zero IOB is precisely the failure §8 warns about — the loop reads
    /// low and doses *more* — so the protection has to come from refusing to dose
    /// at all, and it does: `ClosedLoopService` gates every tick on
    /// `lastPumpSync()` being present and fresh, that read hits the same database
    /// as this one, and it reports nil on failure. The remaining callers are the
    /// watch, the summary view, and the diagnostics view, where a zero is a wrong
    /// display rather than a wrong dose.
    private func derivation(
        windowStart: Date,
        at: Date,
        metric: String
    ) async -> InsulinRecordTimeline.Derivation? {
        guard let recordStore else {
            log.error("no record store; %{public}@ has no history to derive from", metric)
            return nil
        }
        do {
            let timeline = try await recordStore.timeline(
                windowStart: windowStart,
                at: at,
                includeRevoked: false
            )
            return InsulinRecordTimeline.derive(timeline: timeline)
        } catch {
            log.error(
                "record store read failed for %{public}@: %{public}@",
                metric, String(describing: error)
            )
            return nil
        }
    }

    func insulinOnBoard(at: Date) async -> Double {
        // The same window the verifier compared against for every tick of the
        // parallel run, so what ships is what was measured.
        let windowStart = at - InsulinRecordStorePolicy.insulinOnBoardWindow
        guard let derivation = await derivation(windowStart: windowStart, at: at, metric: "iob") else {
            return 0
        }
        return derivation.insulinOnBoard(at: at)
    }

    func insulinDeliveredFromAutomaticTempBasal(startDate: Date, endDate: Date) async -> Double {
        guard let derivation = await derivation(
            windowStart: startDate,
            at: endDate,
            metric: "automaticTempBasal"
        ) else {
            return 0
        }
        return derivation.insulinDeliveredFromAutomaticTempBasal(startDate: startDate, endDate: endDate)
    }

    func insulinDelivered(startDate: Date, endDate: Date) async -> Double {
        guard let derivation = await derivation(
            windowStart: startDate,
            at: endDate,
            metric: "delivered"
        ) else {
            return 0
        }
        return derivation.insulinDelivered(startDate: startDate, endDate: endDate)
    }

    func activeBolus(at: Date) async -> DoseEntry? {
        // A state query rather than a timeline query (I3): an in-flight bolus is
        // one row, and asking a 12-hour window for it would be answering a cheap
        // question expensively.
        guard let recordStore else { return nil }
        do {
            return try await recordStore.activeBolus(at: at)
        } catch {
            log.error(
                "record store read failed for activeBolus: %{public}@",
                String(describing: error)
            )
            return nil
        }
    }
}

extension PumpEventType {
    init?(rawValue: String) {
        switch rawValue {
        case "AlarmPump":
            self = .alarm
        case "ClearAlarm":
            self = .alarmClear
        case "BasalProfileStart":
            self = .basal
        case "Bolus":
            self = .bolus
        case "Prime":
            self = .prime
        case "PumpResume":
            self = .resume
        case "Rewind":
            self = .rewind
        case "PumpSuspend":
            self = .suspend
        case "TempBasal":
            self = .tempBasal
        default:
            if rawValue.starts(with: "Replace"), let value = ReplaceableComponent(rawValue: String(rawValue.dropFirst(7))) {
                self = .replaceComponent(componentType: value)
            } else {
                return nil
            }
        }
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
        
        let model: InsulinModel
        if insulinType == .lyumjev {
            // TODO: Revisit after experimenting with 10 hour DIA
            //model = ExponentialInsulinModel(actionDuration: 6.hoursToSeconds(), peakActivityTime: 45.minutesToSeconds())
            model = PresetInsulinModelProvider(defaultRapidActingModel: nil).model(for: insulinType)
        } else {
            model = PresetInsulinModelProvider(defaultRapidActingModel: nil).model(for: insulinType)
        }
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
