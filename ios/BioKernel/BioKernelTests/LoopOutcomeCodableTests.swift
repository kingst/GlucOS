//
//  LoopOutcomeCodableTests.swift
//  BioKernelTests
//
//  Round-trip tests for LoopOutcome's custom Codable implementation.
//  Verifies the persisted JSON has no synthesized "_0" keys and that
//  encoding then decoding produces an identical wire representation.
//

import Testing
import Foundation
@testable import BioKernel

struct LoopOutcomeCodableTests {

    private func makeSnapshot() -> LoopSnapshot {
        let pid = PIDTempBasalResult(
            at: Date(timeIntervalSince1970: 1_777_687_460),
            Kp: 1, Ki: 0.08, Kd: 3.6,
            filteredGlucose: 121,
            error: 31,
            tempBasal: -3.43,
            accumulatedError: 0,
            derivative: 0,
            lastGlucose: nil,
            lastGlucoseAt: nil,
            deltaGlucoseError: nil,
            basalRateInsulinOnBoard: 0.53
        )
        let safety = SafetyAnalysis(
            machineLearningTempBasal: 0,
            physiologicalTempBasal: 0,
            machineLearningMicroBolus: 0,
            physiologicalMicroBolus: 0,
            machineLearningInsulinLastThreeHours: 0,
            biologicalInvariantMgDlPerHour: nil
        )
        let outputs = PipelineOutputs(
            predictedGlucoseInMgDl: 146.5,
            targetGlucoseInMgDl: 90,
            insulinSensitivity: 55,
            basalRate: 0.3,
            pidTempBasalResult: pid,
            safetyAnalysis: safety,
            decision: .tempBasal(unitsPerHour: 0),
            timings: StageTimings(
                pidDurationInSeconds: 0.0002,
                mlDurationInSeconds: 0.0006,
                safetyDurationInSeconds: 0.00005
            ),
            predictedAddedGlucoseInMgDlPerHour: 152.9
        )
        return LoopSnapshot(
            inputs: LoopSnapshotInputs(glucoseInMgDl: 121, insulinOnBoard: 2.96),
            outputs: outputs,
            replay: LoopReplayInputs(dataFrame: nil, lastMicroBolus: nil)
        )
    }

    private func roundTrip(_ outcome: LoopOutcome) throws -> (firstJson: String, decoded: LoopOutcome, secondJson: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data1 = try encoder.encode(outcome)
        let json1 = try #require(String(data: data1, encoding: .utf8))

        let decoded = try JSONDecoder().decode(LoopOutcome.self, from: data1)

        let data2 = try encoder.encode(decoded)
        let json2 = try #require(String(data: data2, encoding: .utf8))
        return (json1, decoded, json2)
    }

    @Test func skippedRoundTrip() throws {
        let outcome: LoopOutcome = .skipped(.glucoseReadingStale)
        let (json1, decoded, json2) = try roundTrip(outcome)

        #expect(!json1.contains("\"_0\""), "encoded JSON should not contain _0 keys: \(json1)")
        #expect(json1.contains("\"skipped\""))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        guard case .skipped(let reason) = decoded else {
            Issue.record("decoded outcome should be .skipped")
            return
        }
        #expect(reason == .glucoseReadingStale)
    }

    @Test func dosedRoundTrip() throws {
        let snapshot = makeSnapshot()
        let outcome: LoopOutcome = .dosed(snapshot)
        let (json1, decoded, json2) = try roundTrip(outcome)

        #expect(!json1.contains("\"_0\""), "encoded JSON should not contain _0 keys")
        #expect(json1.contains("\"dosed\""))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        guard case .dosed(let s) = decoded else {
            Issue.record("decoded outcome should be .dosed")
            return
        }
        #expect(s.inputs.glucoseInMgDl == snapshot.inputs.glucoseInMgDl)
        #expect(s.outputs.targetGlucoseInMgDl == snapshot.outputs.targetGlucoseInMgDl)
    }

    @Test func pumpErrorRoundTrip() throws {
        let snapshot = makeSnapshot()
        let outcome: LoopOutcome = .pumpError(attempted: snapshot)
        let (json1, decoded, json2) = try roundTrip(outcome)

        #expect(!json1.contains("\"_0\""), "encoded JSON should not contain _0 keys")
        #expect(json1.contains("\"pumpError\""))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        guard case .pumpError(let s) = decoded else {
            Issue.record("decoded outcome should be .pumpError")
            return
        }
        #expect(s.inputs.glucoseInMgDl == snapshot.inputs.glucoseInMgDl)
    }
}
