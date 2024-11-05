//
//  CGMManager.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import LoopKit
import LoopKitUI
import MockKit
import G7SensorKit
import G7SensorKitUI
import CGMBLEKit

let g7ManagerIdentifier: String = "G7CGMManager"
let g7LocalizedTitle = "Dexcom G7"
let g6ManagerIdentifier: String = "DexG6Transmitter"
let g6LocalizedTitle = "Dexcom G6"

let staticCGMManagersByIdentifier: [String: CGMManager.Type] = [
    MockCGMManager.managerIdentifier: MockCGMManager.self,
    g7ManagerIdentifier: G7CGMManager.self,
    g6ManagerIdentifier: G6CGMManager.self
]

var availableStaticCGMManagers: [CGMManagerDescriptor] {
    return [
            CGMManagerDescriptor(identifier: MockCGMManager.managerIdentifier, localizedTitle: MockCGMManager.localizedTitle),
            CGMManagerDescriptor(identifier: g7ManagerIdentifier, localizedTitle: g7LocalizedTitle),
            CGMManagerDescriptor(identifier: g6ManagerIdentifier, localizedTitle: g6LocalizedTitle)
        ]
}

func CGMManagerFromRawValue(_ rawValue: [String: Any]) -> CGMManager? {
    guard let managerIdentifier = rawValue["managerIdentifier"] as? String,
        let rawState = rawValue["state"] as? CGMManager.RawStateValue,
        let Manager = staticCGMManagersByIdentifier[managerIdentifier]
    else {
        return nil
    }
    
    return Manager.init(rawState: rawState)
}

extension CGMManager {

    typealias RawValue = [String: Any]
    
    var rawValue: [String: Any] {
        return [
            "managerIdentifier": managerIdentifier,
            "state": self.rawState
        ]
    }
}
