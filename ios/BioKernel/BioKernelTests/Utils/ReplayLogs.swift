//
//  ReplayLogs.swift
//  BioKernelTests
//
//  Created by Sam King on 11/21/23.
//

import Foundation
import LoopKit
import BioKernel

struct ReplayLogs {
    static func replayLogs(for classObject: AnyClass, forResource: String, ofType: String) -> [NewPumpEvent] {
        let bundle = Bundle(for: classObject)
        let jsonPath = bundle.path(forResource: forResource, ofType: ofType)!
        let jsonData = try! Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode([NewPumpEvent].self, from: jsonData)
    }
    
    static func replayLogs(for classObject: AnyClass, forResource: String, ofType: String) -> [DoseEntry] {
        let bundle = Bundle(for: classObject)
        let jsonPath = bundle.path(forResource: forResource, ofType: ofType)!
        let jsonData = try! Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try! decoder.decode([DoseEntry].self, from: jsonData)
    }
    
    static func immutableReplayLogs(for classObject: AnyClass) -> [NewPumpEvent] {
        return replayLogs(for: classObject, forResource: "immutable_replay_logs", ofType: "json")
    }
    
    static func fullReplayLogs(for classObject: AnyClass) -> [NewPumpEvent] {
        return replayLogs(for: classObject, forResource: "replay_logs", ofType: "json")
    }
    
    static func iobBugLogs(for classObject: AnyClass) -> [DoseEntry] {
        return replayLogs(for: classObject, forResource: "iob_bug", ofType: "json")
    }
}
