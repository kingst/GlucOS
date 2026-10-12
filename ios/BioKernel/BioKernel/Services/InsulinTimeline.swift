//
//  InsulinTimeline.swift
//  BioKernel
//
//  Created by Sam King on 8/1/26.
//
//  The pure dose-timeline reconstruction shared by `LocalInsulinStorage` (which
//  needs it for IoB) and the AI interface exporter (which needs it to publish
//  insulin delivery records). Both used to derive this separately, and the two
//  copies were free to drift.
//
//  The OmniPod does not record explicit scheduled-basal events, so any stretch
//  where no temp basal is running has to be inferred. `basalSegments` builds a
//  gapless picture of what the pump was doing:
//
//    - a temp basal covers [startDate, endDate) at its own rate
//    - a suspension covers [suspend, resume) at rate 0
//    - everything left over is scheduled basal at the pump's basal rate
//
//  `LocalInsulinStorage.inferBasalDoses` keeps only the `.scheduled` segments,
//  which reproduces its previous output exactly: it already skipped the gap
//  following a `.suspend`, and it never returned the temp basals themselves
//  because those doses are counted directly.
//

import Foundation
import LoopKit

enum BasalSegmentKind: Equatable {
    /// A temp basal the pump actually ran. The sync identifier is the pump
    /// driver's, and is nil only for a dose the driver didn't identify.
    case tempBasal(syncIdentifier: String?)
    /// The pump was suspended and delivered nothing. Published as an explicit
    /// rate-0 record so an AI never has to reason about suspension itself.
    case suspended
    /// No temp basal in effect, so the pump fell back to its scheduled rate.
    case scheduled
}

struct BasalSegment: Equatable {
    let startDate: Date
    let endDate: Date
    let rateInUnitsPerHour: Double
    let insulinType: InsulinType
    let kind: BasalSegmentKind
    /// Every dose bounding this segment is immutable, so neither edge can move
    /// later. A segment bounded on the right by a still-mutable temp basal is
    /// not settled: when that temp basal finalizes its `endDate` can shift and
    /// this segment would silently change with it.
    let hasSettledBoundaries: Bool
    /// What the pump reported for a segment backed by a real dose, and nil for
    /// an inferred one.
    ///
    /// This matters more than it looks: pumps deliver in whole
    /// `smallestDeliveryUnit` pulses, so a temp basal that ends mid-pulse
    /// reports measurably less than `rate × duration` — around 6% less across
    /// the recorded logs. GlucOS's own IoB counts the reported amount, so the
    /// published records have to as well or the two disagree by units of
    /// insulin over a day.
    let reportedUnits: Double?

    var duration: TimeInterval {
        return endDate.timeIntervalSince(startDate)
    }

    var unitsDelivered: Double {
        guard let reportedUnits else {
            return rateInUnitsPerHour / 1.hoursToSeconds() * duration
        }
        return reportedUnits
    }

    /// The `DoseEntry` form used by the IoB path. Reproduces exactly what
    /// `LocalInsulinStorage.createBasalDose` used to build.
    func asDoseEntry() -> DoseEntry {
        return DoseEntry(
            type: .basal,
            startDate: startDate,
            endDate: endDate,
            value: rateInUnitsPerHour,
            unit: .unitsPerHour,
            deliveredUnits: unitsDelivered,
            insulinType: insulinType,
            isMutable: false
        )
    }
}

enum InsulinTimeline {
    /// Inferred segments shorter than this are dropped. Loop uses `.ulpOfOne`
    /// but that admits a lot of floating-point noise.
    static let minimumInferredSegmentDuration = 1.0

    /// Collapses the raw event log by `syncIdentifier`, preferring the immutable
    /// version of a dose over the mutable one, and drops anything that starts at
    /// or after `at`.
    static func deduplicatedDoses(events: [NewPumpEvent], at: Date) -> [DoseEntry] {
        let doseEvents = events.compactMap { event -> (String, DoseEntry)? in
            guard let dose = event.dose, let syncId = dose.syncIdentifier, dose.startDate < at else {
                return nil
            }
            return (syncId, dose)
        }

        // Add the immutable entries first so a mutable dose is only taken when
        // no immutable version of it exists.
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

    /// Builds the gapless basal picture over the window ending at `at`.
    ///
    /// Note on overlapping temp basals: if two temp basals overlap, both are
    /// emitted at full duration and the overlap is counted twice. That matches
    /// what GlucOS's own IoB does with the same doses, which is the property we
    /// care about — the exported records have to reconcile with GlucOS's
    /// internal number. In practice the pump driver truncates a superseded temp
    /// basal's `endDate` when it goes immutable, so overlaps don't survive
    /// deduplication.
    /// - Parameter unknownInsulinType: used when the dose log carries no insulin
    ///   type at all. The IoB path leaves this at `.humalog` because that is
    ///   what it has always assumed; the exporter passes the pump's last known
    ///   type instead, since publishing a wrong insulin name is worse than a
    ///   tiny divergence from GlucOS's own IoB in a log that has no temp basals
    ///   or boluses in it.
    static func basalSegments(
        doses: [DoseEntry],
        scheduledRateInUnitsPerHour: Double,
        unknownInsulinType: InsulinType = .humalog,
        at: Date
    ) -> [BasalSegment] {
        let basalDoses = doses
            .filter { $0.type == .tempBasal || $0.type == .resume || $0.type == .suspend }
            .sorted { $0.startDate < $1.startDate }

        // The fallback insulin type comes from the most recent temp basal or
        // bolus. Suspend and resume are excluded because LoopKit emits suspend
        // without an insulin type at all.
        let fallbackInsulinType = doses
            .filter { $0.type == .tempBasal || $0.type == .bolus }
            .sorted { $0.startDate < $1.startDate }
            .last?.insulinType ?? unknownInsulinType

        var segments: [BasalSegment] = []

        // What the pump ran between one basal-ish event and the next. A gap
        // that follows a `.suspend` is the suspension itself.
        func appendInferredSegment(after previous: DoseEntry, until end: Date, rightBoundaryIsSettled: Bool) {
            guard end.timeIntervalSince(previous.endDate) > minimumInferredSegmentDuration else { return }
            let isSuspended = previous.type == .suspend
            segments.append(BasalSegment(
                startDate: previous.endDate,
                endDate: end,
                rateInUnitsPerHour: isSuspended ? 0 : scheduledRateInUnitsPerHour,
                insulinType: fallbackInsulinType,
                kind: isSuspended ? .suspended : .scheduled,
                hasSettledBoundaries: !previous.isMutable && rightBoundaryIsSettled,
                // Nothing reported these; the pump never told us they happened.
                reportedUnits: nil
            ))
        }

        for dose in basalDoses where dose.type == .tempBasal {
            segments.append(BasalSegment(
                startDate: dose.startDate,
                endDate: dose.endDate,
                rateInUnitsPerHour: dose.unitsPerHour,
                insulinType: dose.insulinType ?? fallbackInsulinType,
                kind: .tempBasal(syncIdentifier: dose.syncIdentifier),
                hasSettledBoundaries: !dose.isMutable,
                // The same fallback `insulinDeliveredForSegment` uses, so a
                // published record and GlucOS's IoB count the same units.
                reportedUnits: dose.deliveredUnits ?? dose.programmedUnits
            ))
        }

        for (current, next) in zip(basalDoses, basalDoses.dropFirst()) {
            appendInferredSegment(after: current, until: next.startDate, rightBoundaryIsSettled: !next.isMutable)
        }

        // The trailing stretch runs up to `at` and is never settled: it grows
        // every time we look, until a new dose bounds it on the right.
        if let lastDose = basalDoses.last {
            appendInferredSegment(after: lastDose, until: at, rightBoundaryIsSettled: false)
        }

        return segments.sorted { $0.startDate < $1.startDate }
    }
}
