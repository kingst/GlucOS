//
//  AiInterfaceParityTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/1/26.
//
//  Does what GlucOS publishes actually reconcile with what GlucOS believes?
//
//  This replays the recorded pump logs through the exporter, then runs the
//  reader-side IoB algorithm from dev/ai-interface.md over the published files
//  and compares it against `insulinOnBoard(at:)`. Both sides are handed the
//  identical dose set and the identical insulin model, so anything left over is
//  the difference between the two *algorithms*, which is the number we want.
//
//  The two algorithms differ in two ways, and the run reports them separately
//  so a decision to move GlucOS onto the reader's algorithm can be made against
//  measurements rather than intuition:
//
//    - discretization: GlucOS spreads a dose's units proportionally across
//      5-minute segments; the reader rounds the dose into whole
//      `smallestDeliveryUnit` pulses and spreads the pulses.
//    - bucket anchoring: GlucOS anchors its 5-minute grid at each dose's own
//      `startDate`; the reader anchors one grid at `now` and works backwards.
//
//  The `.exact` attribution below removes bucketing entirely, so the gap
//  between `.exact` and the bucketed variants isolates the anchoring effect.
//

import Testing
import Foundation
import LoopKit

@testable import BioKernel

struct AiInterfaceParityTests {

    // MARK: - The reader's view of a dose

    /// What an AI app has after unioning `finalized_insulin_dosing.*.jsonl`
    /// with `current_insulin_dosing.json`.
    struct ReaderDose {
        let id: String
        let startTime: Date
        let endTime: Date
        let unitsDelivered: Double
        let insulinType: AiInsulinType
        let smallestDeliveryUnit: Double
    }

    /// Where in its 5-minute bucket a pulse is treated as having landed.
    enum Attribution: String, CaseIterable {
        /// No bucketing: each pulse is aged exactly. Isolates discretization.
        case exact
        /// `coefficient[i] = percentEffectRemaining(at: i * 5min)` — what an
        /// implementer following "pre-calculate a vector" would most likely
        /// write. Ages every pulse down to the youngest age in its bucket, so
        /// it reads slightly high.
        case bucketLowerEdge
        /// The unbiased choice within a bucket.
        case bucketMidpoint
    }

    /// The algorithm from dev/ai-interface.md §"Suggested IoB algorithm".
    ///
    /// Uses the same LoopKit insulin model GlucOS uses, so the comparison is
    /// about the record format and the bucketing, not about the curve.
    static func readerInsulinOnBoard(doses: [ReaderDose], at now: Date, attribution: Attribution) -> Double {
        let bucket = 5.minutesToSeconds()
        let provider = PresetInsulinModelProvider(defaultRapidActingModel: nil)
        var total = 0.0

        for dose in doses {
            guard dose.smallestDeliveryUnit > 0 else { continue }

            // "map each insulin delivery event to discretized values by using
            // smallestDeliveryUnit to figure out how many smallestDeliveryUnit
            // doses the pump delivered over the delivery duration"
            let pulses = Int((dose.unitsDelivered / dose.smallestDeliveryUnit).rounded())
            guard pulses > 0 else { continue }

            let duration = max(0, dose.endTime.timeIntervalSince(dose.startTime))
            let model = provider.model(for: dose.insulinType.insulinType)

            // "assume that insulin delivery is constant" — pulses spread evenly
            // across the dose, the first at its start.
            for pulse in 0..<pulses {
                let deliveredAt = dose.startTime + duration * Double(pulse) / Double(pulses)
                let age = now.timeIntervalSince(deliveredAt)
                guard age > 0 else { continue }

                let effectiveAge: Double
                switch attribution {
                case .exact:
                    effectiveAge = age
                case .bucketLowerEdge:
                    effectiveAge = (age / bucket).rounded(.down) * bucket
                case .bucketMidpoint:
                    effectiveAge = ((age / bucket).rounded(.down) + 0.5) * bucket
                }

                total += dose.smallestDeliveryUnit * model.percentEffectRemaining(at: effectiveAge)
            }
        }

        return total
    }

    // MARK: - Reading what we published

    final class Box: StoredObject {
        var data: Data?
        func read<T: Decodable>() throws -> T? {
            guard let data else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }
        func write<T: Encodable>(_ object: T) throws {
            data = try JSONEncoder().encode(object)
        }
        static func create(fileName: String) -> StoredObject { return Box() }
    }

    func makeContainer() throws -> AiInterfaceContainer {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try #require(AiInterfaceContainer(baseURL: base))
    }

    func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Every finalized record across every day file, parsed the way the spec
    /// tells readers to.
    func allFinalized(_ container: AiInterfaceContainer) throws -> [FinalizedDoseRecord] {
        var records: [FinalizedDoseRecord] = []
        for file in container.finalizedDayFiles() {
            guard let data = try? Data(contentsOf: file.url),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var lines = text.components(separatedBy: "\n")
            _ = lines.popLast() // drop any trailing partial record
            for line in lines {
                records.append(try decoder().decode(FinalizedDoseRecord.self, from: Data(line.utf8)))
            }
        }
        return records
    }

    func current(_ container: AiInterfaceContainer) throws -> CurrentInsulinDosing {
        let data = try Data(contentsOf: container.currentInsulinDosingURL)
        return try decoder().decode(CurrentInsulinDosing.self, from: data)
    }

    /// Builds the reader's dose list exactly as dev/ai-interface.md describes.
    func readerDoses(_ container: AiInterfaceContainer, at now: Date) throws -> [ReaderDose] {
        var doses = try allFinalized(container).map {
            ReaderDose(
                id: $0.id, startTime: $0.startTime, endTime: $0.endTime,
                unitsDelivered: $0.unitsDelivered, insulinType: $0.insulinType,
                smallestDeliveryUnit: $0.smallestDeliveryUnit
            )
        }

        let current = try current(container)

        if let bolus = current.bolus {
            // "assume all insulin delivered at once" — an over-count while a
            // bolus is running, which self corrects when it finalizes.
            doses.append(ReaderDose(
                id: bolus.id, startTime: bolus.startTime, endTime: now,
                unitsDelivered: bolus.programmedUnits, insulinType: bolus.insulinType,
                smallestDeliveryUnit: bolus.smallestDeliveryUnit
            ))
        }

        if let basal = current.basal {
            let duration = min(now.timeIntervalSince(basal.startTime), basal.endTime.timeIntervalSince(basal.startTime))
            doses.append(ReaderDose(
                id: basal.id, startTime: basal.startTime, endTime: basal.startTime + max(0, duration),
                unitsDelivered: max(0, duration) * basal.rateInUnitsPerHour / 1.hoursToSeconds(),
                insulinType: basal.insulinType, smallestDeliveryUnit: basal.smallestDeliveryUnit
            ))
        }

        return doses
    }

    // MARK: - The measurement

    struct Sample {
        let at: Date
        let glucos: Double
        let reader: [Attribution: Double]
    }

    struct Stats {
        let p50: Double
        let p90: Double
        let p99: Double
        let max: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            func percentile(_ q: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)]
            }
            p50 = percentile(0.50)
            p90 = percentile(0.90)
            p99 = percentile(0.99)
            max = sorted.last ?? 0
        }
    }

    // MARK: - The GlucOS side of the comparison
    //
    // Computed here rather than asked of `LocalInsulinStorage`, which derives
    // insulin from the record store. That is deliberate and it is what keeps this
    // file measuring one thing: the question here is whether the *exporter's*
    // published records reconcile with the dose set it was handed, so both sides
    // have to be built from that same dose set. Routing one side through the store
    // would fold the store's own reconciliation, quantization, and rate history
    // into a number that is supposed to isolate the reader's algorithm.
    //
    // Mirrors exactly what GlucOS's read path did when it shared `InsulinTimeline`
    // with the exporter: sum the doses, plus the scheduled-basal stretches between
    // them.

    private static func inferredBasalDoses(
        doses: [DoseEntry],
        scheduledRate: Double,
        at: Date
    ) -> [DoseEntry] {
        return InsulinTimeline
            .basalSegments(doses: doses, scheduledRateInUnitsPerHour: scheduledRate, at: at)
            .filter { $0.kind == .scheduled }
            .map { $0.asDoseEntry() }
    }

    private static func glucosInsulinOnBoard(
        doses: [DoseEntry],
        scheduledRate: Double,
        at: Date
    ) -> Double {
        let all = doses + inferredBasalDoses(doses: doses, scheduledRate: scheduledRate, at: at)
        return all.map { $0.insulinOnBoard(at: at) }.reduce(0, +)
    }

    private static func glucosInsulinDelivered(
        doses: [DoseEntry],
        scheduledRate: Double,
        startDate: Date,
        endDate: Date
    ) -> Double {
        let all = doses + inferredBasalDoses(doses: doses, scheduledRate: scheduledRate, at: endDate)
        return all
            .map { $0.insulinDeliveredBetween(startDate: startDate, endDate: endDate) }
            .reduce(0, +)
    }

    /// Replays a log through the exporter, sampling IoB on both sides every
    /// `step` from the first dose to the last.
    func measure(events: [NewPumpEvent], name: String, step: TimeInterval) async throws -> [Sample] {
        let doseDates = events.compactMap { $0.dose?.startDate }.sorted()
        let first = try #require(doseDates.first)
        let last = try #require(doseDates.last)

        let container = try makeContainer()
        let exporter = LocalAiInterfaceStorage(container: container, stateStorage: Box())

        // MockSettingsStorage's pump basal rate. Both sides must use the same
        // scheduled rate or we'd be measuring that instead.
        let scheduledRate = await MainActor.run { MockSettingsStorage().pumpBasalRateUnitsPerHour }
        let pump = PumpMetadata.lyumjevOnOmnipod

        var samples: [Sample] = []
        var at = first + step
        while at <= last {
            // One export pass, exactly as the app would run it.
            let doses = InsulinTimeline.deduplicatedDoses(events: events, at: at)
            await exporter.exportInsulinDosing(
                doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: at
            )

            let published = try readerDoses(container, at: at)

            // The spec promises `current` and `finalized` never hold the same
            // record, and that ids are stable, so a union dedupes cleanly.
            #expect(Set(published.map { $0.id }).count == published.count,
                    "\(name): a record appears in both current and finalized at \(at)")

            var reader: [Attribution: Double] = [:]
            for attribution in Attribution.allCases {
                reader[attribution] = Self.readerInsulinOnBoard(doses: published, at: at, attribution: attribution)
            }

            samples.append(Sample(
                at: at,
                glucos: Self.glucosInsulinOnBoard(doses: doses, scheduledRate: scheduledRate, at: at),
                reader: reader
            ))
            at += step
        }

        return samples
    }

    /// Where the run leaves its numbers.
    ///
    /// `print` from a test host does not survive `xcodebuild` — it only shows
    /// in Xcode's console — and the numbers are the whole point of this file,
    /// so they also go to a fixed path. The simulator's `/tmp` is the host's.
    static let reportPath = "/tmp/glucos_iob_parity.txt"

    func report(_ samples: [Sample], name: String) {
        let glucosValues = samples.map { $0.glucos }
        let meanIob = glucosValues.reduce(0, +) / Double(glucosValues.count)

        var out = "\n=== IoB parity: \(name) ===\n"
        out += String(format: "samples: %d   mean GlucOS IoB: %.3f U   max: %.3f U\n",
                      samples.count, meanIob, glucosValues.max() ?? 0)

        for attribution in Attribution.allCases {
            let absolute = samples.map { abs(($0.reader[attribution] ?? 0) - $0.glucos) }
            let signed = samples.map { ($0.reader[attribution] ?? 0) - $0.glucos }
            let relative = samples.compactMap { sample -> Double? in
                guard sample.glucos > 0.05 else { return nil }
                return abs((sample.reader[attribution] ?? 0) - sample.glucos) / sample.glucos
            }
            let bias = signed.reduce(0, +) / Double(signed.count)
            let absStats = Stats(absolute)
            let relStats = Stats(relative)
            out += String(format: "  %-16@ |dU| p50 %.4f  p90 %.4f  p99 %.4f  max %.4f   bias %+.4f U   |d%%| p50 %.2f%%  p99 %.2f%%\n",
                          attribution.rawValue as NSString,
                          absStats.p50, absStats.p90, absStats.p99, absStats.max,
                          bias, relStats.p50 * 100, relStats.p99 * 100)
        }

        print(out)
        append(out)
    }

    func append(_ text: String) {
        let url = URL(fileURLWithPath: Self.reportPath)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + text).write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Tests

    @Test func exportedRecordsReconcileWithGlucosIobOnTheFullReplayLog() async throws {
        let samples = try await measure(events: ReplayLogs.fullReplayLogs(), name: "replay_logs", step: 30.minutesToSeconds())
        report(samples, name: "replay_logs")

        #expect(samples.count > 20)

        // A structural guard, not a tuned tolerance: the two algorithms should
        // disagree by rounding, never by a missing or duplicated dose. Anything
        // approaching a whole unit means the export lost or double-counted
        // insulin, and the printed distribution above says where.
        for attribution in Attribution.allCases {
            let worst = samples.map { abs(($0.reader[attribution] ?? 0) - $0.glucos) }.max() ?? 0
            #expect(worst < 0.5, "\(attribution.rawValue) diverges by \(worst) U")
        }
    }

    @Test func exportedRecordsReconcileWithGlucosIobOnTheImmutableReplayLog() async throws {
        let samples = try await measure(events: ReplayLogs.immutableReplayLogs(), name: "immutable_replay_logs", step: 5.minutesToSeconds())
        report(samples, name: "immutable_replay_logs")

        #expect(samples.count > 5)
        for attribution in Attribution.allCases {
            let worst = samples.map { abs(($0.reader[attribution] ?? 0) - $0.glucos) }.max() ?? 0
            #expect(worst < 0.5, "\(attribution.rawValue) diverges by \(worst) U")
        }
    }

    /// Conservation: the published records have to add up to the same insulin
    /// GlucOS thinks it delivered, independently of any IoB curve. This is the
    /// assertion that would catch a dropped or duplicated basal segment.
    @Test func publishedRecordsAccountForAllDeliveredInsulin() async throws {
        let events = ReplayLogs.fullReplayLogs()
        let doseDates = events.compactMap { $0.dose?.startDate }.sorted()
        let first = try #require(doseDates.first)
        let last = try #require(doseDates.last)

        let container = try makeContainer()
        let exporter = LocalAiInterfaceStorage(container: container, stateStorage: Box())
        let scheduledRate = await MainActor.run { MockSettingsStorage().pumpBasalRateUnitsPerHour }

        var at = first + 30.minutesToSeconds()
        while at <= last {
            await exporter.exportInsulinDosing(
                doses: InsulinTimeline.deduplicatedDoses(events: events, at: at),
                scheduledBasalRateUnitsPerHour: scheduledRate, pump: .lyumjevOnOmnipod, at: at
            )
            at += 30.minutesToSeconds()
        }

        let published = try readerDoses(container, at: last)
        let publishedUnits = published.map { $0.unitsDelivered }.reduce(0, +)
        let glucosUnits = Self.glucosInsulinDelivered(
            doses: InsulinTimeline.deduplicatedDoses(events: events, at: last),
            scheduledRate: scheduledRate,
            startDate: first,
            endDate: last
        )

        let summary = String(format: "\n=== delivered insulin: published %.3f U vs GlucOS %.3f U (%+.2f%%) ===\n",
                             publishedUnits, glucosUnits, 100 * (publishedUnits - glucosUnits) / glucosUnits)
        print(summary)
        append(summary)

        // Both count the same doses; they differ only in how the trailing
        // partial segments at each end are attributed.
        #expect(abs(publishedUnits - glucosUnits) / glucosUnits < 0.02)
    }
}
