//
//  PumpEventRecord.swift
//  BioKernel
//
//  Created by Sam King on 8/3/26.
//
//  One row of the `pump_event` table, as a domain value. See
//  dev/backlog/insulin-storage-grdb.md §4.1.
//
//  I1: this type holds what the pump reported, and nothing derived. There is no
//  field for an inferred segment, deliberately — inference stays a pure sweep
//  over these rows (§2.1), and a struct with nowhere to put a conclusion is the
//  cheapest way to keep it that way.
//
//  GRDB does not appear here. The record store's protocol seam speaks these
//  values; the GRDB row type that maps them to columns is private to
//  `GRDBInsulinRecordStore`, so the dependency stays swappable and the tests
//  never touch it (§9).
//

import Foundation
import LoopKit

/// The normalized spelling of `event_type`.
///
/// Deliberately not `PumpEventType.rawValue`: LoopKit spells suspend
/// "PumpSuspend" and scheduled basal "BasalProfileStart", and §6.3's state
/// queries are written against `('suspend','resume')` and
/// `('alarm','alarmClear')`. A query you can read against a schema you can read
/// is most of why this store is SQL (§9.4).
///
/// One deviation from the schema in §4.1: `replaceComponent` carries which
/// component was replaced, so it is spelled `replaceComponent:pump` rather than
/// bare `replaceComponent`. Without it the row cannot round-trip back to the
/// `NewPumpEvent` the diagnostics view renders.
enum PumpEventKind: Equatable {
    case tempBasal
    case bolus
    case basal
    case suspend
    case resume
    case alarm
    case alarmClear
    case rewind
    case prime
    case replaceComponent(ReplaceableComponent)
    /// An event the driver gave us with neither a `type` nor a dose we can type.
    /// Stored rather than dropped: I1 says we keep what the pump reported, and a
    /// row we cannot classify is still evidence that something happened.
    case unknown

    /// Suspend and resume are the two `event_type` values the suspension state
    /// query in §6.3 selects on.
    static let suspensionKinds: [PumpEventKind] = [.suspend, .resume]
    /// Likewise for `pumpAlarm()`.
    static let alarmKinds: [PumpEventKind] = [.alarm, .alarmClear]
    /// The kinds that bound an inferred scheduled-basal segment. Suspend and
    /// resume are absent on purpose — that absence is I3.
    static let basalKinds: [PumpEventKind] = [.tempBasal, .basal]

    var rawValue: String {
        switch self {
        case .tempBasal: return "tempBasal"
        case .bolus: return "bolus"
        case .basal: return "basal"
        case .suspend: return "suspend"
        case .resume: return "resume"
        case .alarm: return "alarm"
        case .alarmClear: return "alarmClear"
        case .rewind: return "rewind"
        case .prime: return "prime"
        case .replaceComponent(let component): return "replaceComponent:\(component.rawValue)"
        case .unknown: return "unknown"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "tempBasal": self = .tempBasal
        case "bolus": self = .bolus
        case "basal": self = .basal
        case "suspend": self = .suspend
        case "resume": self = .resume
        case "alarm": self = .alarm
        case "alarmClear": self = .alarmClear
        case "rewind": self = .rewind
        case "prime": self = .prime
        case "unknown": self = .unknown
        default:
            let prefix = "replaceComponent:"
            guard rawValue.hasPrefix(prefix),
                  let component = ReplaceableComponent(rawValue: String(rawValue.dropFirst(prefix.count))) else {
                self = .unknown
                return
            }
            self = .replaceComponent(component)
        }
    }

    init(_ pumpEventType: PumpEventType) {
        switch pumpEventType {
        case .tempBasal: self = .tempBasal
        case .bolus: self = .bolus
        case .basal: self = .basal
        case .suspend: self = .suspend
        case .resume: self = .resume
        case .alarm: self = .alarm
        case .alarmClear: self = .alarmClear
        case .rewind: self = .rewind
        case .prime: self = .prime
        case .replaceComponent(let component): self = .replaceComponent(component)
        }
    }

    init(_ doseType: DoseType) {
        switch doseType {
        case .tempBasal: self = .tempBasal
        case .bolus: self = .bolus
        case .basal: self = .basal
        case .suspend: self = .suspend
        case .resume: self = .resume
        }
    }

    /// The `PumpEventType` this row came from, for rebuilding a `NewPumpEvent`.
    /// nil for `.unknown`, which is what the driver handed us.
    var pumpEventType: PumpEventType? {
        switch self {
        case .tempBasal: return .tempBasal
        case .bolus: return .bolus
        case .basal: return .basal
        case .suspend: return .suspend
        case .resume: return .resume
        case .alarm: return .alarm
        case .alarmClear: return .alarmClear
        case .rewind: return .rewind
        case .prime: return .prime
        case .replaceComponent(let component): return .replaceComponent(componentType: component)
        case .unknown: return nil
        }
    }

    /// The `DoseType` a dose row rebuilds as, and nil for the kinds that carry
    /// no dose.
    var doseType: DoseType? {
        switch self {
        case .tempBasal: return .tempBasal
        case .bolus: return .bolus
        case .basal: return .basal
        case .suspend: return .suspend
        case .resume: return .resume
        case .alarm, .alarmClear, .rewind, .prime, .replaceComponent, .unknown: return nil
        }
    }
}

/// One `pump_event` row.
///
/// `deletedAt` is a soft delete, and every read filters on it (§4.1). A revoked
/// dose has to stay legible so the revocation can propagate and so the phase 1
/// verifier's `R` term is a query rather than a guess; a `DELETE` makes a row's
/// disappearance indistinguishable from its never having existed.
struct PumpEventRecord: Equatable {
    /// The pump driver's identifier, or a synthetic one for events that have
    /// none. The primary key, and therefore the dedup mechanism (§4.1).
    let syncIdentifier: String
    /// The event's own time, as the driver reported it — not when we saw it.
    let date: Date
    let eventType: PumpEventKind
    let alarmType: PumpAlarmType?
    /// nil for a non-dose event. A dose spans `[doseStart, doseEnd)`, so range
    /// reads test overlap and never `doseStart` alone.
    let doseStart: Date?
    let doseEnd: Date?
    let rateUnitsPerHour: Double?
    let programmedUnits: Double?
    /// nil until the pump reports what it actually delivered.
    let deliveredUnits: Double?
    /// Per row, not global: people change pods, pumps, and insulins across a
    /// history, and this pairing is the only place that survives.
    let insulinType: AiInsulinType?
    let automatic: Bool?
    let manuallyEntered: Bool?
    /// I2: mutable until the pump's finalized report replaces it; immutable
    /// thereafter, and then it never changes.
    let isMutable: Bool
    /// Soft delete. NULL means live.
    let deletedAt: Date?
    let pumpPluginIdentifier: String
    let smallestDeliveryUnit: Double?
    /// When we ingested it. Distinct from `date` — the gap between them is how
    /// late a dose arrived.
    let recordedAt: Date
    /// The driver's opaque payload. Diagnostics only; nothing derives from it.
    let raw: Data?
    let title: String?

    // MARK: - Ingest

    /// Maps one `NewPumpEvent` onto a row.
    ///
    /// - Parameter at: the ingest instant, which becomes `recordedAt`.
    init(event: NewPumpEvent, pump: PumpMetadata, at: Date) {
        let dose = event.dose
        let kind: PumpEventKind = {
            if let type = event.type { return PumpEventKind(type) }
            // A dose with no event type still has a dose type, and losing it
            // would make the row unclassifiable for no reason.
            if let doseType = dose?.type { return PumpEventKind(doseType) }
            return .unknown
        }()

        self.syncIdentifier = Self.syncIdentifier(for: event, kind: kind)
        self.date = event.date
        self.eventType = kind
        self.alarmType = event.alarmType
        self.doseStart = dose?.startDate
        self.doseEnd = dose?.endDate
        self.rateUnitsPerHour = dose.map { $0.unitsPerHour }
        self.programmedUnits = dose.map { $0.programmedUnits }
        self.deliveredUnits = dose?.deliveredUnits
        self.insulinType = dose?.insulinType.map { AiInsulinType($0) }
        self.automatic = dose?.automatic
        self.manuallyEntered = dose?.manuallyEntered
        self.isMutable = dose?.isMutable ?? false
        self.deletedAt = nil
        self.pumpPluginIdentifier = pump.pluginIdentifier
        self.smallestDeliveryUnit = pump.smallestDeliveryUnit
        self.recordedAt = at
        self.raw = event.raw
        self.title = event.title
    }

    /// Verbatim initializer, for tests and for rows read back out of the store.
    init(
        syncIdentifier: String,
        date: Date,
        eventType: PumpEventKind,
        alarmType: PumpAlarmType? = nil,
        doseStart: Date? = nil,
        doseEnd: Date? = nil,
        rateUnitsPerHour: Double? = nil,
        programmedUnits: Double? = nil,
        deliveredUnits: Double? = nil,
        insulinType: AiInsulinType? = nil,
        automatic: Bool? = nil,
        manuallyEntered: Bool? = nil,
        isMutable: Bool,
        deletedAt: Date? = nil,
        pumpPluginIdentifier: String,
        smallestDeliveryUnit: Double? = nil,
        recordedAt: Date,
        raw: Data? = nil,
        title: String? = nil
    ) {
        self.syncIdentifier = syncIdentifier
        self.date = date
        self.eventType = eventType
        self.alarmType = alarmType
        self.doseStart = doseStart
        self.doseEnd = doseEnd
        self.rateUnitsPerHour = rateUnitsPerHour
        self.programmedUnits = programmedUnits
        self.deliveredUnits = deliveredUnits
        self.insulinType = insulinType
        self.automatic = automatic
        self.manuallyEntered = manuallyEntered
        self.isMutable = isMutable
        self.deletedAt = deletedAt
        self.pumpPluginIdentifier = pumpPluginIdentifier
        self.smallestDeliveryUnit = smallestDeliveryUnit
        self.recordedAt = recordedAt
        self.raw = raw
        self.title = title
    }

    /// The driver's `syncIdentifier` when it gave us one, and otherwise a
    /// synthetic one from date plus type — the same shape `HealthKitStorage`
    /// already uses for its fallback.
    ///
    /// Alarms and `replaceComponent` never carry one. A *dose* without one is
    /// not expected from any driver GlucOS runs on, and the store records an
    /// observation when it happens, because a synthetic id is invisible to the
    /// old JSON path's `deduplicatedDoses` (which drops such doses outright) and
    /// would otherwise show up as an unexplained verifier residual.
    static func syncIdentifier(for event: NewPumpEvent, kind: PumpEventKind) -> String {
        if let syncIdentifier = event.dose?.syncIdentifier, !syncIdentifier.isEmpty {
            return syncIdentifier
        }
        return syntheticSyncIdentifier(date: event.date, kind: kind)
    }

    /// Anchored to whole milliseconds so re-ingesting the same event produces
    /// the same key, which is the whole point of a primary key here.
    static func syntheticSyncIdentifier(date: Date, kind: PumpEventKind) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return "glucos:synthetic:\(kind.rawValue):\(milliseconds)"
    }

    static func isSynthetic(syncIdentifier: String) -> Bool {
        return syncIdentifier.hasPrefix("glucos:synthetic:")
    }

    // MARK: - Reads

    /// Whether this row carries a dose at all.
    var isDose: Bool {
        return doseStart != nil && doseEnd != nil && eventType.doseType != nil
    }

    /// Rebuilds the `DoseEntry` the row was made from.
    ///
    /// `DoseEntry.value` is internal to LoopKit, so the rate/units pair is
    /// reconstituted through the public initializer: a rate for basal-ish doses,
    /// an amount for a bolus. That round-trips `unitsPerHour` and
    /// `programmedUnits` exactly, which are the two things every sum here reads.
    ///
    /// - Parameter suspensionEndingAt: what to use as a suspend's right edge
    ///   when the pump reported it open-ended (`doseStart == doseEnd`). LoopKit
    ///   extends an unfinished suspend at read time rather than storing it
    ///   open-ended (§6.2); storing it would make a row's meaning depend on when
    ///   it is read, which is the mistake this whole design is about.
    func doseEntry(suspensionEndingAt: Date? = nil) -> DoseEntry? {
        guard let doseType = eventType.doseType, let doseStart, let doseEnd else { return nil }

        let value: Double
        let unit: DoseUnit
        switch doseType {
        case .tempBasal, .basal:
            value = rateUnitsPerHour ?? 0
            unit = .unitsPerHour
        case .bolus:
            value = programmedUnits ?? 0
            unit = .units
        case .suspend, .resume:
            value = 0
            unit = .units
        }

        var endDate = doseEnd
        if doseType == .suspend, let suspensionEndingAt, doseEnd <= doseStart, suspensionEndingAt > doseStart {
            endDate = suspensionEndingAt
        }

        return DoseEntry(
            type: doseType,
            startDate: doseStart,
            endDate: endDate,
            value: value,
            unit: unit,
            deliveredUnits: deliveredUnits,
            syncIdentifier: syncIdentifier,
            insulinType: insulinType?.insulinType,
            automatic: automatic,
            manuallyEntered: manuallyEntered ?? false,
            isMutable: isMutable
        )
    }

    /// Rebuilds the `NewPumpEvent` for the diagnostics view (decision 11).
    func newPumpEvent() -> NewPumpEvent {
        return NewPumpEvent(
            date: date,
            dose: doseEntry(),
            raw: raw ?? Data(),
            title: title ?? "",
            type: eventType.pumpEventType,
            alarmType: alarmType
        )
    }
}
