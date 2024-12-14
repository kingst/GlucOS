//
//  InsulinPersistantStorageTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import XCTest
import LoopKit
@testable import BioKernel

final class InsulinPersistantStorageTests: XCTestCase {
    let iobAccuracy = 0.00000000001
    
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

    func testWithoutFiltering() async throws {
        let events = ReplayLogs.immutableReplayLogs(for: type(of: self))
        let at = events.last!.dose!.endDate
        
        let storage = LocalInsulinStorage()
        let originalIob = await storage.insulinOnBoard(events: events, at: at)
        
        let _ = await storage.addPumpEvents(events, lastReconciliation: at, insulinType: .lyumjev)
        let newIob = await storage.insulinOnBoard(at: at)
        
        XCTAssertEqual(newIob, originalIob, accuracy: iobAccuracy)
    }
    
    func testWithFiltering() async throws {
        let events = ReplayLogs.fullReplayLogs(for: type(of: self))
        let at = events.last!.dose!.endDate
        
        let storage = LocalInsulinStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)
        let originalIob = await storage.insulinOnBoard(events: events, at: at)
        
        let _ = await storage.addPumpEvents(events, lastReconciliation: at, insulinType: .lyumjev)
        let newIob = await storage.insulinOnBoard(at: at)
        
        XCTAssertEqual(newIob, originalIob, accuracy: iobAccuracy)
    }
}
