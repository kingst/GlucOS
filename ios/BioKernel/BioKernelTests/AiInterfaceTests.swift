//
//  AiInterfaceTests.swift
//  BioKernelTests
//
//  Created by Sam King on 8/1/26.
//
//  Covers dev/backlog/ai-interface-prompt.md §8 for the writer half of the AI
//  interface. The IoB parity test against the replay logs lands in stage 2,
//  once the exporter is wired to real pump events.
//

import Testing
import Foundation
import LoopKit

@testable import BioKernel

struct AiInterfaceTests {

    // MARK: - Fixtures

    /// The exporter's ledger has to survive a "relaunch", which `MockStoredObject`
    /// can't model — it drops everything written to it. The box is shared by
    /// reference so a second actor sees the first one's state.
    final class InMemoryStoredObject: StoredObject {
        final class Box {
            var data: Data?
        }

        let box: Box

        init(box: Box) {
            self.box = box
        }

        func read<T: Decodable>() throws -> T? {
            guard let data = box.data else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }

        func write<T: Encodable>(_ object: T) throws {
            box.data = try JSONEncoder().encode(object)
        }

        static func create(fileName: String) -> StoredObject {
            return InMemoryStoredObject(box: Box())
        }
    }

    let scheduledRate = 0.5
    let pump = PumpMetadata.lyumjevOnOmnipod
    let accuracy = 0.000000001

    /// A fresh temp directory standing in for the app group container.
    func makeContainer() throws -> AiInterfaceContainer {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try #require(AiInterfaceContainer(baseURL: base))
    }

    func tempBasal(_ start: Date, _ duration: TimeInterval, rate: Double, id: String, isMutable: Bool = false) -> DoseEntry {
        return DoseEntry(
            type: .tempBasal,
            startDate: start,
            endDate: start + duration,
            value: rate,
            unit: .unitsPerHour,
            deliveredUnits: rate / 1.hoursToSeconds() * duration,
            syncIdentifier: id,
            insulinType: .lyumjev,
            isMutable: isMutable
        )
    }

    func bolus(_ start: Date, _ duration: TimeInterval, programmed: Double, delivered: Double?, id: String, isMutable: Bool) -> DoseEntry {
        return DoseEntry(
            type: .bolus,
            startDate: start,
            endDate: start + duration,
            value: programmed,
            unit: .units,
            deliveredUnits: delivered,
            syncIdentifier: id,
            insulinType: .lyumjev,
            isMutable: isMutable
        )
    }

    func suspend(_ at: Date, id: String) -> DoseEntry {
        return DoseEntry(type: .suspend, startDate: at, value: 0, unit: .units, syncIdentifier: id, isMutable: false)
    }

    func resume(_ at: Date, id: String) -> DoseEntry {
        return DoseEntry(type: .resume, startDate: at, value: 0, unit: .units, syncIdentifier: id, insulinType: .lyumjev, isMutable: false)
    }

    func makeExporter(container: AiInterfaceContainer, box: InMemoryStoredObject.Box) -> LocalAiInterfaceStorage {
        return LocalAiInterfaceStorage(container: container, stateStorage: InMemoryStoredObject(box: box))
    }

    /// Parses a day file the way the spec tells readers to: split on newlines
    /// and drop any trailing line that has no newline after it.
    func readFinalized(_ container: AiInterfaceContainer, day: String) throws -> [FinalizedDoseRecord] {
        let url = container.finalizedURL(forUtcDay: day)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        _ = lines.popLast() // partial record, or the empty tail after the final newline
        return try lines.map { try makeDecoder().decode(FinalizedDoseRecord.self, from: Data($0.utf8)) }
    }

    func readCurrent(_ container: AiInterfaceContainer) throws -> CurrentInsulinDosing {
        let data = try Data(contentsOf: container.currentInsulinDosingURL)
        return try makeDecoder().decode(CurrentInsulinDosing.self, from: data)
    }

    /// What a reader has to do. The timestamps are epoch seconds, and a default
    /// `JSONDecoder` would read them as seconds since 2001 without erroring.
    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Timeline

    @Test func suspensionBecomesAnExplicitRateZeroSegment() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            suspend(t0 + 20.minutesToSeconds(), id: "s"),
            resume(t0 + 30.minutesToSeconds(), id: "r")
        ]
        let now = t0 + 40.minutesToSeconds()

        let segments = InsulinTimeline.basalSegments(doses: doses, scheduledRateInUnitsPerHour: scheduledRate, at: now)

        #expect(segments.count == 4)
        #expect(segments.map { $0.kind } == [
            .tempBasal(syncIdentifier: "a"), .scheduled, .suspended, .scheduled
        ])
        #expect(segments.map { $0.rateInUnitsPerHour } == [1.0, scheduledRate, 0.0, scheduledRate])

        // Gapless: every segment starts where the previous one ended, and the
        // timeline runs from the first dose to `now`.
        #expect(segments.first?.startDate == t0)
        #expect(segments.last?.endDate == now)
        for (current, next) in zip(segments, segments.dropFirst()) {
            #expect(current.endDate == next.startDate)
        }
    }

    @Test func backToBackTempBasalsLeaveNoScheduledGap() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 30.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 30.minutesToSeconds(), 30.minutesToSeconds(), rate: 2.0, id: "b")
        ]
        let now = t0 + 60.minutesToSeconds()

        let segments = InsulinTimeline.basalSegments(doses: doses, scheduledRateInUnitsPerHour: scheduledRate, at: now)

        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.kind != .scheduled })
    }

    @Test func aTempBasalThatEndsEarlyLeavesAScheduledGap() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        // Ran 10 of its 30 programmed minutes before the pump moved on.
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 25.minutesToSeconds(), 30.minutesToSeconds(), rate: 2.0, id: "b")
        ]
        let now = t0 + 40.minutesToSeconds()

        let segments = InsulinTimeline.basalSegments(doses: doses, scheduledRateInUnitsPerHour: scheduledRate, at: now)

        let scheduled = try #require(segments.first { $0.kind == .scheduled })
        #expect(scheduled.startDate == t0 + 10.minutesToSeconds())
        #expect(scheduled.endDate == t0 + 25.minutesToSeconds())
        #expect(scheduled.rateInUnitsPerHour == scheduledRate)
        // 0.5 U/hr for 15 minutes
        #expect(abs(scheduled.unitsDelivered - 0.125) < accuracy)
    }

    @Test func aMutableTempBasalLeavesTheSegmentBeforeItUnsettled() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 30.minutesToSeconds(), rate: 2.0, id: "b", isMutable: true)
        ]
        let now = t0 + 30.minutesToSeconds()

        let segments = InsulinTimeline.basalSegments(doses: doses, scheduledRateInUnitsPerHour: scheduledRate, at: now)

        let scheduled = try #require(segments.first { $0.kind == .scheduled })
        #expect(scheduled.hasSettledBoundaries == false)

        // Once the temp basal goes immutable the gap before it settles.
        let settledDoses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 30.minutesToSeconds(), rate: 2.0, id: "b")
        ]
        let settledSegments = InsulinTimeline.basalSegments(doses: settledDoses, scheduledRateInUnitsPerHour: scheduledRate, at: now)
        let settled = try #require(settledSegments.first { $0.kind == .scheduled })
        #expect(settled.hasSettledBoundaries == true)
    }

    @Test func anEmptyDoseLogProducesNoSegments() throws {
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let segments = InsulinTimeline.basalSegments(doses: [], scheduledRateInUnitsPerHour: scheduledRate, at: now)
        #expect(segments.isEmpty)

        // Which means `basal` is null until the first pump sync.
        let export = LocalAiInterfaceStorage.buildExport(
            doses: [], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, alreadyExported: [], at: now
        )
        #expect(export.current.basal == nil)
        #expect(export.current.bolus == nil)
        #expect(export.newlyFinalized.isEmpty)
    }

    // MARK: - Finalization

    @Test func nothingFinalizesWhileABoundaryDoseIsMutable() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 30.minutesToSeconds(), rate: 2.0, id: "b", isMutable: true)
        ]
        let now = t0 + 30.minutesToSeconds()

        let export = LocalAiInterfaceStorage.buildExport(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, alreadyExported: [], at: now
        )

        // Only the first temp basal is settled and over. The scheduled gap is
        // bounded on the right by the mutable temp basal, and the mutable temp
        // basal itself is the current segment.
        #expect(export.newlyFinalized.map { $0.id } == ["OmnipodDash:a"])
        #expect(export.current.basal?.id == "OmnipodDash:b")
    }

    @Test func theCurrentSegmentIsNeverFinalized() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]
        let now = t0 + 40.minutesToSeconds()

        let export = LocalAiInterfaceStorage.buildExport(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, alreadyExported: [], at: now
        )

        // The trailing scheduled stretch runs up to `now` and keeps growing, so
        // it's current; the temp basal behind it is done.
        #expect(export.newlyFinalized.map { $0.id } == ["OmnipodDash:a"])
        let basal = try #require(export.current.basal)
        #expect(basal.startTime == t0 + 10.minutesToSeconds())
        #expect(basal.endTime == now)
        #expect(basal.rateInUnitsPerHour == scheduledRate)
    }

    @Test func aRunningBolusStaysCurrentThenFinalizesWithTheSameId() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")

        let running = bolus(t0, 2.minutesToSeconds(), programmed: 1.5, delivered: nil, id: "b1", isMutable: true)
        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [running], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 1.minutesToSeconds()
        )

        let day = AiInterfaceContainer.utcDay(for: t0)
        let currentBolus = try #require(try readCurrent(container).bolus)
        #expect(currentBolus.id == "OmnipodDash:b1")
        #expect(currentBolus.programmedUnits == 1.5)
        #expect(try readFinalized(container, day: day).isEmpty)

        let settled = bolus(t0, 2.minutesToSeconds(), programmed: 1.5, delivered: 1.5, id: "b1", isMutable: false)
        await exporter.exportInsulinDosing(
            doses: [settled], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 5.minutesToSeconds()
        )

        #expect(try readCurrent(container).bolus == nil)
        let finalized = try readFinalized(container, day: day)
        #expect(finalized.count == 1)
        // Same id across the move, so a reader that unions both files and
        // dedupes never counts this bolus twice.
        #expect(finalized.first?.id == "OmnipodDash:b1")
        #expect(finalized.first?.unitsDelivered == 1.5)
    }

    /// A bolus that is already immutable while its `endDate` is still ahead of
    /// us. In normal operation this doesn't happen — the pump reports a bolus
    /// mutable while it runs and immutable once it finishes — but clock skew
    /// between pump and phone can produce it, and so can replaying a finished
    /// log, which is how the IoB parity run surfaced it.
    ///
    /// Finalizing there publishes insulin that hasn't been delivered, and a
    /// reader discretizing that record drops every pulse still in the future:
    /// 1.25 U read as 0.30 U in the case that caught this. Under-counting IoB
    /// is the direction that makes an AI dose more.
    @Test func anImmutableBolusStillRunningStaysCurrent() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let running = bolus(t0, 60, programmed: 1.25, delivered: 1.25, id: "b1", isMutable: false)
        let at = t0 + 15 // a quarter of the way through delivery

        let midDelivery = LocalAiInterfaceStorage.buildExport(
            doses: [running], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: at
        )
        #expect(midDelivery.newlyFinalized.isEmpty)
        // Held at full programmed units, which over-counts — the safe direction.
        #expect(midDelivery.current.bolus?.id == "OmnipodDash:b1")
        #expect(midDelivery.current.bolus?.programmedUnits == 1.25)

        // Once it has actually ended it finalizes, with the same id.
        let afterDelivery = LocalAiInterfaceStorage.buildExport(
            doses: [running], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 300
        )
        #expect(afterDelivery.current.bolus == nil)
        #expect(afterDelivery.newlyFinalized.map { $0.id } == ["OmnipodDash:b1"])
        #expect(afterDelivery.newlyFinalized.first?.unitsDelivered == 1.25)
    }

    /// Also from the parity run: a temp basal's units come from what the pump
    /// reported, not from rate × duration. Pumps deliver whole pulses, so a
    /// segment that ends mid-pulse reports measurably less, and GlucOS's own
    /// IoB counts the reported figure.
    @Test func aTempBasalPublishesWhatThePumpReportedNotTheRate() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        // 1.2 U/hr for 23.9 minutes implies 0.478 U, but the pump pushed 9
        // pulses — exactly the shape seen in immutable_replay_logs.
        let dose = DoseEntry(
            type: .tempBasal, startDate: t0, endDate: t0 + 23.9 * 60,
            value: 1.2, unit: .unitsPerHour, deliveredUnits: 0.45,
            syncIdentifier: "tb", insulinType: .lyumjev, isMutable: false
        )

        let segments = InsulinTimeline.basalSegments(
            doses: [dose], scheduledRateInUnitsPerHour: scheduledRate, at: t0 + 60.minutesToSeconds()
        )
        let tempBasal = try #require(segments.first { $0.kind == .tempBasal(syncIdentifier: "tb") })
        #expect(tempBasal.unitsDelivered == 0.45)
        #expect(abs(tempBasal.rateInUnitsPerHour / 1.hoursToSeconds() * tempBasal.duration - 0.478) < 0.001)

        // Inferred segments have nothing reported, so they still integrate.
        let scheduled = try #require(segments.first { $0.kind == .scheduled })
        #expect(abs(scheduled.unitsDelivered - scheduledRate / 1.hoursToSeconds() * scheduled.duration) < accuracy)
    }

    @Test func aCanceledBolusFinalizesWithWhatItActuallyDelivered() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let canceled = bolus(t0, 2.minutesToSeconds(), programmed: 2.0, delivered: 0.7, id: "b1", isMutable: false)

        let export = LocalAiInterfaceStorage.buildExport(
            doses: [canceled], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 10.minutesToSeconds()
        )

        #expect(export.newlyFinalized.count == 1)
        #expect(export.newlyFinalized.first?.unitsDelivered == 0.7)
        #expect(export.current.bolus == nil)
    }

    @Test func extraUnsettledBolusesAreFinalizedRatherThanDropped() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let older = bolus(t0, 2.minutesToSeconds(), programmed: 1.0, delivered: 1.0, id: "b1", isMutable: true)
        let newer = bolus(t0 + 5.minutesToSeconds(), 2.minutesToSeconds(), programmed: 2.0, delivered: nil, id: "b2", isMutable: true)

        let export = LocalAiInterfaceStorage.buildExport(
            doses: [older, newer], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 6.minutesToSeconds()
        )

        // `current` only has room for one, so the older one is written out at
        // its best-known amount instead of vanishing.
        #expect(export.current.bolus?.id == "OmnipodDash:b2")
        #expect(export.newlyFinalized.map { $0.id } == ["OmnipodDash:b1"])
        #expect(export.newlyFinalized.first?.unitsDelivered == 1.0)
    }

    @Test func suspensionIsPublishedAsARateZeroRecord() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            suspend(t0 + 20.minutesToSeconds(), id: "s"),
            resume(t0 + 30.minutesToSeconds(), id: "r")
        ]
        let now = t0 + 40.minutesToSeconds()

        let export = LocalAiInterfaceStorage.buildExport(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, alreadyExported: [], at: now
        )

        let suspended = try #require(export.newlyFinalized.first { $0.unitsDelivered == 0 })
        #expect(suspended.startTime == t0 + 20.minutesToSeconds())
        #expect(suspended.endTime == t0 + 30.minutesToSeconds())
        #expect(suspended.id.hasPrefix("glucos:suspended:"))
    }

    /// `kind` names the pump command, so all three basal sources — a temp basal,
    /// the inferred scheduled rate, a stretch of suspension — publish as
    /// `.basal`, and only a bolus is `.bolus`.
    @Test func everyBasalSourcePublishesKindBasalAndOnlyABolusIsKindBolus() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            bolus(t0 + 15.minutesToSeconds(), 60, programmed: 2.0, delivered: 2.0, id: "b1", isMutable: false),
            suspend(t0 + 20.minutesToSeconds(), id: "s"),
            resume(t0 + 30.minutesToSeconds(), id: "r")
        ]

        let export = LocalAiInterfaceStorage.buildExport(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 40.minutesToSeconds()
        )

        let byKind = Dictionary(grouping: export.newlyFinalized, by: { $0.kind })
        #expect(byKind[.bolus]?.map { $0.id } == ["OmnipodDash:b1"])

        let basals = byKind[.basal] ?? []
        #expect(basals.contains { $0.id == "OmnipodDash:a" })
        #expect(basals.contains { $0.id.hasPrefix("glucos:basal:") })
        #expect(basals.contains { $0.id.hasPrefix("glucos:suspended:") })
        #expect(basals.count == export.newlyFinalized.count - 1)

        // Spelled as a name on the wire, which is what a reader matches on.
        let bolusRecord = try #require(byKind[.bolus]?.first)
        let data = try LocalAiInterfaceStorage.makeEncoder().encode(bolusRecord)
        let line = try #require(String(data: data, encoding: .utf8))
        #expect(line.contains("\"kind\":\"bolus\""))
    }

    // MARK: - Idempotency

    @Test func runningTheExporterTwiceWritesNoDuplicateLines() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let now = t0 + 40.minutesToSeconds()
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 10.minutesToSeconds(), rate: 2.0, id: "b")
        ]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)
        let afterFirstPass = try readFinalized(container, day: AiInterfaceContainer.utcDay(for: now))
        #expect(!afterFirstPass.isEmpty)

        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)
        let afterSecondPass = try readFinalized(container, day: AiInterfaceContainer.utcDay(for: now))
        #expect(afterSecondPass == afterFirstPass)
    }

    @Test func theLedgerSurvivesARelaunch() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let now = t0 + 40.minutesToSeconds()
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 10.minutesToSeconds(), rate: 2.0, id: "b")
        ]

        let firstLaunch = makeExporter(container: container, box: box)
        await firstLaunch.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)
        let afterFirstLaunch = try readFinalized(container, day: AiInterfaceContainer.utcDay(for: now))

        // A brand new actor reading the same ledger, as if the app restarted
        // and the pump replayed the same 24 hours of events.
        let secondLaunch = makeExporter(container: container, box: box)
        await secondLaunch.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)

        #expect(try readFinalized(container, day: AiInterfaceContainer.utcDay(for: now)) == afterFirstLaunch)
    }

    // MARK: - Day rollover

    @Test func recordsLandInTheDayTheyWereAppended() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()

        // A temp basal that ran late on the 14th, exported at 00:05 on the 15th.
        let t0 = Date.f("2026-03-14 23:30:00 +0000")
        let now = Date.f("2026-03-15 00:05:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 10.minutesToSeconds(), rate: 2.0, id: "b")
        ]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)

        let newDay = try readFinalized(container, day: "2026-03-15")
        #expect(!newDay.isEmpty)
        // The records describe the 14th but live in the 15th's file.
        #expect(newDay.contains { $0.startTime < Date.f("2026-03-15 00:00:00 +0000") })
        #expect(try readFinalized(container, day: "2026-03-14").isEmpty)
    }

    @Test func utcDaysAreFormattedAndParsedConsistently() throws {
        let date = Date.f("2026-03-15 00:05:00 +0000")
        #expect(AiInterfaceContainer.utcDay(for: date) == "2026-03-15")
        // Five minutes earlier is the previous UTC day.
        #expect(AiInterfaceContainer.utcDay(for: date - 10.minutesToSeconds()) == "2026-03-14")

        #expect(AiInterfaceContainer.utcDay(fromFinalizedFileName: "finalized_insulin_dosing.2026-03-15.jsonl") == "2026-03-15")
        // Anything that isn't one of ours is left alone.
        #expect(AiInterfaceContainer.utcDay(fromFinalizedFileName: "current_insulin_dosing.json") == nil)
        #expect(AiInterfaceContainer.utcDay(fromFinalizedFileName: "finalized_insulin_dosing.latest.jsonl") == nil)
        #expect(AiInterfaceContainer.utcDay(fromFinalizedFileName: "finalized_insulin_dosing.2026-13-45.jsonl") == nil)
    }

    // MARK: - Retention

    @Test func retentionDeletesOnlyFilesPastNinetyDays() throws {
        let container = try makeContainer()
        let now = Date.f("2026-03-15 12:00:00 +0000")

        let stale = AiInterfaceContainer.utcDay(for: now - 91.0.daysToSeconds())
        let fresh = AiInterfaceContainer.utcDay(for: now - 89.0.daysToSeconds())
        for day in [stale, fresh] {
            #expect(container.appendFinalized(line: Data("{}\n".utf8), utcDay: day))
        }

        // A file that isn't ours must survive, even inside our own directory.
        let foreign = container.writerURL.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: foreign)

        #expect(container.pruneFinalizedFiles(at: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: container.finalizedURL(forUtcDay: stale).path))
        #expect(FileManager.default.fileExists(atPath: container.finalizedURL(forUtcDay: fresh).path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func retentionRunsAtMostOncePerDay() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-15 12:00:00 +0000")
        let stale = AiInterfaceContainer.utcDay(for: now - 91.0.daysToSeconds())

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(doses: [], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)

        // Written after the day's retention pass already ran, so it survives
        // until tomorrow rather than being swept up mid-day.
        #expect(container.appendFinalized(line: Data("{}\n".utf8), utcDay: stale))
        await exporter.exportInsulinDosing(doses: [], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now + 5.minutesToSeconds())
        #expect(FileManager.default.fileExists(atPath: container.finalizedURL(forUtcDay: stale).path))

        // Next UTC day, retention runs again and collects it.
        await exporter.exportInsulinDosing(doses: [], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now + 1.0.daysToSeconds())
        #expect(!FileManager.default.fileExists(atPath: container.finalizedURL(forUtcDay: stale).path))
    }

    // MARK: - On-disk format

    @Test func everyLineIsNewlineTerminatedAndParsesStandalone() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let now = t0 + 40.minutesToSeconds()
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            suspend(t0 + 20.minutesToSeconds(), id: "s"),
            resume(t0 + 25.minutesToSeconds(), id: "r")
        ]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)

        let url = container.finalizedURL(forUtcDay: AiInterfaceContainer.utcDay(for: now))
        let text = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(text.hasSuffix("\n"))

        let lines = text.components(separatedBy: "\n").dropLast()
        #expect(lines.count >= 3)
        for line in lines {
            #expect(!line.isEmpty)
            // Each line stands on its own — no wrapping array, no shared state.
            _ = try makeDecoder().decode(FinalizedDoseRecord.self, from: Data(line.utf8))
        }
    }

    @Test func aFileTruncatedMidLineStillYieldsEveryCompleteRecordBeforeIt() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let now = t0 + 40.minutesToSeconds()
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            suspend(t0 + 20.minutesToSeconds(), id: "s"),
            resume(t0 + 25.minutesToSeconds(), id: "r")
        ]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now)

        let day = AiInterfaceContainer.utcDay(for: now)
        let complete = try readFinalized(container, day: day)
        #expect(complete.count >= 3)

        // Simulate a torn append: the process died partway through the last line.
        let url = container.finalizedURL(forUtcDay: day)
        let data = try Data(contentsOf: url)
        let truncated = data.prefix(data.count - 10)
        try Data(truncated).write(to: url)

        let survivors = try readFinalized(container, day: day)
        #expect(survivors == Array(complete.dropLast()))
    }

    @Test func anIdlePumpWritesNoBolusOrBasal() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [], scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )

        let object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: container.currentInsulinDosingURL)) as? [String: Any]
        )

        // Optionals encode as absent keys rather than explicit nulls, which
        // readers see the same way — `obj.get("bolus")` / `json["bolus"]` /
        // `decodeIfPresent` are all nil either way.
        #expect(object["bolus"] == nil)
        #expect(object["basal"] == nil)
        #expect(object["updatedAt"] != nil)
        // No version key: a missing version implies v=1.
        #expect(object["version"] == nil)

        let current = try readCurrent(container)
        #expect(current.bolus == nil)
        #expect(current.basal == nil)
    }

    @Test func insulinTypeIsWrittenAsANameNotALoopKitOrdinal() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        for insulinType in InsulinType.allCases {
            let record = FinalizedDoseRecord(
                id: "x", startTime: t0, endTime: t0 + 60, unitsDelivered: 0.1,
                insulinType: AiInsulinType(insulinType), smallestDeliveryUnit: 0.05,
                kind: .bolus
            )
            let data = try LocalAiInterfaceStorage.makeEncoder().encode(record)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("\"insulinType\":\"\(AiInsulinType(insulinType).rawValue)\""))
            // Round-trips back to the same LoopKit case.
            #expect(AiInsulinType(insulinType).insulinType == insulinType)
        }
    }

    /// The records spell their timestamps as `Date`, so the encoder's
    /// `.secondsSince1970` strategy is the only thing keeping epoch seconds on
    /// the wire. Losing it would emit seconds-since-2001 — still a JSON number,
    /// so nothing downstream would throw; a reader would just be 31 years off.
    @Test func timestampsAreEpochSecondsNotIsoStringsOrReferenceDates() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let now = t0 + 40.minutesToSeconds()

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )

        let current = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: container.currentInsulinDosingURL)) as? [String: Any]
        )
        #expect(current["updatedAt"] as? Double == now.timeIntervalSince1970)
        let basal = try #require(current["basal"] as? [String: Any])
        // A number, not a string, and counted from 1970 rather than 2001.
        #expect(basal["startTime"] as? Double == (t0 + 10.minutesToSeconds()).timeIntervalSince1970)
        #expect(basal["startTime"] as? String == nil)

        let url = container.finalizedURL(forUtcDay: AiInterfaceContainer.utcDay(for: now))
        let firstLine = try #require(
            String(data: try Data(contentsOf: url), encoding: .utf8)?.components(separatedBy: "\n").first
        )
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        #expect(raw["startTime"] as? Double == t0.timeIntervalSince1970)

        let record = try #require(try readFinalized(container, day: AiInterfaceContainer.utcDay(for: now)).first)
        #expect(record.startTime == t0)
    }

    // MARK: - File protection

    @Test func everythingWeCreateIsUnprotected() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [tempBasal(now - 40.minutesToSeconds(), 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )

        let created = [
            container.rootURL,
            container.writerURL,
            container.currentInsulinDosingURL,
            container.finalizedURL(forUtcDay: AiInterfaceContainer.utcDay(for: now))
        ]

        // Caveat, measured rather than assumed: the iOS Simulator does not
        // implement data protection and reports no `.protectionKey` at all for
        // files and directories we create with one. So on the simulator this
        // loop only proves the paths exist and that nothing we write reports a
        // *protected* class; the `== .none` half of it can only be exercised on
        // a real device. Left strict so it fails loudly if that ever changes.
        for url in created {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                #expect(protection == .none, "\(url.lastPathComponent) is \(protection.rawValue)")
            }
        }

        // Re-asserting must not disturb anything, and must not reach outside
        // AiInterface/GlucOS.
        container.reassertFileProtection()
        for url in created {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let protection = attributes[.protectionKey] as? FileProtectionType {
                #expect(protection == .none, "\(url.lastPathComponent) is \(protection.rawValue)")
            }
        }
    }

    @Test func weNeverTouchAnythingOutsideOurOwnDirectory() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")

        // An AI app's subtree, next to ours in the shared container.
        let aiDirectory = container.rootURL.appendingPathComponent("ai/com.example.coach", isDirectory: true)
        try FileManager.default.createDirectory(at: aiDirectory, withIntermediateDirectories: true)
        let aiFile = aiDirectory.appendingPathComponent("meal_announcements.2026-03-14.jsonl")
        let aiContents = Data("{\"mealId\":\"m1\"}\n".utf8)
        try aiContents.write(to: aiFile)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [tempBasal(now - 40.minutesToSeconds(), 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )
        container.reassertFileProtection()
        container.pruneFinalizedFiles(at: now + 200.0.daysToSeconds())

        #expect(try Data(contentsOf: aiFile) == aiContents)

        // Everything we created lives under AiInterface/GlucOS.
        let ours = try FileManager.default.contentsOfDirectory(atPath: container.rootURL.path)
        #expect(Set(ours) == Set(["GlucOS", "ai"]))
    }

    @Test func aMissingAppGroupDegradesToANoOp() async throws {
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")

        // What a signing regression looks like: no container at all.
        let exporter = LocalAiInterfaceStorage(container: nil, stateStorage: InMemoryStoredObject(box: box))
        await exporter.exportInsulinDosing(
            doses: [tempBasal(now - 40.minutesToSeconds(), 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )

        // Nothing thrown, nothing written, nothing recorded.
        #expect(box.data == nil)
    }

    // MARK: - Pass ordering and pump metadata

    @Test func anOutOfOrderPassCannotWalkCurrentBackwards() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]

        // Exports are fired without being awaited, so a slow pass can land
        // after a newer one.
        let exporter = makeExporter(container: container, box: box)
        let newer = t0 + 40.minutesToSeconds()
        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: newer)
        let afterNewer = try readCurrent(container)

        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 20.minutesToSeconds()
        )
        #expect(try readCurrent(container) == afterNewer)
        #expect(try readCurrent(container).updatedAt == newer.timeIntervalSince1970)

        // An equal timestamp still runs; the ledger keeps it from duplicating.
        let day = AiInterfaceContainer.utcDay(for: newer)
        let lines = try readFinalized(container, day: day)
        await exporter.exportInsulinDosing(doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: newer)
        #expect(try readFinalized(container, day: day) == lines)
    }

    @Test func aLaunchPassWithNoPumpUsesTheLastKnownMetadata() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]

        let firstLaunch = makeExporter(container: container, box: box)
        await firstLaunch.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )

        // Relaunch: the app publishes before any pump has reported this session.
        let secondLaunch = makeExporter(container: container, box: box)
        await secondLaunch.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: nil, at: t0 + 50.minutesToSeconds()
        )

        let basal = try #require(try readCurrent(container).basal)
        #expect(basal.smallestDeliveryUnit == pump.smallestDeliveryUnit)
        // Still namespaced by the real pump, so ids stay stable across restarts.
        #expect(basal.id.hasPrefix("glucos:basal:") || basal.id.hasPrefix("\(pump.pluginIdentifier):"))
    }

    /// The bug this replaces, found on device: the launch pass ran before any
    /// pump had reported, minted ids under a placeholder namespace, and then the
    /// first pump sync republished every one of those doses under the real
    /// namespace. Different ids, so the ledger couldn't catch it — 229 of 234
    /// doses landed in the file twice and a reader summed exactly double the
    /// insulin.
    ///
    /// Ids are namespaced by the pump, so with no pump there is no stable id and
    /// the only correct move is to publish nothing yet.
    @Test func aLaunchBeforeAnyPumpHasReportedPublishesNothing() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            bolus(t0 + 15.minutesToSeconds(), 60, programmed: 2.0, delivered: 2.0, id: "b1", isMutable: false)
        ]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: nil, at: t0 + 40.minutesToSeconds()
        )

        let day = AiInterfaceContainer.utcDay(for: t0)
        #expect(try readFinalized(container, day: day).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: container.currentInsulinDosingURL.path))

        // The first pump sync publishes the whole backfill, once each.
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 45.minutesToSeconds()
        )

        let records = try readFinalized(container, day: day)
        #expect(records.count == Set(records.map { $0.id }).count)
        #expect(records.allSatisfy { $0.id.hasPrefix("OmnipodDash:") || $0.id.hasPrefix("glucos:") })
        // One bolus, counted once — the symptom on device was exactly 2x here.
        let bolusRecords = records.filter { $0.id == "OmnipodDash:b1" }
        #expect(bolusRecords.count == 1)
        #expect(bolusRecords.first?.unitsDelivered == 2.0)
    }

    /// The same class of bug from the other direction: if the pump's plugin
    /// identifier ever changes, the published ids change with it, and a ledger
    /// keyed on the whole id would treat every dose in the log as new.
    @Test func aChangedPumpNamespaceDoesNotRepublishOldRecords() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            bolus(t0 + 15.minutesToSeconds(), 60, programmed: 2.0, delivered: 2.0, id: "b1", isMutable: false)
        ]
        let day = AiInterfaceContainer.utcDay(for: t0)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )
        let afterFirstPump = try readFinalized(container, day: day)
        #expect(!afterFirstPump.isEmpty)

        let differentPump = PumpMetadata(pluginIdentifier: "SomeOtherPump", smallestDeliveryUnit: 0.05, insulinType: .fiasp)
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: differentPump, at: t0 + 45.minutesToSeconds()
        )

        #expect(try readFinalized(container, day: day) == afterFirstPump)
    }

    // MARK: - Reset

    @Test func resettingClearsPublishedFilesAndTheLedgerTogether() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            tempBasal(t0 + 20.minutesToSeconds(), 10.minutesToSeconds(), rate: 2.0, id: "b")
        ]
        let day = AiInterfaceContainer.utcDay(for: t0)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )
        let published = try readFinalized(container, day: day)
        #expect(!published.isEmpty)

        await exporter.resetPublishedData()

        #expect(try readFinalized(container, day: day).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: container.currentInsulinDosingURL.path))
        #expect(container.finalizedDayFiles().isEmpty)

        // The ledger went with the files, so the next pass republishes the whole
        // history rather than believing it is already out there.
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 45.minutesToSeconds()
        )
        let republished = try readFinalized(container, day: day)
        #expect(Set(republished.map { $0.id }) == Set(published.map { $0.id }))
    }

    @Test func resettingLeavesAnAiAppsFilesAlone() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")

        let aiDirectory = container.rootURL.appendingPathComponent("ai/com.example.coach", isDirectory: true)
        try FileManager.default.createDirectory(at: aiDirectory, withIntermediateDirectories: true)
        let aiFile = aiDirectory.appendingPathComponent("meal_announcements.2026-03-14.jsonl")
        let aiContents = Data("{\"mealId\":\"m1\"}\n".utf8)
        try aiContents.write(to: aiFile)

        // Something in our own directory that isn't ours either.
        let foreign = container.writerURL.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: foreign)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )
        await exporter.resetPublishedData()

        #expect(try Data(contentsOf: aiFile) == aiContents)
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: - Reading back what we published

    /// The export UI shares a bounded slice of the 90 days on disk, so it stays
    /// a share sheet rather than an archive dump. `current_insulin_dosing.json`
    /// always rides along, since that is where anything still in motion lives.
    @Test func theExportOffersTheNewestFewDaysPlusTheCurrentFile() throws {
        let container = try makeContainer()
        let days = ["2026-03-10", "2026-03-11", "2026-03-12", "2026-03-13", "2026-03-14"]
        for day in days {
            container.appendFinalized(line: Data("{}\n".utf8), utcDay: day)
        }
        container.writeCurrentInsulinDosing(Data("{}".utf8))
        // Not ours, and not a day file: passed through, never counted as a day.
        try Data("hello".utf8).write(to: container.writerURL.appendingPathComponent("notes.txt"))

        let names = AiInterfaceContainer.publishedFileURLs(inWriterDirectory: container.writerURL)
            .map { $0.lastPathComponent }

        #expect(names.contains(AiInterfaceContainer.currentInsulinDosingFileName))
        #expect(names.contains("notes.txt"))

        let exported = names.compactMap { AiInterfaceContainer.utcDay(fromFinalizedFileName: $0) }
        #expect(exported == Array(days.suffix(AiInterfaceContainer.exportInDays)))
    }

    /// A device that stopped publishing days ago is exactly the one you'd export
    /// to find out why, so the window follows the newest days that exist rather
    /// than the last few calendar days.
    @Test func theExportFollowsTheNewestDaysThatExistNotTheCalendar() throws {
        let container = try makeContainer()
        container.appendFinalized(line: Data("{}\n".utf8), utcDay: "2020-01-01")
        container.appendFinalized(line: Data("{}\n".utf8), utcDay: "2020-01-02")

        let names = AiInterfaceContainer.publishedFileURLs(inWriterDirectory: container.writerURL)
            .map { $0.lastPathComponent }

        #expect(names.compactMap { AiInterfaceContainer.utcDay(fromFinalizedFileName: $0) } == ["2020-01-01", "2020-01-02"])
    }

    // MARK: - Reading back what the AI apps published

    func aiDirectory(in container: AiInterfaceContainer) -> URL {
        return container.rootURL.appendingPathComponent(AiInterfaceContainer.aiDirectoryName, isDirectory: true)
    }

    @discardableResult
    func writeAiFile(_ name: String, forApp bundleIdentifier: String, in container: AiInterfaceContainer) throws -> URL {
        let directory = aiDirectory(in: container).appendingPathComponent(bundleIdentifier, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data("{\"mealId\":\"m1\"}\n".utf8).write(to: url)
        return url
    }

    @Test func aiFilesAreGroupedByBundleIdentifier() throws {
        let container = try makeContainer()
        try writeAiFile("meal_announcements.2026-03-14.jsonl", forApp: "com.example.other", in: container)
        try writeAiFile("meal_announcements.2026-03-14.jsonl", forApp: "com.example.coach", in: container)
        try writeAiFile("meal_announcements.2026-03-13.jsonl", forApp: "com.example.coach", in: container)

        let apps = AiInterfaceContainer.aiPublishedFiles(inAiDirectory: aiDirectory(in: container))

        #expect(apps.map { $0.bundleIdentifier } == ["com.example.coach", "com.example.other"])
        // Day-stamped names sort chronologically, and the two apps' files are
        // kept apart even though they share a name.
        #expect(apps.first?.urls.map { $0.lastPathComponent } == [
            "meal_announcements.2026-03-13.jsonl",
            "meal_announcements.2026-03-14.jsonl"
        ])
        #expect(apps.last?.urls.count == 1)
    }

    @Test func theExportOffersTheNewestFewDaysPerAiApp() throws {
        let container = try makeContainer()
        let days = ["2026-03-10", "2026-03-11", "2026-03-12", "2026-03-13", "2026-03-14"]
        for day in days {
            try writeAiFile("meal_announcements.\(day).jsonl", forApp: "com.example.coach", in: container)
        }
        try writeAiFile("meal_announcements.2026-03-14.jsonl", forApp: "com.example.other", in: container)
        // Not a day file: passed through, never counted as a day.
        try writeAiFile("notes.txt", forApp: "com.example.coach", in: container)

        let apps = AiInterfaceContainer.aiFilesForExport(inAiDirectory: aiDirectory(in: container))

        let coach = try #require(apps.first { $0.bundleIdentifier == "com.example.coach" })
        #expect(coach.urls.map { $0.lastPathComponent }.contains("notes.txt"))
        #expect(
            coach.urls.compactMap { AiInterfaceContainer.utcDay(fromMealAnnouncementFileName: $0.lastPathComponent) }
            == Array(days.suffix(AiInterfaceContainer.exportInDays))
        )
        // An app with fewer days than the limit is left alone.
        #expect(apps.first { $0.bundleIdentifier == "com.example.other" }?.urls.count == 1)
    }

    /// The export limit is presentation only. The meal banner reads the same
    /// subtree and has to keep seeing any day it asks for, including one the
    /// export trims — the two must not share a window.
    @Test func theExportLimitDoesNotNarrowWhatTheMealBannerCanRead() throws {
        let container = try makeContainer()
        let days = ["2026-03-10", "2026-03-11", "2026-03-12", "2026-03-13", "2026-03-14"]
        for day in days {
            try writeAiFile("meal_announcements.\(day).jsonl", forApp: "com.example.coach", in: container)
        }
        let aiURL = aiDirectory(in: container)

        let exported = AiInterfaceContainer.aiFilesForExport(inAiDirectory: aiURL)
            .flatMap { $0.urls.map { $0.lastPathComponent } }
        #expect(!exported.contains("meal_announcements.2026-03-10.jsonl"))

        let readable = AiInterfaceContainer.mealAnnouncementFiles(inAiDirectory: aiURL, utcDays: ["2026-03-10"])
        #expect(readable.map { $0.url.lastPathComponent } == ["meal_announcements.2026-03-10.jsonl"])
    }

    /// Everything GlucOS publishes stays in its own section of the export UI —
    /// the two listings read from different directories and can't pick up each
    /// other's files.
    @Test func aiFilesAndOurOwnFilesDoNotMix() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        try writeAiFile("meal_announcements.2026-03-14.jsonl", forApp: "com.example.coach", in: container)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [tempBasal(now - 40.minutesToSeconds(), 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )

        let apps = AiInterfaceContainer.aiPublishedFiles(inAiDirectory: aiDirectory(in: container))
        let theirFiles = apps.flatMap { $0.urls.map { $0.lastPathComponent } }
        #expect(theirFiles == ["meal_announcements.2026-03-14.jsonl"])

        let ourFiles = try FileManager.default.contentsOfDirectory(atPath: container.writerURL.path)
        #expect(!ourFiles.contains { $0.hasPrefix("meal_announcements") })
        #expect(ourFiles.contains(AiInterfaceContainer.currentInsulinDosingFileName))
    }

    /// Listing must not create anything: reading the export view is the one time
    /// we look at an AI app's subtree, and conjuring an empty `ai/` directory
    /// there would be a write we have no business making.
    @Test func listingAiFilesCreatesNothing() throws {
        let container = try makeContainer()
        let aiURL = aiDirectory(in: container)

        #expect(AiInterfaceContainer.aiPublishedFiles(inAiDirectory: aiURL).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: aiURL.path))

        // An app that has claimed a directory but written nothing has nothing to
        // export, and a stray file directly in `ai/` belongs to no app.
        try FileManager.default.createDirectory(
            at: aiURL.appendingPathComponent("com.example.coach", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("stray".utf8).write(to: aiURL.appendingPathComponent("notes.txt"))
        #expect(AiInterfaceContainer.aiPublishedFiles(inAiDirectory: aiURL).isEmpty)
    }

    // MARK: - Ids

    @Test func inferredSegmentIdsAreStableAcrossPasses() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]

        // The same scheduled stretch seen at two different times keeps its id,
        // because the id is anchored to the segment's fixed left edge.
        let first = LocalAiInterfaceStorage.buildExport(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 20.minutesToSeconds()
        )
        let second = LocalAiInterfaceStorage.buildExport(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 30.minutesToSeconds()
        )

        #expect(first.current.basal?.id == second.current.basal?.id)
        #expect(first.current.basal?.id == "glucos:basal:\(Int64((t0 + 10.minutesToSeconds()).timeIntervalSince1970 * 1000))")
        // And the end time moved with `now`, which is what readers clamp.
        #expect(second.current.basal?.endTime ?? .distantPast > first.current.basal?.endTime ?? .distantPast)
    }

    @Test func pumpSyncIdentifiersAreNamespacedByPlugin() throws {
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let export = LocalAiInterfaceStorage.buildExport(
            doses: [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "abc123")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump,
            alreadyExported: [], at: t0 + 40.minutesToSeconds()
        )
        #expect(export.newlyFinalized.first?.id == "OmnipodDash:abc123")
    }

    // MARK: - Glucose
    //
    // Simpler than the insulin half in the way the store behind it is simpler: a
    // CGM reading arrives once, immutable, already carrying its own identifier,
    // so there is no current/finalized split and nothing to settle. What is left
    // is the append discipline — one line per reading, ever, in the day file that
    // was current when we wrote it.

    /// Same reader rules as `readFinalized`.
    func readGlucose(_ container: AiInterfaceContainer, day: String) throws -> [GlucoseRecord] {
        let url = container.glucoseURL(forUtcDay: day)
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        _ = lines.popLast()
        return try lines.map { try makeDecoder().decode(GlucoseRecord.self, from: Data($0.utf8)) }
    }

    @Test func glucoseIsPublishedOldestFirstWithTheCgmsOwnId() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let readings = GlucoseFixtures.series(endingAt: now, count: 3, startingAtMgDl: 120)

        let exporter = makeExporter(container: container, box: box)
        // Handed over newest first, so the file's order has to come from the
        // readings rather than from the caller.
        await exporter.exportGlucose(readings: readings.reversed(), at: now)

        let published = try readGlucose(container, day: AiInterfaceContainer.utcDay(for: now))
        #expect(published.map { $0.id } == readings.map { $0.syncIdentifier })
        #expect(published.map { $0.measuredAt } == readings.map { $0.date })
        #expect(published.map { $0.glucoseInMgDl } == [120, 121, 122])
    }

    @Test func glucoseTimestampsAreEpochSecondsAndEveryLineParsesStandalone() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let readings = GlucoseFixtures.series(endingAt: now, count: 2)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportGlucose(readings: readings, at: now)

        let url = container.glucoseURL(forUtcDay: AiInterfaceContainer.utcDay(for: now))
        let text = try #require(String(data: try Data(contentsOf: url), encoding: .utf8))
        #expect(text.hasSuffix("\n"))

        let lines = text.components(separatedBy: "\n").dropLast()
        #expect(lines.count == 2)
        for line in lines {
            let raw = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            // A number counted from 1970, not a string and not a reference date.
            #expect(raw["measuredAt"] as? String == nil)
            #expect(raw["measuredAt"] as? Double ?? 0 > Date.f("2026-01-01 00:00:00 +0000").timeIntervalSince1970)
            // No version key: a missing version implies v=1.
            #expect(raw["version"] == nil)
        }
        let first = try #require(readings.first)
        #expect(try readGlucose(container, day: AiInterfaceContainer.utcDay(for: now)).first?.measuredAt == first.date)
    }

    /// Callers deliberately hand us `inserted` *plus* an overlapping window from
    /// the store, so the same reading arrives twice within one call.
    @Test func aReadingOfferedTwiceInOneBatchIsWrittenOnce() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let readings = GlucoseFixtures.series(endingAt: now, count: 3)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportGlucose(readings: readings + readings, at: now)

        let published = try readGlucose(container, day: AiInterfaceContainer.utcDay(for: now))
        #expect(published.count == 3)
        #expect(Set(published.map { $0.id }).count == 3)
    }

    @Test func republishingTheSameWindowWritesNoDuplicateLines() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let day = AiInterfaceContainer.utcDay(for: now)
        let readings = GlucoseFixtures.series(endingAt: now, count: 3)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportGlucose(readings: readings, at: now)
        let afterFirstPass = try readGlucose(container, day: day)
        #expect(afterFirstPass.count == 3)

        // The next reading arrives and the window comes back with it.
        let next = GlucoseFixtures.reading(id: "cgm-3", at: now + 5.minutesToSeconds(), mgDl: 130)
        await exporter.exportGlucose(readings: readings + [next], at: now + 5.minutesToSeconds())
        #expect(try readGlucose(container, day: day).map { $0.id } == afterFirstPass.map { $0.id } + ["cgm-3"])

        // And a relaunch reads the same ledger rather than starting over.
        let secondLaunch = makeExporter(container: container, box: box)
        await secondLaunch.exportGlucose(readings: readings + [next], at: now + 10.minutesToSeconds())
        #expect(try readGlucose(container, day: day).count == 4)
    }

    @Test func glucoseRecordsLandInTheDayTheyWereAppended() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()

        // Measured at 23:58 on the 14th, appended at 00:01 on the 15th.
        let measuredAt = Date.f("2026-03-14 23:58:00 +0000")
        let now = Date.f("2026-03-15 00:01:00 +0000")

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportGlucose(
            readings: [GlucoseFixtures.reading(id: "cgm-1", at: measuredAt, mgDl: 104)],
            at: now
        )

        let newDay = try readGlucose(container, day: "2026-03-15")
        #expect(newDay.map { $0.measuredAt } == [measuredAt])
        #expect(try readGlucose(container, day: "2026-03-14").isEmpty)
    }

    @Test func glucoseRetentionDeletesOnlyFilesPastNinetyDays() throws {
        let container = try makeContainer()
        let now = Date.f("2026-03-15 12:00:00 +0000")

        let stale = AiInterfaceContainer.utcDay(for: now - 91.0.daysToSeconds())
        let fresh = AiInterfaceContainer.utcDay(for: now - 89.0.daysToSeconds())
        for day in [stale, fresh] {
            #expect(container.appendGlucose(line: Data("{}\n".utf8), utcDay: day))
        }
        // An insulin file of the same age is not this pass's business.
        #expect(container.appendFinalized(line: Data("{}\n".utf8), utcDay: stale))

        #expect(container.pruneGlucoseFiles(at: now) == 1)
        #expect(!FileManager.default.fileExists(atPath: container.glucoseURL(forUtcDay: stale).path))
        #expect(FileManager.default.fileExists(atPath: container.glucoseURL(forUtcDay: fresh).path))
        #expect(FileManager.default.fileExists(atPath: container.finalizedURL(forUtcDay: stale).path))
    }

    /// Retention runs from whichever export gets there first on a given day, so a
    /// device whose pump is off but whose CGM is still reporting keeps pruning.
    @Test func aGlucosePassPrunesBothFamilies() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-15 12:00:00 +0000")
        let stale = AiInterfaceContainer.utcDay(for: now - 91.0.daysToSeconds())
        container.appendGlucose(line: Data("{}\n".utf8), utcDay: stale)
        container.appendFinalized(line: Data("{}\n".utf8), utcDay: stale)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportGlucose(
            readings: [GlucoseFixtures.reading(id: "cgm-1", at: now, mgDl: 100)],
            at: now
        )

        #expect(!FileManager.default.fileExists(atPath: container.glucoseURL(forUtcDay: stale).path))
        #expect(!FileManager.default.fileExists(atPath: container.finalizedURL(forUtcDay: stale).path))
    }

    @Test func resettingClearsGlucoseFilesAndTheirLedgerToo() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")
        let day = AiInterfaceContainer.utcDay(for: now)
        let readings = GlucoseFixtures.series(endingAt: now, count: 3)

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportGlucose(readings: readings, at: now)
        #expect(try readGlucose(container, day: day).count == 3)

        await exporter.resetPublishedData()
        #expect(try readGlucose(container, day: day).isEmpty)
        #expect(container.glucoseDayFiles().isEmpty)

        // Ledger went with the files, so the same readings come back rather than
        // being believed already published.
        await exporter.exportGlucose(readings: readings, at: now + 1.minutesToSeconds())
        #expect(try readGlucose(container, day: day).map { $0.id } == readings.map { $0.syncIdentifier })
    }

    /// The share sheet's limit is per family. Three days of insulin and three days
    /// of glucose, not three files total — and a glucose file must not be able to
    /// push an insulin file out of the list.
    @Test func theExportOffersTheNewestFewDaysOfEachFamily() throws {
        let container = try makeContainer()
        let days = ["2026-03-10", "2026-03-11", "2026-03-12", "2026-03-13", "2026-03-14"]
        for day in days {
            container.appendFinalized(line: Data("{}\n".utf8), utcDay: day)
            container.appendGlucose(line: Data("{}\n".utf8), utcDay: day)
        }
        container.writeCurrentInsulinDosing(Data("{}".utf8))

        let names = AiInterfaceContainer.publishedFileURLs(inWriterDirectory: container.writerURL)
            .map { $0.lastPathComponent }

        let expected = Array(days.suffix(AiInterfaceContainer.exportInDays))
        #expect(names.compactMap { AiInterfaceContainer.utcDay(fromFinalizedFileName: $0) } == expected)
        #expect(names.compactMap { AiInterfaceContainer.utcDay(fromGlucoseFileName: $0) } == expected)
        #expect(names.contains(AiInterfaceContainer.currentInsulinDosingFileName))
    }

    @Test func glucoseDayFileNamesAreParsedAsStrictlyAsInsulinOnes() throws {
        #expect(AiInterfaceContainer.utcDay(fromGlucoseFileName: "glucose.2026-03-15.jsonl") == "2026-03-15")
        #expect(AiInterfaceContainer.utcDay(fromGlucoseFileName: "glucose.latest.jsonl") == nil)
        #expect(AiInterfaceContainer.utcDay(fromGlucoseFileName: "glucose.2026-13-45.jsonl") == nil)
        // The two families never claim each other's files.
        #expect(AiInterfaceContainer.utcDay(fromGlucoseFileName: "finalized_insulin_dosing.2026-03-15.jsonl") == nil)
        #expect(AiInterfaceContainer.utcDay(fromFinalizedFileName: "glucose.2026-03-15.jsonl") == nil)
    }

    // MARK: - The CGM tick marker
    //
    // What an AI app listening in on CGM Bluetooth polls for: it holds a reading
    // and needs to know whether GlucOS has finished reacting to that same
    // reading, since anything it reads before then describes the previous tick.

    @Test func theTickMarkerIsAbsentUntilALoopHasRun() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: [tempBasal(now - 40.minutesToSeconds(), 10.minutesToSeconds(), rate: 1.0, id: "a")],
            scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: now
        )

        #expect(try readCurrent(container).lastCgmTickHandledAt == nil)
        // Absent rather than an explicit null, which readers see the same way.
        let object = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: container.currentInsulinDosingURL)) as? [String: Any]
        )
        #expect(object["lastCgmTickHandledAt"] == nil)
    }

    @Test func aHandledTickIsPublishedWithoutDisturbingTheDosingObject() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [
            tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a"),
            bolus(t0 + 38.minutesToSeconds(), 60, programmed: 1.5, delivered: nil, id: "b1", isMutable: true)
        ]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )
        let beforeTick = try readCurrent(container)

        // The loop dosed on the reading from two minutes ago.
        let cgmReadingAt = t0 + 38.minutesToSeconds()
        await exporter.recordCgmTickHandled(cgmReadingAt: cgmReadingAt, at: t0 + 41.minutesToSeconds())

        let afterTick = try readCurrent(container)
        #expect(afterTick.lastCgmTickHandledAt == cgmReadingAt)
        // This path has seen no pump events, so it carries the dosing half over
        // untouched rather than rebuilding a timeline it doesn't have.
        #expect(afterTick.basal == beforeTick.basal)
        #expect(afterTick.bolus == beforeTick.bolus)

        // And a later pump sync republishes the marker rather than dropping it.
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 45.minutesToSeconds()
        )
        #expect(try readCurrent(container).lastCgmTickHandledAt == cgmReadingAt)
    }

    @Test func anOlderTickCannotMoveTheMarkerBackwards() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]

        let exporter = makeExporter(container: container, box: box)
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )

        let newest = t0 + 38.minutesToSeconds()
        await exporter.recordCgmTickHandled(cgmReadingAt: newest, at: t0 + 41.minutesToSeconds())
        // A backfilled reading the loop ran on afterwards is still older, and an
        // AI app that saw `newest` must not be told to wait for it again.
        await exporter.recordCgmTickHandled(cgmReadingAt: t0 + 33.minutesToSeconds(), at: t0 + 42.minutesToSeconds())

        #expect(try readCurrent(container).lastCgmTickHandledAt == newest)
    }

    @Test func theTickMarkerSurvivesARelaunch() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]

        let firstLaunch = makeExporter(container: container, box: box)
        await firstLaunch.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 40.minutesToSeconds()
        )
        let cgmReadingAt = t0 + 38.minutesToSeconds()
        await firstLaunch.recordCgmTickHandled(cgmReadingAt: cgmReadingAt, at: t0 + 41.minutesToSeconds())

        // A reader that saw the marker before the relaunch must not see it vanish:
        // that is indistinguishable from GlucOS going back to an older reading.
        let secondLaunch = makeExporter(container: container, box: box)
        await secondLaunch.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: t0 + 50.minutesToSeconds()
        )
        #expect(try readCurrent(container).lastCgmTickHandledAt == cgmReadingAt)
    }

    /// The loop stamps its `at` before it spends seconds talking to the pump, so
    /// the tick write that follows an export can carry an earlier instant than the
    /// export did. `updatedAt` is what readers use to tell idle from dead, so it
    /// has to be non-decreasing whichever order the two arrive in.
    @Test func updatedAtNeverMovesBackwards() async throws {
        let container = try makeContainer()
        let box = InMemoryStoredObject.Box()
        let t0 = Date.f("2026-03-14 12:00:00 +0000")
        let doses = [tempBasal(t0, 10.minutesToSeconds(), rate: 1.0, id: "a")]

        let exporter = makeExporter(container: container, box: box)
        let exportedAt = t0 + 40.minutesToSeconds()
        await exporter.exportInsulinDosing(
            doses: doses, scheduledBasalRateUnitsPerHour: scheduledRate, pump: pump, at: exportedAt
        )

        await exporter.recordCgmTickHandled(
            cgmReadingAt: t0 + 38.minutesToSeconds(),
            at: exportedAt - 5 // the loop started before the export it triggered
        )

        let current = try readCurrent(container)
        #expect(current.updatedAt == exportedAt.timeIntervalSince1970)
        // The marker still lands, which is the point of the write.
        #expect(current.lastCgmTickHandledAt == t0 + 38.minutesToSeconds())
    }

    @Test func aMissingAppGroupDegradesToANoOpForGlucoseAndTicksToo() async throws {
        let box = InMemoryStoredObject.Box()
        let now = Date.f("2026-03-14 12:00:00 +0000")

        let exporter = LocalAiInterfaceStorage(container: nil, stateStorage: InMemoryStoredObject(box: box))
        await exporter.exportGlucose(
            readings: [GlucoseFixtures.reading(id: "cgm-1", at: now, mgDl: 100)],
            at: now
        )
        await exporter.recordCgmTickHandled(cgmReadingAt: now, at: now)

        #expect(box.data == nil)
    }
}
