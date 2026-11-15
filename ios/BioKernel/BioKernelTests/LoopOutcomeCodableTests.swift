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

    /// A tick with no override by default. The arguments are the four fields
    /// an override fills in.
    private func makeSnapshot(
        overridePolicy: String? = nil,
        overrideTargetGlucoseInMgDl: Double? = nil,
        overrideBasalRate: Double? = nil,
        overrideInsulinSensitivity: Double? = nil
    ) -> LoopSnapshot {
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
            overridePolicy: overridePolicy,
            overrideTargetGlucoseInMgDl: overrideTargetGlucoseInMgDl,
            insulinSensitivity: 55,
            basalRate: 0.3,
            overrideBasalRate: overrideBasalRate,
            overrideInsulinSensitivity: overrideInsulinSensitivity,
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

    /// The override fields were added after the replay fixtures in
    /// `Resources` were captured, so a payload without them has to decode as
    /// a tick with no override rather than fail
    /// (dev/backlog/more-settings-automation.md, "What each tick records").
    @Test func theOverrideFieldsDefaultToNoOverrideWhenAbsent() throws {
        let overrideKeys = ["overridePolicy", "overrideTargetGlucoseInMgDl", "overrideBasalRate", "overrideInsulinSensitivity"]
        let snapshot = makeSnapshot(
            overridePolicy: "exercise",
            overrideTargetGlucoseInMgDl: 140,
            overrideBasalRate: 0.18,
            overrideInsulinSensitivity: 91.5
        )
        let data = try JSONEncoder().encode(LoopOutcome.dosed(snapshot))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var dosed = try #require(json["dosed"] as? [String: Any])
        var outputs = try #require(dosed["outputs"] as? [String: Any])
        for key in overrideKeys {
            #expect(outputs[key] != nil, "\(key) is encoded when an override is on")
            outputs.removeValue(forKey: key)
        }
        dosed["outputs"] = outputs
        json["dosed"] = dosed

        let stripped = try JSONSerialization.data(withJSONObject: json)
        let decoded = try #require(try JSONDecoder().decode(LoopOutcome.self, from: stripped).snapshot?.outputs)
        #expect(decoded.overridePolicy == nil)
        #expect(decoded.overrideTargetGlucoseInMgDl == nil)
        #expect(decoded.overrideBasalRate == nil)
        #expect(decoded.overrideInsulinSensitivity == nil)
        #expect(decoded.targetGlucoseInMgDl == 90, "the settings values beside them are untouched")
        #expect(decoded.basalRate == 0.3)
        #expect(decoded.insulinSensitivity == 55)
    }

    /// A payload from a build that wrote `targetSource` and
    /// `dosingOverrideEnabled` still loads. Neither key is read any more:
    /// `targetSource` was an enum whose decode threw on a name it did not
    /// know, so here it is a name no build ever had, and the payload loads
    /// anyway. What the tick dosed with comes from the values that are still
    /// there.
    @Test func aPayloadWithTheOldTargetSourceAndDosingFlagKeysStillLoads() throws {
        let snapshot = makeSnapshot(
            overrideTargetGlucoseInMgDl: 140,
            overrideBasalRate: 0.18,
            overrideInsulinSensitivity: 91.5
        )
        let data = try JSONEncoder().encode(LoopOutcome.dosed(snapshot))
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var dosed = try #require(json["dosed"] as? [String: Any])
        var outputs = try #require(dosed["outputs"] as? [String: Any])
        #expect(outputs["targetSource"] == nil, "no longer encoded")
        #expect(outputs["dosingOverrideEnabled"] == nil, "no longer encoded")
        outputs["targetSource"] = "aSourceNoBuildEverHad"
        outputs["dosingOverrideEnabled"] = true
        dosed["outputs"] = outputs
        json["dosed"] = dosed

        let old = try JSONSerialization.data(withJSONObject: json)
        let decoded = try #require(try JSONDecoder().decode(LoopOutcome.self, from: old).snapshot?.outputs)
        #expect(decoded.overridePolicy == nil, "an old payload has no policy identifier")
        #expect(decoded.overrideTargetGlucoseInMgDl == 140)
        #expect(decoded.overrideBasalRate == 0.18)
        #expect(decoded.overrideInsulinSensitivity == 91.5)
        #expect(decoded.targetGlucoseInMgDl == 90)
    }

    /// With an override on, all four fields survive the round trip beside the
    /// settings values.
    @Test func theOverrideFieldsRoundTrip() throws {
        let snapshot = makeSnapshot(
            overridePolicy: "exercise",
            overrideTargetGlucoseInMgDl: 140,
            overrideBasalRate: 0.18,
            overrideInsulinSensitivity: 91.5
        )
        let (json1, decoded, json2) = try roundTrip(.dosed(snapshot))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        let outputs = try #require(decoded.snapshot?.outputs)
        #expect(outputs.overridePolicy == "exercise")
        #expect(outputs.targetGlucoseInMgDl == 90)
        #expect(outputs.overrideTargetGlucoseInMgDl == 140)
        #expect(outputs.overrideBasalRate == 0.18)
        #expect(outputs.overrideInsulinSensitivity == 91.5)
        #expect(outputs.basalRate == 0.3)
        #expect(outputs.insulinSensitivity == 55)
    }

    /// A tick whose override only scales dosing carries its policy
    /// identifier and no override target, and one from a policy this build
    /// does not know round-trips like any other: the identifier is text.
    @Test func thePolicyIdentifierRoundTripsOnADosingOnlyTickAndForAnUnknownPolicy() throws {
        let dosingOnly = makeSnapshot(overridePolicy: "digestion", overrideBasalRate: 0.39, overrideInsulinSensitivity: 42.3)
        let digestion = try #require(try roundTrip(.dosed(dosingOnly)).decoded.snapshot?.outputs)
        #expect(digestion.overridePolicy == "digestion")
        #expect(digestion.overrideTargetGlucoseInMgDl == nil)
        #expect(digestion.overrideBasalRate == 0.39)

        let unknown = makeSnapshot(overridePolicy: "some-future-source", overrideTargetGlucoseInMgDl: 110)
        let decoded = try #require(try roundTrip(.dosed(unknown)).decoded.snapshot?.outputs)
        #expect(decoded.overridePolicy == "some-future-source")
        #expect(decoded.overrideTargetGlucoseInMgDl == 110)
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
