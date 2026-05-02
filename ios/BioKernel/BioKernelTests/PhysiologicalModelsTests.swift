//
//  PhysiologicalModelsTests.swift
//  BioKernelTests
//

import Testing
import Foundation
import LoopKit
@testable import BioKernel

@MainActor
@Suite(.serialized)
struct PhysiologicalModelsTests {
    let now = Date.f("2024-01-15 10:30:00 +0000")
    let settings: MockSettingsStorage

    init() {
        InMemoryStoredObject.reset()
        settings = MockSettingsStorage()
    }

    @Test func coldStartHasNoPriorGlucose() async throws {
        let physModels = LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )

        let result = await physModels.tempBasal(
            settings: settings.snapshot(),
            glucoseInMgDl: 120,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: now
        )

        #expect(result.lastGlucose == nil)
        #expect(result.lastGlucoseAt == nil)
        #expect(result.derivative == 0.0)
        #expect(result.accumulatedError == 0.0)
    }

    @Test func tempBasalPersistsStateToStorage() async throws {
        let physModels = LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )

        _ = await physModels.tempBasal(
            settings: settings.snapshot(),
            glucoseInMgDl: 120,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: now
        )

        let persisted: PIDState? = try InMemoryStoredObject.read(fileName: "pid_state.json")
        #expect(persisted != nil)
        #expect(persisted?.savedAt == now)
        #expect(persisted?.lastGlucose == 120)
        #expect(persisted?.lastGlucoseAt == now)
        #expect(persisted?.accumulatedError == 0.0)
        // lowPassFilter returns the raw value on cold start
        #expect(persisted?.lastFilteredGlucose == 120)
    }

    @Test func newInstanceRestoresPriorPidState() async throws {
        // First "boot" runs once and persists to the shared in-memory storage.
        let firstBoot = LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )
        _ = await firstBoot.tempBasal(
            settings: settings.snapshot(),
            glucoseInMgDl: 120,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: now
        )

        // Second "boot" — fresh actor sharing the same storage.
        let secondBoot = LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )
        let nextReadingAt = now + 5.minutesToSeconds()
        let result = await secondBoot.tempBasal(
            settings: settings.snapshot(),
            glucoseInMgDl: 130,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: nextReadingAt
        )

        // Result reports the *prior* glucose (the one persisted from the first boot).
        #expect(result.lastGlucose == 120)
        #expect(result.lastGlucoseAt == now)
        // 5-minute gap is inside the 11-minute dt guard, so derivative is non-zero.
        #expect(result.derivative != 0.0)
    }

    @Test func staleRestoredStateResetsToDefaults() async throws {
        // Pre-seed storage with state savedAt 30 minutes ago — past the 23-min
        // staleness threshold. The next tempBasal call should reset the
        // controller to defaults rather than resume from the stale snapshot.
        let staleAt = now - 30.minutesToSeconds()
        let stale = PIDState(
            savedAt: staleAt,
            lastGlucose: 110,
            lastGlucoseAt: staleAt,
            accumulatedError: 50,
            lastFilteredGlucose: 110
        )
        try InMemoryStoredObject.write(stale, fileName: "pid_state.json")

        let physModels = LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )

        let result = await physModels.tempBasal(
            settings: settings.snapshot(),
            glucoseInMgDl: 130,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: now
        )

        // Stale state was wiped before the call ran ⇒ behaves like cold start.
        #expect(result.lastGlucose == nil)
        #expect(result.lastGlucoseAt == nil)
        #expect(result.accumulatedError == 0.0)
        #expect(result.derivative == 0.0)
    }

    @Test func freshRestoredStateIsKept() async throws {
        // savedAt 22 minutes ago — just inside the 23-min staleness threshold.
        // State should survive the restore. The 11-min `dt` guard still skips
        // derivative/integrator updates on this single call, but the prior
        // values themselves stay intact.
        let savedAt = now - 22.minutesToSeconds()
        let fresh = PIDState(
            savedAt: savedAt,
            lastGlucose: 110,
            lastGlucoseAt: savedAt,
            accumulatedError: 50,
            lastFilteredGlucose: 110
        )
        try InMemoryStoredObject.write(fresh, fileName: "pid_state.json")

        let physModels = LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )

        let result = await physModels.tempBasal(
            settings: settings.snapshot(),
            glucoseInMgDl: 130,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: now
        )

        #expect(result.lastGlucose == 110)
        #expect(result.lastGlucoseAt == savedAt)
        #expect(result.accumulatedError == 50)
        #expect(result.derivative == 0.0)
    }
}

// MARK: - In-memory persisting StoredObject for tests

/// Test double for `StoredObject` whose backing storage is shared across all
/// instances with the same fileName. Lets a test simulate "app restart" by
/// constructing a fresh actor with the same factory type and seeing the prior
/// writes.
final class InMemoryStoredObject: StoredObject {
    nonisolated(unsafe) private static var blobs: [String: Data] = [:]
    private let fileName: String

    private init(fileName: String) {
        self.fileName = fileName
    }

    static func create(fileName: String) -> BioKernel.StoredObject {
        return InMemoryStoredObject(fileName: fileName)
    }

    static func reset() {
        blobs.removeAll()
    }

    static func read<T: Decodable>(fileName: String) throws -> T? {
        guard let data = blobs[fileName] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ object: T, fileName: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        blobs[fileName] = try encoder.encode(object)
    }

    func read<T>() throws -> T? where T : Decodable {
        return try Self.read(fileName: fileName)
    }

    func write<T>(_ object: T) throws where T : Encodable {
        try Self.write(object, fileName: fileName)
    }
}
