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
    /// The settings values, which are what the pipeline hands the PID when no
    /// dosing override is on. They match `MockSettingsStorage`.
    let basalRate = 1.0
    let insulinSensitivity = 45.0
    let accuracy = 1e-9

    /// The pair with no dosing override on: the settings values themselves.
    var settingsDosing: DosingParameters {
        return DosingParameters(settingsBasalRate: basalRate, settingsInsulinSensitivity: insulinSensitivity, dosingOverride: nil)
    }

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
            dosing: settingsDosing,
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
            dosing: settingsDosing,
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
        // with the filter off (the mock's default) the controller's input is the raw reading
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
            dosing: settingsDosing,
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
            dosing: settingsDosing,
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
            dosing: settingsDosing,
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
            dosing: settingsDosing,
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

    // MARK: - Low-pass filter setting

    private func makePhysModels() -> LocalPhysiologicalModels {
        LocalPhysiologicalModels(
            storedObjectFactory: InMemoryStoredObject.self,
            glucoseStorage: MockGlucoseStorage(),
            insulinStorage: MockInsulinStorage()
        )
    }

    private func tick(_ physModels: LocalPhysiologicalModels, glucose: Double, at: Date) async -> PIDTempBasalResult {
        await physModels.tempBasal(
            settings: settings.snapshot(),
            dosing: settingsDosing,
            glucoseInMgDl: glucose,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: 0,
            dataFrame: nil,
            at: at
        )
    }

    /// Two ticks five minutes apart with the filter off (the mock's default,
    /// matching the app's): the controller sees the raw reading, the
    /// derivative is the raw delta, and the persisted "filtered" value is
    /// the raw reading too.
    @Test func filterOffFeedsTheControllerRawGlucose() async throws {
        #expect(settings.snapshot().isPidLowPassFilterEnabled() == false)
        let physModels = makePhysModels()

        _ = await tick(physModels, glucose: 120, at: now)
        let result = await tick(physModels, glucose: 130, at: now + 5.minutesToSeconds())

        #expect(result.filteredGlucose == 130)
        #expect(result.error == 40)
        #expect(result.derivative == 10)
        let persisted: PIDState? = try InMemoryStoredObject.read(fileName: "pid_state.json")
        #expect(persisted?.lastFilteredGlucose == 130)
    }

    /// The same two ticks with the filter on, for contrast: the controller's
    /// input lags the raw reading and the derivative is damped.
    @Test func filterOnSmoothsTheControllerInput() async throws {
        settings.update(usePidLowPassFilter: true)
        let physModels = makePhysModels()

        _ = await tick(physModels, glucose: 120, at: now)
        let result = await tick(physModels, glucose: 130, at: now + 5.minutesToSeconds())

        #expect(result.filteredGlucose > 120)
        #expect(result.filteredGlucose < 130)
        let derivative = try #require(result.derivative)
        #expect(derivative > 0)
        #expect(derivative < 10)
        let persisted: PIDState? = try InMemoryStoredObject.read(fileName: "pid_state.json")
        #expect(persisted?.lastFilteredGlucose == result.filteredGlucose)
    }

    /// The tick that turns the filter off, which is also the first tick after
    /// the upgrade that introduced the setting: the restored state's
    /// `lastFilteredGlucose` lags its `lastGlucose`, and the derivative must
    /// be the raw delta (135 - 130), not the lag charged in one go (135 - 110).
    @Test func switchingTheFilterOffDoesNotChargeTheLagToTheDerivative() async throws {
        let fiveMinutesAgo = now - 5.minutesToSeconds()
        let lagging = PIDState(
            savedAt: fiveMinutesAgo,
            lastGlucose: 130,
            lastGlucoseAt: fiveMinutesAgo,
            accumulatedError: 0,
            lastFilteredGlucose: 110
        )
        try InMemoryStoredObject.write(lagging, fileName: "pid_state.json")
        let physModels = makePhysModels()

        let result = await tick(physModels, glucose: 135, at: now)

        #expect(result.filteredGlucose == 135)
        #expect(result.derivative == 5)
    }

    /// Turning the filter on resumes from the last raw reading: while off,
    /// `lastFilteredGlucose` is written with the raw value, so the first
    /// filtered tick blends from the previous raw reading and its derivative
    /// is the damped delta from it.
    @Test func switchingTheFilterOnResumesFromTheLastRawReading() async throws {
        let physModels = makePhysModels()
        _ = await tick(physModels, glucose: 120, at: now)

        settings.update(usePidLowPassFilter: true)
        let result = await tick(physModels, glucose: 130, at: now + 5.minutesToSeconds())

        #expect(result.filteredGlucose > 120)
        #expect(result.filteredGlucose < 130)
        let derivative = try #require(result.derivative)
        #expect(abs(derivative - (result.filteredGlucose - 120)) < 1e-9)
    }

    /// The stale-state reset still clears the filter when it is on: the first
    /// tick after the reset seeds from the raw reading rather than blending
    /// toward the stale filtered value.
    @Test func staleResetClearsTheFilterWhenItIsOn() async throws {
        settings.update(usePidLowPassFilter: true)
        let staleAt = now - 30.minutesToSeconds()
        let stale = PIDState(
            savedAt: staleAt,
            lastGlucose: 110,
            lastGlucoseAt: staleAt,
            accumulatedError: 50,
            lastFilteredGlucose: 110
        )
        try InMemoryStoredObject.write(stale, fileName: "pid_state.json")
        let physModels = makePhysModels()

        let result = await tick(physModels, glucose: 130, at: now)

        #expect(result.filteredGlucose == 130)
        #expect(result.derivative == 0.0)
        let persisted: PIDState? = try InMemoryStoredObject.read(fileName: "pid_state.json")
        #expect(persisted?.lastFilteredGlucose == 130)
    }

    // MARK: - Dosing overrides (dev/backlog/more-settings-automation.md)
    //
    // The PID takes the basal rate and insulin sensitivity to dose with. Under
    // a dosing override the pipeline hands it the basal rate times the dosing
    // multiplier and the insulin sensitivity divided by it. `deltaGlucoseError`,
    // which is the integrator input and the biological invariant, reads the
    // settings values itself and is the same with an override on or off.

    /// One cold-start tick with `dosingMultiplier` on, or with the settings
    /// pair for nil. No previous glucose, so the derivative and the
    /// integrator are both zero and the PID output is the proportional term
    /// alone.
    private func coldTick(dosingMultiplier: Double?, glucose: Double, insulinOnBoard: Double = 0) async -> PIDTempBasalResult {
        InMemoryStoredObject.reset()
        return await makePhysModels().tempBasal(
            settings: settings.snapshot(),
            dosing: dosing(dosingMultiplier),
            glucoseInMgDl: glucose,
            targetGlucoseInMgDl: 90,
            insulinOnBoard: insulinOnBoard,
            dataFrame: nil,
            at: now
        )
    }

    /// The pair the pipeline hands the PID with `dosingMultiplier` on, or
    /// the settings pair for nil. Built the way the pipeline builds it.
    private func dosing(_ dosingMultiplier: Double?) -> DosingParameters {
        return DosingParameters(
            settingsBasalRate: basalRate,
            settingsInsulinSensitivity: insulinSensitivity,
            dosingOverride: dosingMultiplier.flatMap { DosingOverride(dosingMultiplier: $0) }
        )
    }

    /// `DosingParameters` is the one place the scaled pair is built: the
    /// basal rate times the multiplier and the insulin sensitivity over it.
    /// With no dosing override it is the settings pair, untouched.
    @Test(arguments: [1.3, 0.6, 0.8])
    func dosingParametersScaleTheSettingsPair(dosingMultiplier: Double) {
        let scaled = dosing(dosingMultiplier)
        #expect(scaled.isOverridden)
        #expect(abs(scaled.basalRate - basalRate * dosingMultiplier) <= accuracy)
        #expect(abs(scaled.insulinSensitivity - insulinSensitivity / dosingMultiplier) <= accuracy)

        #expect(settingsDosing.isOverridden == false)
        #expect(settingsDosing.basalRate == basalRate)
        #expect(settingsDosing.insulinSensitivity == insulinSensitivity)
        #expect(dosing(nil) == settingsDosing)
    }

    /// The steady-state insulin on board at a basal rate, for the insulin
    /// type `MockInsulinStorage` reports.
    private func baselineInsulinOnBoard(basalRate: Double) -> Double {
        return PhysiologicalUtilities.calculateBasalBaselineInsulinOnBoard(basalRate: basalRate, insulinType: .humalog)
    }

    /// At target with nothing on board the correction is zero, so the temp
    /// basal is the basal rate the PID was handed: the settings rate times the
    /// dosing multiplier.
    @Test(arguments: [1.3, 0.6, 0.8])
    func scaledInputsGiveTheScaledBasalRateAtZeroCorrection(dosingMultiplier: Double) async throws {
        let scaledBasalRate = basalRate * dosingMultiplier
        let result = await coldTick(dosingMultiplier: dosingMultiplier, glucose: 90)

        #expect(result.error == 0)
        #expect(abs(result.tempBasal - scaledBasalRate) <= accuracy)
        // The PID's own baseline follows the basal rate it was handed.
        let baseline = try #require(result.basalRateInsulinOnBoard)
        #expect(abs(baseline - baselineInsulinOnBoard(basalRate: scaledBasalRate)) <= accuracy)
    }

    /// Above target with nothing on board, the correction is the PID output
    /// over the scaled sensitivity, which is the dosing multiplier times what
    /// the settings would give, and the scaled basal rate is added back in. So
    /// the whole temp basal scales by the multiplier.
    @Test(arguments: [1.3, 0.6, 0.8])
    func aDosingMultiplierScalesTheCorrectionAndTheBasalRateTogether(dosingMultiplier: Double) async throws {
        let unscaled = await coldTick(dosingMultiplier: nil, glucose: 150)
        let scaled = await coldTick(dosingMultiplier: dosingMultiplier, glucose: 150)

        // 60 mg/dl over target at 45 mg/dl per unit is 4/3 U, over a 30 minute
        // correction, plus the 1 U/h basal rate.
        #expect(abs(unscaled.tempBasal - (60.0 / 45.0 * 2 + 1)) <= accuracy)
        #expect(abs(scaled.tempBasal - dosingMultiplier * unscaled.tempBasal) <= accuracy)
        #expect(scaled.error == unscaled.error, "the multiplier does not touch the PID terms")
    }

    /// Starting Exercise or Post exercise. The baseline drops at once while
    /// the insulin on board still reflects the old rate, so the PID sees net
    /// insulin and doses below the scaled basal rate until it decays. That is
    /// the safe side.
    @Test(arguments: [0.6, 0.8])
    func aLowerBasalRateCountsTheOldBaselineAsNetInsulin(dosingMultiplier: Double) async throws {
        let scaledBasalRate = basalRate * dosingMultiplier
        let onBoard = baselineInsulinOnBoard(basalRate: basalRate)
        let result = await coldTick(dosingMultiplier: dosingMultiplier, glucose: 90, insulinOnBoard: onBoard)

        let netInsulin = onBoard - baselineInsulinOnBoard(basalRate: scaledBasalRate)
        #expect(netInsulin > 0)
        let correctionDuration = settings.snapshot().correctionDurationInSeconds
        #expect(abs(result.tempBasal - (scaledBasalRate - netInsulin * 1.hoursToSeconds() / correctionDuration)) <= accuracy)
        #expect(result.tempBasal < scaledBasalRate)
    }

    /// Starting Digestion, and Exercise ending. The baseline rises above the
    /// insulin on board, net insulin clamps at zero, and there is no catch-up
    /// dose for the gap: the temp basal is the scaled basal rate and no more.
    @Test func aHigherBasalRateDoesNotDoseForTheBaselineGap() async throws {
        let dosingMultiplier = 1.3
        let scaledBasalRate = basalRate * dosingMultiplier
        let onBoard = baselineInsulinOnBoard(basalRate: basalRate)
        #expect(onBoard < baselineInsulinOnBoard(basalRate: scaledBasalRate))

        let result = await coldTick(dosingMultiplier: dosingMultiplier, glucose: 90, insulinOnBoard: onBoard)
        #expect(abs(result.tempBasal - scaledBasalRate) <= accuracy)
    }

    /// Five rows five minutes apart with flat glucose, which is the window
    /// `deltaGlucoseError` reads. `insulinDelivered` is per row.
    private func flatFrame(insulinDelivered: Double) -> [AddedGlucoseDataRow] {
        return (0..<5).map { index in
            AddedGlucoseDataRow(
                eventTime: now - Double(4 - index) * 5.minutesToSeconds(),
                glucose: 100,
                insulinDelivered: insulinDelivered,
                insulinOnBoard: 1.5
            )
        }
    }

    /// `deltaGlucoseError` reads the settings basal rate and insulin
    /// sensitivity itself. With flat glucose and no active insulin the error
    /// is minus basal rate times insulin sensitivity, and active insulin adds
    /// its units times the insulin sensitivity.
    @Test func deltaGlucoseErrorIsOnTheSettingsValues() async throws {
        let physModels = makePhysModels()

        let noActiveInsulin = try #require(await physModels.deltaGlucoseError(settings: settings.snapshot(), dataFrame: flatFrame(insulinDelivered: 0), at: now))
        #expect(abs(noActiveInsulin + basalRate * insulinSensitivity) <= accuracy)

        // 0.05 U in each of the four steps and no change in insulin on board,
        // so 0.2 U were active over the window. At 45 mg/dl per unit over 20
        // minutes that is 27 mg/dl per hour.
        let activeInsulin = try #require(await physModels.deltaGlucoseError(settings: settings.snapshot(), dataFrame: flatFrame(insulinDelivered: 0.05), at: now))
        #expect(abs(activeInsulin - (27 - basalRate * insulinSensitivity)) <= accuracy)

        // It follows the settings: twice the basal rate is twice the basal term.
        settings.update(pumpBasalRateUnitsPerHour: 2 * basalRate)
        let doubledBasalRate = try #require(await physModels.deltaGlucoseError(settings: settings.snapshot(), dataFrame: flatFrame(insulinDelivered: 0), at: now))
        #expect(abs(doubledBasalRate + 2 * basalRate * insulinSensitivity) <= accuracy)
    }

    /// The integrator input does not follow the pair the PID is handed to dose
    /// with. Two ticks five minutes apart with a dosing multiplier on: each
    /// reports the settings error, and the second accumulates that error and
    /// not one with the weight of the active insulin divided by the
    /// multiplier.
    @Test(arguments: [1.3, 0.6, 0.8])
    func theIntegratorInputStaysOnTheSettingsValuesUnderADosingMultiplier(dosingMultiplier: Double) async throws {
        InMemoryStoredObject.reset()
        let physModels = makePhysModels()
        let frame = flatFrame(insulinDelivered: 0.05)
        let settingsError = try #require(await physModels.deltaGlucoseError(settings: settings.snapshot(), dataFrame: frame, at: now))
        #expect(abs(settingsError - (27 - basalRate * insulinSensitivity)) <= accuracy)
        // What scaling the pair would have given, which is a different number.
        let scaledError = 27 / dosingMultiplier - basalRate * insulinSensitivity
        #expect(abs(scaledError - settingsError) > 1)

        var results: [PIDTempBasalResult] = []
        for at in [now, now + 5.minutesToSeconds()] {
            results.append(await physModels.tempBasal(
                settings: settings.snapshot(),
                dosing: dosing(dosingMultiplier),
                glucoseInMgDl: 100,
                targetGlucoseInMgDl: 90,
                insulinOnBoard: 0,
                dataFrame: frame,
                at: at
            ))
        }

        let first = try #require(results.first)
        let second = try #require(results.last)
        #expect(first.deltaGlucoseError == settingsError)
        // Nothing accumulates on a first tick: there is no previous reading.
        #expect(first.accumulatedError == 0)
        #expect(second.deltaGlucoseError == settingsError)
        #expect(abs(second.accumulatedError - settingsError) <= accuracy)
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
