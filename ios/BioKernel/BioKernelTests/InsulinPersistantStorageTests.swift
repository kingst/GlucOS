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

    @MainActor private func makeStorage() -> LocalInsulinStorage {
        let settings = MockSettingsStorage()
        return LocalInsulinStorage(
            storedObjectFactory: MockStoredObject.self,
            healthKitStorage: MockHealthKitStore(),
            watchComms: { MockWatchComms() },
            settingsStorage: { settings }
        )
    }

    func testWithoutFiltering() async throws {
        let events = ReplayLogs.immutableReplayLogs(for: type(of: self))
        let at = events.last!.dose!.endDate

        let storage = await makeStorage()
        let originalIob = await storage.insulinOnBoard(events: events, at: at)

        let _ = await storage.addPumpEvents(events, lastReconciliation: at, insulinType: .lyumjev)
        let newIob = await storage.insulinOnBoard(at: at)

        XCTAssertEqual(newIob, originalIob, accuracy: iobAccuracy)
    }

    func testWithFiltering() async throws {
        let events = ReplayLogs.fullReplayLogs(for: type(of: self))
        let at = events.last!.dose!.endDate

        let storage = await makeStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)
        let originalIob = await storage.insulinOnBoard(events: events, at: at)

        let _ = await storage.addPumpEvents(events, lastReconciliation: at, insulinType: .lyumjev)
        let newIob = await storage.insulinOnBoard(at: at)

        XCTAssertEqual(newIob, originalIob, accuracy: iobAccuracy)
    }
}
