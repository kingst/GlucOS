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

import XCTest
import LoopKit

@testable import BioKernel

final class InsulinStorageTests: XCTestCase {
    let iobAccuracy = 0.00000000001
    let lyumjevAtOneUnitPerHourForOneHour = 0.9098867547866101
    
    @MainActor override func setUpWithError() throws {
        Dependency.useMockConstructors = true
        let settings = MockSettingsStorage()
        Dependency.mock { settings as SettingsStorage }
        Dependency.mock { MockStoredObject.self as StoredObject.Type }
        Dependency.mock { MockReplayLogger() as EventLogger }
        Dependency.mock { MockWatchComms() as WatchComms }
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }
    
    func testBasalAtEnd() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 30.minutesToSeconds(), value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.5, insulinType: .lyumjev, isMutable: false)
        
        let at = startDate + 60.minutesToSeconds()
        let storage = LocalInsulinStorage()
        let iobBasal = await storage.inferBasalDoses(doses: [dose], at: at).map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        let iobTempBasal = dose.insulinOnBoard(at: at)
        let iob = iobBasal + iobTempBasal
        
        XCTAssertEqual(iob, lyumjevAtOneUnitPerHourForOneHour, accuracy: iobAccuracy)
    }
    
    func testBasalInMiddle() async throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 30.minutesToSeconds(), value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.5, insulinType: .lyumjev, isMutable: false)
        let dose2 = DoseEntry(type: .tempBasal, startDate: startDate + 45.minutesToSeconds(), endDate: startDate + 60.minutesToSeconds(), value: 1.0, unit: .unitsPerHour, deliveredUnits: 0.25, insulinType: .lyumjev, isMutable: false)
        
        let at = startDate + 60.minutesToSeconds()
        let storage = LocalInsulinStorage()
        //let iobBasal = await storage.inferredBasalInsulinOnBoard(insulinType: .lyumjev, doses: [dose, dose2], at: at)
        let iobBasal = await storage.inferBasalDoses(doses: [dose, dose2], at: at).map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        let iobTempBasal = dose.insulinOnBoard(at: at) + dose2.insulinOnBoard(at: at)
        let iob = iobBasal + iobTempBasal
        
        XCTAssertEqual(iob, lyumjevAtOneUnitPerHourForOneHour, accuracy: iobAccuracy)
    }
 
    func testNewPumpEvents() async throws {
        let startDate = Date.f("2023-11-19 23:13:05 +0000")
        let at = Date.f("2023-11-20 01:00:30 +0000")
        let pumpEvents = ReplayLogs.immutableReplayLogs(for: type(of: self))
        var iob = 0.0
        for event in pumpEvents {
            iob += event.dose!.insulinOnBoard(at: at)
        }
        
        // make sure to account for the implicit basal at the beginning
        let implicitBasal = DoseEntry(type: .basal, startDate: startDate, endDate: Date.f("2023-11-19 23:23:31 +0000"), value: 1.0, unit: .unitsPerHour, insulinType: .lyumjev, isMutable: false)
        iob += implicitBasal.insulinOnBoard(at: at)
        
        let storage = LocalInsulinStorage()
        let totalIob = await storage.insulinOnBoard(events: pumpEvents, at: at)
        
        XCTAssertEqual(iob, totalIob, accuracy: iobAccuracy)
    }
    
    func testMutableAfterImmutable() async throws {
        let events: [NewPumpEvent] = ReplayLogs.replayLogs(for: type(of: self), forResource: "filter_bug", ofType: "json")
        let at = events.last!.dose!.endDate
        
        let storage = LocalInsulinStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)
        let iob = await storage.insulinOnBoard(events: events, at: at)
        
        XCTAssertEqual(iob, 0.0, accuracy: iobAccuracy)
    }
    
    func testInsulinDelivered() async throws {
        let startDate = Date.f("2023-11-19 23:13:05 +0000")
        let endDate = Date.f("2023-11-20 00:30:42 +0000")
        let pumpEvents = ReplayLogs.immutableReplayLogs(for: type(of: self))
        
        // manually calculated from the logs
        // make sure to account for the implicit basal at the beginning
        let implicitBasal = DoseEntry(type: .basal, startDate: startDate, endDate: Date.f("2023-11-19 23:23:31 +0000"), value: 1.0, unit: .unitsPerHour, insulinType: .lyumjev, isMutable: false)
        let implicitBasalUnits = implicitBasal.deliveredUnits ?? implicitBasal.programmedUnits
        let insulinDelivered = 0.45 + 0.35 + 1.25 + 0.45 + implicitBasalUnits
        
        let storage = LocalInsulinStorage()
        let calculatedInsulinDelivered = await storage.insulinDelivered(events: pumpEvents, startDate: startDate, endDate: endDate)
        
        XCTAssertEqual(insulinDelivered, calculatedInsulinDelivered, accuracy: iobAccuracy)
    }
    
    func testInsulinDeliveredPartialBasal() async throws {
        let startDate = Date.f("2023-11-19 23:13:05 +0000")
        // remove the last 1 minute from the tempBasal that ends at 00:30:42
        let endDate = Date.f("2023-11-20 00:29:42 +0000")
        let pumpEvents = ReplayLogs.immutableReplayLogs(for: type(of: self))
        
        // manually calculated from the logs
        // make sure to account for the implicit basal at the beginning
        let implicitBasal = DoseEntry(type: .basal, startDate: startDate, endDate: Date.f("2023-11-19 23:23:31 +0000"), value: 1.0, unit: .unitsPerHour, insulinType: .lyumjev, isMutable: false)
        let implicitBasalUnits = implicitBasal.deliveredUnits ?? implicitBasal.programmedUnits
        
        // because of the way we quantize insulin delivery
        // we'll still get the full amount of the last basal
        //let lastBasal = 0.45 * (1404.0 - 60.0) / 1404.0
        let lastBasal = 0.45
        let insulinDelivered = 0.45 + 0.35 + 1.25 + lastBasal + implicitBasalUnits
        
        let storage = LocalInsulinStorage()
        let calculatedInsulinDelivered = await storage.insulinDelivered(events: pumpEvents, startDate: startDate, endDate: endDate)
        
        XCTAssertEqual(insulinDelivered, calculatedInsulinDelivered, accuracy: iobAccuracy)
    }
    
    func omnipodIoBCalculation(storage: LocalInsulinStorage, doses: [DoseEntry], at: Date) async -> (Double, Double) {
        let iob = doses.map({ $0.insulinOnBoard(at: at) }).reduce(0, +)
        let basalDoses = await storage.inferBasalDoses(doses: doses, at: at)
        let basalIob = basalDoses.map({ $0.insulinOnBoard(at: at) }).reduce(0, +)

        return (iob, basalIob)
    }
    
    func testIoBAfterSuspend() async throws {
        let doses = ReplayLogs.iobBugLogs(for: type(of: self))
        let atSuspend = Date(timeIntervalSince1970: 1714517892.726407)
        let atResume = Date(timeIntervalSince1970: 1714531049.1750169)
        let storage = LocalInsulinStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)

        let iobSuspend = await omnipodIoBCalculation(storage: storage, doses: doses, at: atSuspend)
        let iobResume = await omnipodIoBCalculation(storage: storage, doses: doses, at: atResume)
        
        // make sure that iob is going down while the pump is suspended
        XCTAssert(iobSuspend.0 > iobResume.0)
        
        // make sure that there isn't any basal insulin inferred while
        // the pump is suspended
        XCTAssert(iobResume.1 < .ulpOfOne)
    }
}
