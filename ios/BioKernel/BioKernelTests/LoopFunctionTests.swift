//
//  LoopFunctionTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/31/24.
//

import Testing
import Foundation
import LoopKit
import HealthKit
import MockKit
import G7SensorKit
@testable import BioKernel

@MainActor
struct LoopFunctionTests {
    let tempBasalAccuracy = 0.00000000001

    var closedLoop: LoopRunner
    let settings: MockSettingsStorage
    let glucoseStorage: MockGlucoseStorage
    let insulinStorage: MockInsulinStorage
    let deviceManager: MockDeviceDataManager
    let pumpManager: MockPumpManager
    let pumpManagerDelegate: MockPumpManagerDelegate
    let now = Date.f("2024-01-15 10:30:00 +0000")

    init() {
        let settings = MockSettingsStorage()
        let glucoseStorage = MockGlucoseStorage()
        let insulinStorage = MockInsulinStorage()
        let deviceManager = MockDeviceDataManager()
        let pumpManager = MockPumpManager()
        let pumpManagerDelegate = MockPumpManagerDelegate()
        deviceManager.mockPumpManager = pumpManager
        pumpManager.pumpManagerDelegate = pumpManagerDelegate

        let closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage
        )

        self.settings = settings
        self.glucoseStorage = glucoseStorage
        self.insulinStorage = insulinStorage
        self.deviceManager = deviceManager
        self.pumpManager = pumpManager
        self.pumpManagerDelegate = pumpManagerDelegate
        self.closedLoop = closedLoop
    }

    // MARK: - Basic Loop State Tests

    @Test func loopWithClosedLoopDisabled() async throws {
        // Setup
        settings.closedLoopEnabled = false

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false when closed loop is disabled")
        let lastResult = await closedLoop.latestLoopRecord()
        #expect(lastResult?.outcome.skipReason == .openLoop, "Should skip with openLoop when closed loop is disabled")
    }

    @Test func loopWithStaleGlucoseData() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60 // 10 minutes

        // Add stale glucose reading (15 minutes old)
        let staleGlucoseDate = now.addingTimeInterval(-15 * 60)
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            date: staleGlucoseDate
        )

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false with stale glucose data")
        let lastResult = await closedLoop.latestLoopRecord()
        #expect(lastResult?.outcome.skipReason == .glucoseReadingStale, "Should skip with glucoseReadingStale")
    }

    @Test func loopWithStalePumpData() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60 // 10 minutes

        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            date: now.addingTimeInterval(-5 * 60)
        )

        // Set stale pump sync time
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-15 * 60)

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false with stale pump data")
        let lastResult = await closedLoop.latestLoopRecord()
        #expect(lastResult?.outcome.skipReason == .pumpReadingStale, "Should skip with pumpReadingStale")
    }

    @Test func loopWithNoPumpManager() async throws {
        // Setup
        settings.closedLoopEnabled = true
        deviceManager.pumpManager = nil

        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 100),
            date: now.addingTimeInterval(-5 * 60)
        )

        // Add fresh pump reading
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false with no pump manager")
        let lastResult = await closedLoop.latestLoopRecord()
        #expect(lastResult?.outcome.skipReason == .noPumpManager, "Should skip with noPumpManager")
    }

    // MARK: - Successful Loop Tests
    @Test func successfulLoopWithTempBasal() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = false

        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )

        // Set fresh pump sync
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(result, "Loop should return true for successful temp basal")
        let lastResult = await closedLoop.latestLoopRecord()
        guard case .dosed(let snapshot) = lastResult?.outcome else {
            Issue.record("Outcome should be .dosed for successful temp basal")
            return
        }
        guard case .tempBasal = snapshot.decision else {
            Issue.record("Decision should be .tempBasal")
            return
        }
    }

    @Test func successfulLoopWithMicroBolus() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = true
        settings.targetGlucoseInMgDl = 100

        // Add fresh glucose reading significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180),
            date: now.addingTimeInterval(-5 * 60)
        )

        // Set fresh pump sync
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(result, "Loop should return true for successful micro bolus")
        let lastResult = await closedLoop.latestLoopRecord()
        guard case .dosed(let snapshot) = lastResult?.outcome else {
            Issue.record("Outcome should be .dosed for successful micro bolus")
            return
        }
        guard case .microBolus = snapshot.decision else {
            Issue.record("Decision should be .microBolus")
            return
        }
    }

    @Test func loopWithPumpError() async throws {
        // Setup
        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60

        // Add fresh glucose reading
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )

        // Set fresh pump sync
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        pumpManager.state.pumpErrorDetected = true

        // Test
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false when pump returns error")
        let lastResult = await closedLoop.latestLoopRecord()
        guard case .pumpError = lastResult?.outcome else {
            Issue.record("Outcome should be .pumpError")
            return
        }
    }

    // MARK: - Microbolus tests
    @Test mutating func loopWithMicrobolusSuccess() async throws {
        // Configure settings for microbolus
        settings.update(maxBasalRateUnitsPerHour: 2.0)
        settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        // lastMicroBolus is a query against the record store; with no prior dosed runs, it is nil.

        // Mock physiological models to return rising glucose prediction
        let mockPhysiological = MockPhysiologicalModels()
        mockPhysiological.mockPredictGlucose = 185  // Rising glucose
        mockPhysiological.mockTempBasalResult = 2.0
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: mockPhysiological
        )

        // Mock current data - significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180), // 80 mg/dl above target
            date: now
        )
        insulinStorage.mockLastPumpSync = now

        // Execute loop. `runLoop` returns what the tick produced without making
        // any of it durable — that is `loop`'s job — so this reads the in-memory
        // `ClosedLoopResult` rather than the projected record.
        let run: LoopRun = await closedLoop.runLoop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())
        guard case .dosed(let snapshot) = run.result.outcome else {
            Issue.record("Loop should complete successfully with microbolus")
            return
        }
        guard case .microBolus(let units) = snapshot.outputs.decision else {
            Issue.record("Decision should be .microBolus")
            return
        }

        // Verify microbolus was set
        #expect(units > 0)

        // The ledger entry a dosed tick earns, built here and written by `loop`.
        guard case .microBolus(let programmed, _) = run.safetyState?.kind else {
            Issue.record("A dosed micro bolus should carry a .microBolus ledger entry")
            return
        }
        #expect(programmed == units)
    }

    @Test mutating func loopWithMicrobolusError() async throws {
        // Configure settings for microbolus
        settings.update(maxBasalRateUnitsPerHour: 2.0)
        settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        // lastMicroBolus is a query against the record store; with no prior dosed runs, it is nil.

        // Mock physiological models to return rising glucose prediction
        let mockPhysiological = MockPhysiologicalModels()
        mockPhysiological.mockPredictGlucose = 185  // Rising glucose
        mockPhysiological.mockTempBasalResult = 2.0
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: mockPhysiological
        )

        // Mock current data - significantly above target
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180), // 80 mg/dl above target
            date: now
        )
        insulinStorage.mockLastPumpSync = now

        // Configure pump to return an error for bolus delivery
        pumpManager.state.bolusEnactmentShouldError = true

        // Execute loop
        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // Verify
        #expect(!result, "Loop should return false when pump returns error during micro bolus")
        let lastResult = await closedLoop.latestLoopRecord()
        guard case .pumpError(let snapshot) = lastResult?.outcome else {
            Issue.record("Outcome should be .pumpError")
            return
        }
        guard case .microBolus(let units) = snapshot.decision else {
            Issue.record("Decision should be .microBolus even though delivery failed")
            return
        }
        #expect(units > 0, "Micro bolus amount should be greater than 0")
    }

    // MARK: - AI interface: the CGM tick marker
    //
    // `lastCgmTickHandledAt` is how an AI app that listens in on CGM Bluetooth
    // itself knows GlucOS has finished reacting to the reading it just saw, so
    // what it is about to read is this tick's answer rather than the last one's.
    // The loop is the only thing that can say that, which is why these live here
    // rather than with the rest of the exporter's tests.

    /// A real exporter over a temp directory, so the marker can be read back out
    /// of the file an AI app would poll rather than out of a spy.
    func makeAiInterfaceStorage() async throws -> (AiInterfaceContainer, LocalAiInterfaceStorage) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let container = try #require(AiInterfaceContainer(baseURL: base))
        let exporter = LocalAiInterfaceStorage(container: container, stateStorage: MockStoredObject())
        // One insulin pass first, because that is what creates
        // `current_insulin_dosing.json` — the tick marker is a field in it, not a
        // file of its own.
        await exporter.exportInsulinDosing(
            doses: [],
            scheduledBasalRateUnitsPerHour: 0.5,
            pump: .lyumjevOnOmnipod,
            at: now - 1.minutesToSeconds()
        )
        return (container, exporter)
    }

    func readCgmTickMarker(_ container: AiInterfaceContainer) throws -> Date? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = try Data(contentsOf: container.currentInsulinDosingURL)
        return try decoder.decode(CurrentInsulinDosing.self, from: data).lastCgmTickHandledAt
    }

    @Test mutating func aDosedLoopPublishesTheReadingItDosedOn() async throws {
        let (container, aiInterfaceStorage) = try await makeAiInterfaceStorage()
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            aiInterfaceStorage: aiInterfaceStorage
        )
        #expect(try readCgmTickMarker(container) == nil)

        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = false

        let cgmReadingAt = now.addingTimeInterval(-5 * 60)
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: cgmReadingAt
        )
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        #expect(result, "Loop should have dosed")
        // The CGM's timestamp, not the loop's `at` — that is the value an AI app
        // holding the same reading can compare against.
        #expect(try readCgmTickMarker(container) == cgmReadingAt)
    }

    @Test mutating func aLoopThatSetsNoPumpCommandsPublishesNoTick() async throws {
        let (container, aiInterfaceStorage) = try await makeAiInterfaceStorage()
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            aiInterfaceStorage: aiInterfaceStorage
        )

        // Open loop: fresh data, nothing sent to the pump.
        settings.closedLoopEnabled = false
        settings.freshnessIntervalInSeconds = 10 * 60
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        #expect(!result)
        // Nothing was set, so there is nothing for an AI app to wait for and the
        // marker stays where it was.
        #expect(try readCgmTickMarker(container) == nil)
    }

    @Test mutating func aFailedPumpCommandPublishesNoTick() async throws {
        let (container, aiInterfaceStorage) = try await makeAiInterfaceStorage()
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            aiInterfaceStorage: aiInterfaceStorage
        )

        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)
        pumpManager.state.pumpErrorDetected = true

        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        #expect(!result)
        // The commands were attempted and failed, so GlucOS is not done with this
        // reading in any sense a reader should act on.
        #expect(try readCgmTickMarker(container) == nil)
    }

    /// The marker used to be written *between* the loop's two file writes, with a
    /// comment stating it must not come before the safety record. It now runs
    /// after a single transaction, so "GlucOS is done with this reading" cannot
    /// be published for a tick whose dose the ledger has not accounted for.
    ///
    /// That is strictly later than before, and this is the case that shows it:
    /// the pump commands succeeded, so the old ordering would have published.
    @Test mutating func aFailedRecordPublishesNoTick() async throws {
        let (container, aiInterfaceStorage) = try await makeAiInterfaceStorage()
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            recordStore: MockLoopRecordStore(failWrites: true),
            aiInterfaceStorage: aiInterfaceStorage
        )

        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = false
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        // The dose happened, so the loop reports success and the UI still shows
        // the tick — only the marker is withheld.
        #expect(result, "the pump commands succeeded, whatever happened to the record")
        #expect(try readCgmTickMarker(container) == nil, "an unrecorded dose must not advertise completion")
        let lastResult = await closedLoop.latestLoopRecord()
        #expect(lastResult?.outcome.snapshot != nil, "UI state reflects what happened whether or not it was stored")
    }

    /// Same reasoning for a store that never opened: nothing is durable, so
    /// nothing is advertised.
    @Test mutating func noRecordStorePublishesNoTick() async throws {
        let (container, aiInterfaceStorage) = try await makeAiInterfaceStorage()
        closedLoop = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            recordStore: nil,
            aiInterfaceStorage: aiInterfaceStorage
        )

        settings.closedLoopEnabled = true
        settings.freshnessIntervalInSeconds = 10 * 60
        settings.useMicroBolus = false
        await glucoseStorage.addGlucoseReading(
            quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150),
            date: now.addingTimeInterval(-5 * 60)
        )
        insulinStorage.mockLastPumpSync = now.addingTimeInterval(-5 * 60)

        let result: Bool = await closedLoop.loop(at: now, pumpManager: deviceManager.pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())

        #expect(result)
        #expect(try readCgmTickMarker(container) == nil)
    }

    // MARK: - The launch path

    /// Pins the fix for the watchdog kill: constructing a `LoopRunner` reads
    /// nothing.
    ///
    /// The old initializer ran `(try? storage.read()) ?? []` on
    /// `closed_loop_results.json` from an `@MainActor` composition root, so every
    /// launch — foreground, BGTask, and the before-first-unlock Bluetooth wakes
    /// the CGM generates — decoded up to a day of loop results before any device
    /// manager existed. On 2026-08-15 that used the whole 30-second
    /// process-launch allowance.
    ///
    /// Scope, stated honestly: this pins that init's *body* touches the store not
    /// at all. What replaced the eager read is a `Task` that runs after init
    /// returns, and the test below covers the other half — that the chart data it
    /// populates still arrives.
    @Test func initPerformsNoStoreReads() async throws {
        let store = MockLoopRecordStore()
        _ = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            recordStore: store
        )
        #expect(await store.readCount == 0)
    }

    /// The deferred half: chart population moved into the background task rather
    /// than being deleted.
    @Test func theFilteredGlucoseChartIsPopulatedFromTheStore() async throws {
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        try await store.record(
            LoopRecordFixtures.dosed(at: now - 10.minutesToSeconds(), pid: LoopRecordFixtures.pid(at: now - 10.minutesToSeconds())),
            safetyState: nil,
            at: now
        )

        let observableState = AppObservableState()
        let runner = LoopRunner(
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            physiologicalModels: MockPhysiologicalModels(),
            targetGlucoseService: MockTargetGlucose(),
            machineLearning: MockMachineLearning(),
            safetyService: MockSafetyService(),
            settingsStorage: { self.settings },
            observableState: observableState,
            doseProgress: DoseProgress(),
            recordStore: store,
            startBackgroundTask: false
        )

        // Driven directly rather than waiting on the launch task, so there is no
        // sleep in this test.
        await runner.updateFilteredGlucoseChartData(at: now)

        #expect(observableState.filteredGlucoseChartData.count == 1)
        #expect(observableState.filteredGlucoseChartData.first?.at == now - 10.minutesToSeconds())
    }
}
