//
//  ClosedLoopTests.swift
//  BioKernelTests
//
//  Created by Sam King on 12/16/23.
//

import Testing
import Foundation
import LoopKit
import OmnipodKit
import MockKit
import HealthKit

@testable import BioKernel

@MainActor
struct ClosedLoopTests {
    let iobAccuracy = 0.00000000001

    @Test func baselineIoB() throws {
        let startDate = Date.f("2018-07-15 03:34:29 +0000")
        let endDate = startDate + 6.hoursToSeconds()
        let dose = DoseEntry(type: .tempBasal, startDate: startDate, endDate: endDate, value: 0.4, unit: .unitsPerHour, insulinType: .humalog, isMutable: false)

        let iob = dose.insulinOnBoard(at: endDate)
        // From the Python unit tests
        #expect(abs(iob - 0.8589151141064484) <= iobAccuracy)
    }

    // copied from the OmnipodKit code
    func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return OmniPumpManager.onboardingSupportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    @Test func basalRateRounding() throws {
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.31) - 0.3) <= iobAccuracy)
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.3491) - 0.3) <= iobAccuracy)
        #expect(abs(roundToSupportedBasalRate(unitsPerHour: 0.351) - 0.35) <= iobAccuracy)
    }

    // We reimplement OmnipodKit's internal ReservoirLevel.percentage, so pin it to the values that
    // implementation produces. A drift here silently changes what the app reports as remaining.
    @Test func reservoirPercentRemaining() throws {
        let percentRemaining = LocalDeviceDataManager.reservoirPercentRemaining(unitsRemaining:)

        // At or below the 50U threshold the pod reports an exact reading, scaled against 100U.
        #expect(abs(percentRemaining(0) - 0) <= iobAccuracy)
        #expect(abs(percentRemaining(10) - 0.1) <= iobAccuracy)
        #expect(abs(percentRemaining(50) - 0.5) <= iobAccuracy)

        // Above it the pod only reports "more than 50", which counts as full.
        #expect(abs(percentRemaining(50.1) - 1) <= iobAccuracy)
        #expect(abs(percentRemaining(200) - 1) <= iobAccuracy)

        #expect(abs(percentRemaining(-1) - 0) <= iobAccuracy)
    }

    @Test func doseLogic() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        let dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseMachineLearning() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: true, useBiologicalInvariant: false)

        let dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseMachineLearningMicroBolus() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: true, useBiologicalInvariant: false)

        let dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.25) <= iobAccuracy)
    }

    @Test func doseLogicUseMicroBolus() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: false)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.2) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.02, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseBiologicalInvariant() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: false, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseMicroBolusBiologicalInvariant() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: false, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.2) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.2) <= iobAccuracy)
    }

    @Test func doseLogicUseMachineLearningBiologicalInvariant() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: false, useMachineLearningClosedLoop: true, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 1.5) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)
    }

    @Test func doseLogicUseAll() async {
        let settings = await MockSettingsStorage()
        await settings.update(useMicroBolus: true, useMachineLearningClosedLoop: true, useBiologicalInvariant: true)

        var dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -25)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.25) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: -45)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.0) <= iobAccuracy)

        dose = DoseSelector.decide(settings: settings.snapshot(), physiologicalTempBasal: 1.0, safetyTempBasal: 1.5, microBolusPhysiological: 0.2, microBolusSafety: 0.25, biologicalInvariant: nil)

        #expect(abs(dose.tempBasal - 0.0) <= iobAccuracy)
        #expect(abs(dose.microBolus - 0.25) <= iobAccuracy)
    }

    // MARK: - Overrides (dev/backlog/meal-soon.md §10, exercise.md §6, more-settings-automation.md)

    /// One tick at 150 mg/dl with nothing on board, through a fresh runner
    /// with `kind` on, or no override for nil. A fresh runner per run, so each
    /// PID starts from the same state and the only difference between two runs
    /// is the override.
    private func tick(
        kind: TargetOverrideKind?,
        at now: Date,
        pumpManager: MockPumpManager,
        deviceManager: MockDeviceDataManager
    ) async throws -> (outputs: PipelineOutputs, recorded: LoopRecordSnapshot) {
        let settings = MockSettingsStorage()
        let glucoseStorage = MockGlucoseStorage()
        let insulinStorage = MockInsulinStorage()
        await glucoseStorage.addGlucoseReading(quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 150), date: now)
        insulinStorage.mockLastPumpSync = now
        let store = try GRDBLoopRecordStore(inMemoryCreatedAt: .distantPast)
        let runner = makeClosedLoopService(
            settings: settings,
            glucoseStorage: glucoseStorage,
            insulinStorage: insulinStorage,
            targetGlucoseService: MockTargetGlucose(kind: kind, startedAt: now),
            recordStore: store
        )

        // `runLoop` returns the in-memory result; `loop` is what makes a
        // tick durable.
        let run = await runner.runLoop(at: now, pumpManager: pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata())
        let outputs = try #require(run.result.outcome.snapshot?.outputs)
        #expect(await runner.loop(at: now, pumpManager: pumpManager, cgmPumpMetadata: deviceManager.cgmPumpMetadata()))
        let recorded = try #require(try await store.latestRecord()?.outcome.snapshot)
        return (outputs, recorded)
    }

    /// A target override reaches the pipeline through its one target read, so
    /// a stub with meal soon or exercise soon open is enough to check the
    /// whole path: the PID error shifts by the drop or the raise, the outputs
    /// carry the policy identifier, and the stored row carries the settings
    /// target with the override's target and its policy beside it.
    @Test func anOverrideTargetShiftsThePidErrorAndIsRecorded() async throws {
        let now = Date.f("2026-10-20 12:00:00 +0000")
        let pumpManager = MockPumpManager()
        let pumpManagerDelegate = MockPumpManagerDelegate()
        pumpManager.pumpManagerDelegate = pumpManagerDelegate
        let deviceManager = MockDeviceDataManager()
        deviceManager.mockPumpManager = pumpManager

        let settingsRun = try await tick(kind: nil, at: now, pumpManager: pumpManager, deviceManager: deviceManager)
        let mealSoonRun = try await tick(kind: .mealSoon, at: now, pumpManager: pumpManager, deviceManager: deviceManager)

        #expect(settingsRun.outputs.overridePolicy == nil)
        #expect(settingsRun.outputs.targetGlucoseInMgDl == 90)
        #expect(settingsRun.outputs.overrideTargetGlucoseInMgDl == nil)
        #expect(mealSoonRun.outputs.overridePolicy == "mealSoon")
        #expect(mealSoonRun.outputs.targetGlucoseInMgDl == 90, "the settings target, override or not")
        #expect(mealSoonRun.outputs.overrideTargetGlucoseInMgDl == 75)

        // error = filtered glucose − target, so a lower target is a larger error.
        let shift = mealSoonRun.outputs.pidTempBasalResult.error - settingsRun.outputs.pidTempBasalResult.error
        #expect(abs(shift - MealSoonPolicy.dropMgDl) <= iobAccuracy)

        #expect(settingsRun.recorded.targetGlucoseInMgDl == 90)
        #expect(settingsRun.recorded.overridePolicy == nil)
        #expect(settingsRun.recorded.overrideTargetGlucoseInMgDl == nil)
        #expect(mealSoonRun.recorded.targetGlucoseInMgDl == 90)
        #expect(mealSoonRun.recorded.overridePolicy == "mealSoon")
        #expect(mealSoonRun.recorded.overrideTargetGlucoseInMgDl == 75)

        // Exercise soon goes the other way: a higher target is a smaller error.
        let exerciseSoonRun = try await tick(kind: .exerciseSoon, at: now, pumpManager: pumpManager, deviceManager: deviceManager)
        #expect(exerciseSoonRun.outputs.overridePolicy == "exerciseSoon")
        #expect(exerciseSoonRun.outputs.targetGlucoseInMgDl == 90)
        #expect(exerciseSoonRun.outputs.overrideTargetGlucoseInMgDl == 140)
        let raise = settingsRun.outputs.pidTempBasalResult.error - exerciseSoonRun.outputs.pidTempBasalResult.error
        #expect(abs(raise - ExercisePolicy.raiseMgDl) <= iobAccuracy)
        #expect(exerciseSoonRun.recorded.targetGlucoseInMgDl == 90)
        #expect(exerciseSoonRun.recorded.overridePolicy == "exerciseSoon")
        #expect(exerciseSoonRun.recorded.overrideTargetGlucoseInMgDl == 140)

        // None of these three is a dosing override, so the PID dosed with the
        // settings values and nothing is recorded beside them.
        for run in [settingsRun, mealSoonRun, exerciseSoonRun] {
            #expect(run.outputs.overrideBasalRate == nil)
            #expect(run.outputs.overrideInsulinSensitivity == nil)
            #expect(run.recorded.overrideBasalRate == nil)
            #expect(run.recorded.overrideInsulinSensitivity == nil)
        }
    }

    /// A dosing override reaches the pipeline on the same read. The PID doses
    /// with the scaled basal rate and insulin sensitivity, the recorded basal
    /// rate and insulin sensitivity stay the settings values, the scaled pair
    /// is recorded beside them with the override's policy identifier, and the
    /// guardrail clamp does not move.
    ///
    /// The policy identifier is on a dosing-only tick too. Digestion and post
    /// exercise leave the target alone, so they have no override target, and
    /// before the identifier had its own field nothing on such a tick said
    /// which setting set the multiplier.
    @Test func aDosingOverrideScalesThePidAndIsRecordedBesideTheSettingsValues() async throws {
        let now = Date.f("2026-11-13 12:00:00 +0000")
        let pumpManager = MockPumpManager()
        let pumpManagerDelegate = MockPumpManagerDelegate()
        pumpManager.pumpManagerDelegate = pumpManagerDelegate
        let deviceManager = MockDeviceDataManager()
        deviceManager.mockPumpManager = pumpManager
        let settings = MockSettingsStorage().snapshot()

        let settingsRun = try await tick(kind: nil, at: now, pumpManager: pumpManager, deviceManager: deviceManager)
        let basalRate = settingsRun.outputs.basalRate
        let insulinSensitivity = settingsRun.outputs.insulinSensitivity
        #expect(basalRate == settings.learnedBasalRate(at: now))
        #expect(insulinSensitivity == settings.learnedInsulinSensitivity(at: now))

        // Written out, not read back from the kind. Exercise is the one kind
        // with both a target and a dosing override.
        let expected: [(kind: TargetOverrideKind, dosingMultiplier: Double, overridePolicy: String, overrideTarget: Double?)] = [
            (.digestion, 1.3, "digestion", nil),
            (.exercise, 0.6, "exercise", 140),
            (.postExercise, 0.8, "postExercise", nil)
        ]
        for (kind, dosingMultiplier, overridePolicy, overrideTarget) in expected {
            let run = try await tick(kind: kind, at: now, pumpManager: pumpManager, deviceManager: deviceManager)

            // The existing fields hold the settings values.
            #expect(run.outputs.basalRate == basalRate)
            #expect(run.outputs.insulinSensitivity == insulinSensitivity)
            #expect(run.outputs.targetGlucoseInMgDl == 90)
            #expect(run.outputs.overridePolicy == overridePolicy)
            #expect(run.outputs.overrideTargetGlucoseInMgDl == overrideTarget)

            // The scaled pair sits beside them.
            let overrideBasalRate = try #require(run.outputs.overrideBasalRate, "\(kind)")
            let overrideInsulinSensitivity = try #require(run.outputs.overrideInsulinSensitivity)
            #expect(abs(overrideBasalRate - basalRate * dosingMultiplier) <= iobAccuracy)
            #expect(abs(overrideInsulinSensitivity - insulinSensitivity / dosingMultiplier) <= iobAccuracy)
            #expect(abs(overrideBasalRate * overrideInsulinSensitivity - basalRate * insulinSensitivity) <= 1e-9)

            // The PID dosed with the scaled pair. On a first tick with nothing
            // on board its output is the proportional term alone: the error
            // over the scaled sensitivity, spread over the correction
            // duration, plus the scaled basal rate.
            let pid = run.outputs.pidTempBasalResult
            let expectedTempBasal = pid.error / overrideInsulinSensitivity * 1.hoursToSeconds() / settings.correctionDurationInSeconds + overrideBasalRate
            #expect(abs(pid.tempBasal - expectedTempBasal) <= 1e-9, "\(kind)")
            let baseline = try #require(pid.basalRateInsulinOnBoard)
            let expectedBaseline = PhysiologicalUtilities.calculateBasalBaselineInsulinOnBoard(basalRate: overrideBasalRate, insulinType: .humalog)
            #expect(abs(baseline - expectedBaseline) <= 1e-9, "the PID's own baseline follows the scaled basal rate")

            // The bounds do not move: the guardrail still clamps at the
            // settings max basal rate, which Digestion's PID output is over.
            #expect(run.outputs.candidates.physiologicalTempBasal <= settings.maxBasalRateUnitsPerHour)
            if kind == .digestion {
                #expect(pid.tempBasal > settings.maxBasalRateUnitsPerHour)
                #expect(run.outputs.candidates.physiologicalTempBasal == settings.maxBasalRateUnitsPerHour)
            }

            // And the stored row says the same.
            #expect(run.recorded.basalRate == basalRate)
            #expect(run.recorded.insulinSensitivity == insulinSensitivity)
            #expect(run.recorded.targetGlucoseInMgDl == 90)
            #expect(run.recorded.overridePolicy == overridePolicy)
            #expect(run.recorded.overrideTargetGlucoseInMgDl == overrideTarget)
            #expect(run.recorded.overrideBasalRate == overrideBasalRate)
            #expect(run.recorded.overrideInsulinSensitivity == overrideInsulinSensitivity)
        }

        // With the target unchanged the whole PID dose scales by the
        // multiplier: more insulin above 1, less below.
        let digestionRun = try await tick(kind: .digestion, at: now, pumpManager: pumpManager, deviceManager: deviceManager)
        let postExerciseRun = try await tick(kind: .postExercise, at: now, pumpManager: pumpManager, deviceManager: deviceManager)
        let settingsTempBasal = settingsRun.outputs.pidTempBasalResult.tempBasal
        #expect(abs(digestionRun.outputs.pidTempBasalResult.tempBasal - 1.3 * settingsTempBasal) <= 1e-9)
        #expect(abs(postExerciseRun.outputs.pidTempBasalResult.tempBasal - 0.8 * settingsTempBasal) <= 1e-9)
    }

    /// The pipeline sees the guardrails, not just the five settings' numbers.
    /// An open row with a target offset and a multiplier far outside their
    /// ranges, which `start` would have refused, reaches the PID clamped: a
    /// target of 200 and a multiplier of 1.5.
    @Test func aRowOutsideTheGuardrailsReachesThePipelineClamped() async throws {
        let now = Date.f("2026-11-15 12:00:00 +0000")
        let settings = MockSettingsStorage().snapshot()
        let basalRate = settings.learnedBasalRate(at: now)
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: now)
        let outside = TargetOverride(
            id: 1,
            policyIdentifier: "another-build",
            effect: OverrideEffect(targetOffsetMgDl: 500, dosingMultiplier: 10),
            startedAt: now - 5.minutesToSeconds(),
            expiresAt: now + 10.hoursToSeconds(),
            settingsTargetMgDl: 90,
            endedAt: nil,
            endReason: nil
        )

        func run(at: Date) async -> PipelineOutputs {
            let pipeline = DosingPipeline(
                physiological: LocalPhysiologicalModels(storedObjectFactory: MockStoredObject.self, glucoseStorage: MockGlucoseStorage(), insulinStorage: MockInsulinStorage()),
                machineLearning: MockMachineLearning(),
                safety: MockSafetyService(),
                target: MockTargetGlucose(override: outside)
            )
            return await pipeline.run(LoopInputs(
                at: at,
                settings: settings,
                glucoseInMgDl: 150,
                insulinOnBoard: 0,
                dataFrame: nil,
                lastMicroBolus: nil,
                roundToSupportedBasalRate: { $0 },
                roundToSupportedBolusVolume: { $0 }
            ))
        }

        let outputs = await run(at: now)
        #expect(outputs.overridePolicy == "another-build")
        #expect(outputs.targetGlucoseInMgDl == 90)
        #expect(outputs.overrideTargetGlucoseInMgDl == 200)
        #expect(outputs.pidTempBasalResult.error == 150 - 200)
        let overrideBasalRate = try #require(outputs.overrideBasalRate)
        let overrideInsulinSensitivity = try #require(outputs.overrideInsulinSensitivity)
        #expect(abs(overrideBasalRate - basalRate * 1.5) <= iobAccuracy)
        #expect(abs(overrideInsulinSensitivity - insulinSensitivity / 1.5) <= iobAccuracy)

        // Four hours after it started the row is over, whatever its expiry
        // says, and the tick is on the settings.
        let afterTheMaximum = await run(at: now - 5.minutesToSeconds() + 4.hoursToSeconds())
        #expect(afterTheMaximum.overridePolicy == nil)
        #expect(afterTheMaximum.overrideTargetGlucoseInMgDl == nil)
        #expect(afterTheMaximum.overrideBasalRate == nil)
        #expect(afterTheMaximum.pidTempBasalResult.error == 150 - 90)
    }

    /// A dosing override does not move the biological invariant or the
    /// integrator input: both are `deltaGlucoseError` on the settings values.
    ///
    /// Glucose here falls 30 mg/dl per hour with 0.2 U active over the window.
    /// The settings (1 U/h, 45 mg/dl per unit) explain a fall of 45 - 27 = 18
    /// less than that, so the error is -48 mg/dl per hour, past the -35 that
    /// suspends. Weighing the active insulin with Exercise's scaled
    /// sensitivity would read -30 and dose.
    @Test func aDosingOverrideDoesNotMoveTheBiologicalInvariant() async throws {
        let now = Date.f("2026-11-14 12:00:00 +0000")
        let settingsStorage = MockSettingsStorage()
        settingsStorage.update(useBiologicalInvariant: true)
        let settings = settingsStorage.snapshot()
        let frame = (0..<5).map { index in
            AddedGlucoseDataRow(
                eventTime: now - Double(4 - index) * 5.minutesToSeconds(),
                glucose: 110 - 2.5 * Double(index),
                insulinDelivered: 0.05,
                insulinOnBoard: 1.5
            )
        }

        let kinds: [TargetOverrideKind?] = [nil, .digestion, .exercise, .postExercise]
        for kind in kinds {
            // A fresh PID per run, so the only difference is the override.
            let pipeline = DosingPipeline(
                physiological: LocalPhysiologicalModels(storedObjectFactory: MockStoredObject.self, glucoseStorage: MockGlucoseStorage(), insulinStorage: MockInsulinStorage()),
                machineLearning: MockMachineLearning(),
                safety: MockSafetyService(),
                target: MockTargetGlucose(kind: kind, startedAt: now)
            )
            let outputs = await pipeline.run(LoopInputs(
                at: now,
                settings: settings,
                glucoseInMgDl: 100,
                insulinOnBoard: 1.5,
                dataFrame: frame,
                lastMicroBolus: nil,
                roundToSupportedBasalRate: { $0 },
                roundToSupportedBolusVolume: { $0 }
            ))

            #expect((outputs.overrideBasalRate != nil) == (kind != nil), "\(String(describing: kind))")
            #expect(outputs.overridePolicy == kind?.policyIdentifier)
            let integratorInput = try #require(outputs.pidTempBasalResult.deltaGlucoseError)
            #expect(abs(integratorInput + 48) <= 1e-9, "\(String(describing: kind))")
            #expect(outputs.decision == .suspendForBiologicalInvariant(mgDlPerHour: integratorInput), "\(String(describing: kind))")
        }
    }

    @Test func legacyInsulinSensitivityKeyDecodes() async throws {
        // Pre-rename on-disk format used the misspelled key.
        // After the rename, existing files must still decode without resetting user settings.
        let json = """
        {
            "created": "2025-01-01T00:00:00Z",
            "pumpBasalRateUnitsPerHour": 0.3,
            "insulinSensitivityInMgDlPerUnit": 45,
            "maxBasalRateUnitsPerHour": 2,
            "maxBolusUnits": 5,
            "shutOffGlucoseInMgDl": 85,
            "targetGlucoseInMgDl": 90,
            "freshnessIntervalInSeconds": 600,
            "correctionDurationInSeconds": 1800,
            "closedLoopEnabled": true,
            "useMachineLearningClosedLoop": false,
            "learnedBasalRatesUnitsPerHour": {},
            "learnedInsulinSensivityInMgDlPerUnit": { "midnightToFour": 42 }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(CodableSettings.self, from: json)

        // The legacy schedule should land on the renamed property.
        #expect(settings.learnedInsulinSensitivityInMgDlPerUnit.midnightToFour == 42)
        // An absent `usePidLowPassFilter` key reads as off, the default, so an
        // upgraded install runs with the filter off until the switch is saved.
        #expect(settings.isPidLowPassFilterEnabled() == false)
    }

    @Test func pidLowPassFilterKeyDecodes() async throws {
        let json = """
        {
            "created": "2025-01-01T00:00:00Z",
            "pumpBasalRateUnitsPerHour": 0.3,
            "insulinSensitivityInMgDlPerUnit": 45,
            "maxBasalRateUnitsPerHour": 2,
            "maxBolusUnits": 5,
            "shutOffGlucoseInMgDl": 85,
            "targetGlucoseInMgDl": 90,
            "closedLoopEnabled": true,
            "useMachineLearningClosedLoop": false,
            "learnedBasalRatesUnitsPerHour": {},
            "usePidLowPassFilter": true
        }
        """
        let data = try #require(json.data(using: .utf8))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let settings = try decoder.decode(CodableSettings.self, from: data)

        #expect(settings.isPidLowPassFilterEnabled() == true)
    }
}
