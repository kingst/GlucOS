//
//  SafetyStateCodableTests.swift
//  BioKernelTests
//
//  Round-trip tests for SafetyState's Codable conformance. The Kind enum has
//  associated values, which is the shape that previously surfaced "_0" key bugs
//  for LoopOutcome — this guards SafetyState against the same regression and
//  the silent failure mode where post-restart decoding falls back to [] and the
//  3-hour ML budget tally invisibly resets.
//

import Testing
import Foundation

@testable import BioKernel

struct SafetyStateCodableTests {
    private let referenceAt = Date(timeIntervalSince1970: 1_777_687_460)
    private let referenceDuration: TimeInterval = 30 * 60

    private func makeState(kind: SafetyState.Kind) -> SafetyState {
        return SafetyState(at: referenceAt, duration: referenceDuration, kind: kind)
    }

    private func roundTrip(_ state: SafetyState) throws -> (firstJson: String, decoded: SafetyState, secondJson: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data1 = try encoder.encode(state)
        let json1 = try #require(String(data: data1, encoding: .utf8))

        let decoded = try JSONDecoder().decode(SafetyState.self, from: data1)

        let data2 = try encoder.encode(decoded)
        let json2 = try #require(String(data: data2, encoding: .utf8))
        return (json1, decoded, json2)
    }

    @Test func tempBasalRoundTrip() throws {
        let state = makeState(kind: .tempBasal(programmed: 1.5, physiological: 0.95))
        let (json1, decoded, json2) = try roundTrip(state)

        #expect(!json1.contains("\"_0\""), "encoded JSON should not contain _0 keys: \(json1)")
        #expect(json1.contains("\"tempBasal\""))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        guard case .tempBasal(let programmed, let physiological) = decoded.kind else {
            Issue.record("decoded kind should be .tempBasal; got \(decoded.kind)")
            return
        }
        #expect(programmed == 1.5)
        #expect(physiological == 0.95)
        #expect(decoded.at == state.at)
        #expect(decoded.duration == state.duration)
    }

    @Test func microBolusRoundTrip() throws {
        let state = makeState(kind: .microBolus(programmed: 0.3, physiological: 0.2))
        let (json1, decoded, json2) = try roundTrip(state)

        #expect(!json1.contains("\"_0\""), "encoded JSON should not contain _0 keys: \(json1)")
        #expect(json1.contains("\"microBolus\""))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        guard case .microBolus(let programmed, let physiological) = decoded.kind else {
            Issue.record("decoded kind should be .microBolus; got \(decoded.kind)")
            return
        }
        #expect(programmed == 0.3)
        #expect(physiological == 0.2)
        #expect(decoded.at == state.at)
        #expect(decoded.duration == state.duration)
    }

    @Test func suspendedRoundTrip() throws {
        let state = makeState(kind: .suspended)
        let (json1, decoded, json2) = try roundTrip(state)

        #expect(!json1.contains("\"_0\""), "encoded JSON should not contain _0 keys: \(json1)")
        #expect(json1.contains("\"suspended\""))
        #expect(json1 == json2, "round-trip JSON should be byte-identical")

        guard case .suspended = decoded.kind else {
            Issue.record("decoded kind should be .suspended; got \(decoded.kind)")
            return
        }
        #expect(decoded.at == state.at)
        #expect(decoded.duration == state.duration)
    }

    // Mirrors what `safety_states.json` actually persists: an ordered array of
    // mixed-kind entries. Catches regressions where a single Kind round-trips
    // but the array shape doesn't.
    @Test func arrayRoundTripPreservesAllKinds() throws {
        let states: [SafetyState] = [
            makeState(kind: .tempBasal(programmed: 1.5, physiological: 0.95)),
            makeState(kind: .microBolus(programmed: 0.3, physiological: 0.2)),
            makeState(kind: .suspended)
        ]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(states)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(!json.contains("\"_0\""), "encoded JSON should not contain _0 keys: \(json)")

        let decoded = try JSONDecoder().decode([SafetyState].self, from: data)
        #expect(decoded.count == 3)

        guard case .tempBasal(let p1, let phy1) = decoded[0].kind else {
            Issue.record(".tempBasal didn't survive array round-trip; got \(decoded[0].kind)")
            return
        }
        #expect(p1 == 1.5)
        #expect(phy1 == 0.95)

        guard case .microBolus(let p2, let phy2) = decoded[1].kind else {
            Issue.record(".microBolus didn't survive array round-trip; got \(decoded[1].kind)")
            return
        }
        #expect(p2 == 0.3)
        #expect(phy2 == 0.2)

        guard case .suspended = decoded[2].kind else {
            Issue.record(".suspended didn't survive array round-trip; got \(decoded[2].kind)")
            return
        }
    }
}
