//
//  InsulinPersistentStorageTests.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import Testing
import Foundation
import LoopKit
@testable import BioKernel

struct InsulinPersistentStorageTests {
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

    @Test func withoutFiltering() async throws {
        let events = ReplayLogs.immutableReplayLogs()
        let lastDose = try #require(events.last?.dose)
        let at = lastDose.endDate

        let storage = await makeStorage()
        let originalIob = await storage.insulinOnBoard(events: events, at: at)

        let _ = await storage.addPumpEvents(events, lastReconciliation: at, insulinType: .lyumjev)
        let newIob = await storage.insulinOnBoard(at: at)

        #expect(abs(newIob - originalIob) <= iobAccuracy)
    }

    @Test func withFiltering() async throws {
        let events = ReplayLogs.fullReplayLogs()
        let lastDose = try #require(events.last?.dose)
        let at = lastDose.endDate

        let storage = await makeStorage()
        await storage.setPumpRecordsBasalProfileStartEvents(false)
        let originalIob = await storage.insulinOnBoard(events: events, at: at)

        let _ = await storage.addPumpEvents(events, lastReconciliation: at, insulinType: .lyumjev)
        let newIob = await storage.insulinOnBoard(at: at)

        #expect(abs(newIob - originalIob) <= iobAccuracy)
    }
}
