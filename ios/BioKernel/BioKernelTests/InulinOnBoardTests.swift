//
//  BioKernelTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/9/23.
//

import XCTest
import LoopKit

@testable import BioKernel

final class InulinOnBoardTests: XCTestCase {

    struct TestingTime {
        let offset: TimeInterval
        let result: Double
    }

    // See the InsulinTesting Playground in this workspace to see the script to generate these
    // two iob reference values
    let iobTimeReferences: [TestingTime] = [
        TestingTime(offset: 30.minutesToSeconds(), result: 0.9659746550047483),
        TestingTime(offset: 60.minutesToSeconds(), result: 0.8337993409625033),
        TestingTime(offset: 90.minutesToSeconds(), result: 0.6657177108987371),
        TestingTime(offset: 120.minutesToSeconds(), result: 0.5005768165495502),
        TestingTime(offset: 150.minutesToSeconds(), result: 0.35669204409321253),
        TestingTime(offset: 180.minutesToSeconds(), result: 0.24057361580865244)
    ]
    
    // the last item is because the basal interval is 19 minutes, so the last
    // five minute segment is only four minutes, which reduces the result by
    // 80 percent (basal for only 4 minutes not the full 5)
    let iobShortTimeReferences: [TestingTime] = [
        TestingTime(offset: 90.minutesToSeconds(), result: 0.6657177108987371),
        TestingTime(offset: 85.minutesToSeconds(), result: 0.6942633437181707),
        TestingTime(offset: 80.minutesToSeconds(), result: 0.7228075911918497),
        TestingTime(offset: 75.minutesToSeconds(), result: 0.7512060072038422 * 0.8),
    ]
    
    let iobAccuracy = 0.00000000001
    
    override func setUpWithError() throws {
        Dependency.useMockConstructors = true
    }

    override func tearDownWithError() throws {
        Dependency.resetMocks()
        Dependency.useMockConstructors = false
    }
    
    func testBolusDoseEntry() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let dose = DoseEntry(type: .bolus, startDate: startDate, endDate: startDate + 2.minutesToSeconds(), value: 1.0, unit: .units, deliveredUnits: 1.0, insulinType: .humalog, isMutable: false)

        for test in iobTimeReferences {
            let time = test.offset
            let iob = dose.insulinOnBoard(at: startDate + time)
            XCTAssertEqual(iob, test.result, accuracy: iobAccuracy)
        }

    }

    func testFiveMinuteBasal() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let dose = DoseEntry(type: .basal, startDate: startDate, endDate: startDate + 5.minutesToSeconds(), value: 12.0, unit: .unitsPerHour, deliveredUnits: 1.0, insulinType: .humalog, isMutable: false)

        for test in iobTimeReferences {
            let time = test.offset
            let iob = dose.insulinOnBoard(at: startDate + time)
            XCTAssertEqual(iob, test.result, accuracy: iobAccuracy)
        }
        
        let dose2 = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 5.minutesToSeconds(), value: 12.0, unit: .unitsPerHour, deliveredUnits: 1.0, insulinType: .humalog, isMutable: false)

        for test in iobTimeReferences {
            let time = test.offset
            let iob = dose2.insulinOnBoard(at: startDate + time)
            XCTAssertEqual(iob, test.result, accuracy: iobAccuracy)
        }
    }
    
    func testLongerBasal() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        // make sure that we test out clipping the last increment to 4 minutes
        let dose = DoseEntry(type: .basal, startDate: startDate, endDate: startDate + 19.minutesToSeconds(), value: 12.0, unit: .unitsPerHour, deliveredUnits: 3.8, insulinType: .humalog, isMutable: false)

        let time = 90.minutesToSeconds()
        let iob = dose.insulinOnBoard(at: startDate + time)
        
        // iobShortTimeReferences includes all of the iob values for each of the
        // four segments in the 19 minute span, so just sum them all up
        let refIob = iobShortTimeReferences.map({ $0.result }).reduce(0) { $1 + $0 }
        XCTAssertEqual(iob, refIob, accuracy: iobAccuracy)
    }
    
    func testCornerCases() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        // test the case where endDate < startDate, we should still return the full dose
        // amount in this case
        let dose = DoseEntry(type: .bolus, startDate: startDate, endDate: startDate - 2.minutesToSeconds(), value: 1.0, unit: .units, deliveredUnits: 1.0, insulinType: .humalog, isMutable: false)
        for test in iobTimeReferences {
            let time = test.offset
            let iob = dose.insulinOnBoard(at: startDate + time)
            XCTAssertEqual(iob, test.result, accuracy: iobAccuracy)
        }
        
        // iob before the entry's start date should be 0
        let time = startDate - 10.minutesToSeconds()
        let iob = dose.insulinOnBoard(at: time)
        XCTAssertEqual(iob, 0.0, accuracy: iobAccuracy)
    }
    
    // because of the way we quantize our doses we'll get
    // five minutes worth of insulin delivered at the beginning
    // of a five minute segment
    func testTempBasal() {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        
        // first make sure that the iob is correct 4 minutes out
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 30.minutesToSeconds(), value: 12.0, unit: .unitsPerHour, insulinType: .humalog, isMutable: true)
        let at = startDate + 4.minutesToSeconds()
        let iobAtFiveMinutes = dose.insulinOnBoard(at: at)
        XCTAssertEqual(iobAtFiveMinutes, 1.0, accuracy: iobAccuracy)
        
        // now do the same but for only 1 minute out
        let atOneMinute = startDate + 1.minutesToSeconds()
        let iobAtOneMinute = dose.insulinOnBoard(at: atOneMinute)
        XCTAssertEqual(iobAtOneMinute, 1.0, accuracy: iobAccuracy)
        
        // and for seven minutes to make sure that we get two segments
        let atSevenMinutes = startDate + 7.minutesToSeconds()
        let iobAtSevenMinutes = dose.insulinOnBoard(at: atSevenMinutes)
        XCTAssertEqual(iobAtSevenMinutes, 2.0, accuracy: iobAccuracy)
    }
    
    // Insulin doesn't start absorbing for 10 minutes
    // according to our models, so we can use this to
    // make sure that our IoB and insulin delivered
    // algorithms match
    func testIoBAndUnitsDeliveredEquivalenceBolus() {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let dose = DoseEntry(type: .bolus, startDate: startDate, endDate: startDate + 2.minutesToSeconds(), value: 1.0, unit: .units, deliveredUnits: 1.0, insulinType: .humalog, isMutable: false)

        for time in stride(from: 1.0, to: 9.0, by: 1.0) {
            let iob = dose.insulinOnBoard(at: startDate + time.minutesToSeconds())
            let insulinDelivered = dose.insulinDeliveredBetween(startDate: startDate, endDate: startDate + time.minutesToSeconds())
            XCTAssertEqual(iob, insulinDelivered, accuracy: iobAccuracy)
        }
    }
    
    func testIoBAndUnitsDeliveredEquivalenceBasal() {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: startDate + 30.minutesToSeconds(), value: 12.0, unit: .unitsPerHour, insulinType: .humalog, isMutable: false)

        for time in stride(from: 1.0, to: 9.0, by: 1.0) {
            let iob = dose.insulinOnBoard(at: startDate + time.minutesToSeconds())
            let insulinDelivered = dose.insulinDeliveredBetween(startDate: startDate, endDate: startDate + time.minutesToSeconds())
            XCTAssertEqual(iob, insulinDelivered, accuracy: iobAccuracy)
        }
    }
}
