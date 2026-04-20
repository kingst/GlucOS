//
//  ReplayLogs.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import Foundation
import LoopKit
import BioKernel

private final class BundleToken {}

struct ReplayLogs {
    static func replayLogs(forResource: String, ofType: String) -> [NewPumpEvent] {
        let bundle = Bundle(for: BundleToken.self)
        let jsonPath = bundle.path(forResource: forResource, ofType: ofType)!
        let jsonData = try! Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode([NewPumpEvent].self, from: jsonData)
    }

    static func replayLogs(forResource: String, ofType: String) -> [DoseEntry] {
        let bundle = Bundle(for: BundleToken.self)
        let jsonPath = bundle.path(forResource: forResource, ofType: ofType)!
        let jsonData = try! Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try! decoder.decode([DoseEntry].self, from: jsonData)
    }

    static func immutableReplayLogs() -> [NewPumpEvent] {
        return replayLogs(forResource: "immutable_replay_logs", ofType: "json")
    }

    static func fullReplayLogs() -> [NewPumpEvent] {
        return replayLogs(forResource: "replay_logs", ofType: "json")
    }

    static func iobBugLogs() -> [DoseEntry] {
        return replayLogs(forResource: "iob_bug", ofType: "json")
    }
}
