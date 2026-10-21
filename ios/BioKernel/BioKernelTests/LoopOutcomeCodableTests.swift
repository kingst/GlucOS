//
//  LoopOutcomeCodableTests.swift
//  BioKernelTests
//
//  Round-trip tests for LoopOutcome's custom Codable implementation.
//  Verifies the JSON has no synthesized "_0" keys and that encoding then
//  decoding produces an identical wire representation.
//
//  There is no longer an on-disk consumer of this format. `ClosedLoopResult` is
//  the in-memory pipeline result and the store persists `LoopRecord`, a
//  projection of it, in columns. The conformance is kept deliberately —
//  dev/backlog/loop-record-store-grdb.md §9 — because the full result is still
//  the audit payload, still in hand at the end of every loop, and the sink that
//  eventually consumes it (a replay log, a settings-version table) will want it
//  to encode correctly. So these tests keep guarding a shape whose next reader
//  has not been written yet, which is a weaker reason than they had before and
//  worth knowing when they fail.
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
        let candidates = DoseCandidates(
            physiologicalTempBasal: 0,
            mlTempBasal: 0,
            physiologicalMicroBolus: 0,
            mlMicroBolus: 0
        )
        let outputs = PipelineOutputs(
            predictedGlucoseInMgDl: 146.5,
            targetGlucoseInMgDl: 90,
            targetSource: .settings,
            insulinSensitivity: 55,
            basalRate: 0.3,
            pidTempBasalResult: pid,
            candidates: candidates,
            machineLearningInsulinLastThreeHours: 0,
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

    /// `targetSource` was added after the replay fixtures in `Resources` were
    /// captured, so a payload without it has to decode as `.settings` rather
    /// than fail (dev/backlog/meal-soon.md §6).
    @Test func targetSourceDefaultsToSettingsWhenAbsent() throws {
        let data = try JSONEncoder().encode(LoopOutcome.dosed(makeSnapshot()))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var dosed = try #require(json["dosed"] as? [String: Any])
        var outputs = try #require(dosed["outputs"] as? [String: Any])
        #expect(outputs["targetSource"] as? String == "settings", "the field is encoded when present")
        outputs.removeValue(forKey: "targetSource")
        dosed["outputs"] = outputs
        json["dosed"] = dosed

        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(LoopOutcome.self, from: stripped)
        #expect(decoded.snapshot?.outputs.targetSource == .settings)
        #expect(decoded.snapshot?.outputs.targetGlucoseInMgDl == 90)
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
