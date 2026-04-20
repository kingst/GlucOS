//
//  InsulinStorageTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/20/23.
//
//  Overall we want to test:
//    - A standard set of Pump Events
//      - A set of immutable events with temp basal currently running
//      - A set of immutable events with a bolus currently running
//    - Cases where we have to fill in the standard basal rate
//      - A basal event in the past
//      - A basal event currently running

import Testing
import Foundation
import LoopKit

@testable import BioKernel

struct InsulinStorageTests {
    let iobAccuracy = 0.00000000001
    // generated offline manually
    let lyumjevAtOneUnitPerHourForOneHour = 0.90988675478661

    @MainActor private func makeStorage() -> LocalInsulinStorage {
        let settings = MockSettingsStorage()
        return LocalInsulinStorage(
            storedObjectFactory: MockStoredObject.self,
            healthKitStorage: MockHealthKitStore(),
            watchComms: { MockWatchComms() },
            settingsStorage: { settings }
        )
    }

    @Test func basalAtEnd() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 30.minutesToSeconds(), value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.5, insulinType: .lyumjev, isMutable: false)

        let at = startDate + 60.minutesToSeconds()
        let storage = await makeStorage()
        let iobBasal = await storage.inferBasalDoses(doses: [dose], at: at).map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        let iobTempBasal = dose.insulinOnBoard(at: at)
        let iob = iobBasal + iobTempBasal

        #expect(abs(iob - lyumjevAtOneUnitPerHourForOneHour) <= iobAccuracy)
    }

    @Test func basalInMiddle() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")

        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 30.minutesToSeconds(), value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.5, insulinType: .lyumjev, isMutable: false)
        let dose2 = DoseEntry(type: .tempBasal, startDate: startDate + 45.minutesToSeconds(), endDate: startDate + 60.minutesToSeconds(), value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.25, insulinType: .lyumjev, isMutable: false)

        let at = startDate + 60.minutesToSeconds()
        let storage = await makeStorage()
        let iobBasal = await storage.inferBasalDoses(doses: [dose, dose2], at: at).map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        let iobTempBasal = dose.insulinOnBoard(at: at) + dose2.insulinOnBoard(at: at)
        let iob = iobBasal + iobTempBasal

        #expect(abs(iob - lyumjevAtOneUnitPerHourForOneHour) <= iobAccuracy)
    }

    @Test func newPumpEvents() async throws {
        let startDate = Date.f("2023-11-19 23:13:05 +0000")
        let at = Date.f("2023-11-20 01:00:30 +0000")
        let pumpEvents = ReplayLogs.immutableReplayLogs()
        var iob = 0.0
        for event in pumpEvents {
            let dose = try #require(event.dose)
            iob += dose.insulinOnBoard(at: at)
        }

        // make sure to account for the implicit basal at the beginning
        let implicitBasal = DoseEntry(type: .basal, startDate: startDate, endDate: Date.f("2023-11-19 23:23:31 +0000"), value: 1.0, unit: .unitsPerHour, insulinType: .lyumjev, isMutable: false)
        iob += implicitBasal.insulinOnBoard(at: at)

        let storage = await makeStorage()
        let totalIob = await storage.insulinOnBoard(events: pumpEvents, at: at)

        #expect(abs(iob - totalIob) <= iobAccuracy)
    }

    @Test func mutableAfterImmutable() async throws {
        let events: [NewPumpEvent] = ReplayLogs.replayLogs(forResource: "filter_bug", ofType: "json")
        let lastDose = try #require(events.last?.dose)
        let at = lastDose.endDate

        let storage = await makeStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)
        let iob = await storage.insulinOnBoard(events: events, at: at)

        #expect(abs(iob) <= iobAccuracy)
    }

    @Test func insulinDelivered() async throws {
        let startDate = Date.f("2023-11-19 23:13:05 +0000")
        let endDate = Date.f("2023-11-20 00:30:42 +0000")
        let pumpEvents = ReplayLogs.immutableReplayLogs()

        // manually calculated from the logs
        // make sure to account for the implicit basal at the beginning
        let implicitBasal = DoseEntry(type: .basal, startDate: startDate, endDate: Date.f("2023-11-19 23:23:31 +0000"), value: 1.0, unit: .unitsPerHour, insulinType: .lyumjev, isMutable: false)
        let implicitBasalUnits = implicitBasal.deliveredUnits ?? implicitBasal.programmedUnits
        let insulinDelivered = 0.45 + 0.35 + 1.25 + 0.45 + implicitBasalUnits

        let storage = await makeStorage()
        let calculatedInsulinDelivered = await storage.insulinDelivered(events: pumpEvents, startDate: startDate, endDate: endDate)

        #expect(abs(insulinDelivered - calculatedInsulinDelivered) <= iobAccuracy)
    }

    @Test func insulinDeliveredPartialBasal() async throws {
        let startDate = Date.f("2023-11-19 23:13:05 +0000")
        // remove the last 1 minute from the tempBasal that ends at 00:30:42
        let endDate = Date.f("2023-11-20 00:29:42 +0000")
        let pumpEvents = ReplayLogs.immutableReplayLogs()

        // manually calculated from the logs
        // make sure to account for the implicit basal at the beginning
        let implicitBasal = DoseEntry(type: .basal, startDate: startDate, endDate: Date.f("2023-11-19 23:23:31 +0000"), value: 1.0, unit: .unitsPerHour, insulinType: .lyumjev, isMutable: false)
        let implicitBasalUnits = implicitBasal.deliveredUnits ?? implicitBasal.programmedUnits

        // because of the way we quantize insulin delivery
        // we'll still get the full amount of the last basal
        //let lastBasal = 0.45 * (1404.0 - 60.0) / 1404.0
        let lastBasal = 0.45
        let insulinDelivered = 0.45 + 0.35 + 1.25 + lastBasal + implicitBasalUnits

        let storage = await makeStorage()
        let calculatedInsulinDelivered = await storage.insulinDelivered(events: pumpEvents, startDate: startDate, endDate: endDate)

        #expect(abs(insulinDelivered - calculatedInsulinDelivered) <= iobAccuracy)
    }

    func omnipodIoBCalculation(storage: LocalInsulinStorage, doses: [DoseEntry], at: Date) async -> (Double, Double) {
        let iob = doses.map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        let basalDoses = await storage.inferBasalDoses(doses: doses, at: at)
        let basalIob = basalDoses.map({ $0.insulinOnBoard(at: at) }).reduce(0, +)

        return (iob, basalIob)
    }

    @Test func ioBAfterSuspend() async throws {
        let doses = ReplayLogs.iobBugLogs()
        let atSuspend = Date(timeIntervalSince1970: 1714517892.726407)
        let atResume = Date(timeIntervalSince1970: 1714531049.1750169)
        let storage = await makeStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)

        let iobSuspend = await omnipodIoBCalculation(storage: storage, doses: doses, at: atSuspend)
        let iobResume = await omnipodIoBCalculation(storage: storage, doses: doses, at: atResume)

        // make sure that iob is going down while the pump is suspended
        #expect(iobSuspend.0 > iobResume.0)

        // make sure that there isn't any basal insulin inferred while
        // the pump is suspended
        #expect(iobResume.1 < .ulpOfOne)
    }
}
