//
//  TargetGlucoseService.swift
//  BioKernel
//
//  Created by Sam King on 12/29/24.
//

// Note: this service is a pass-through today but exists as the future hook
// for meal predictions that lower the target 1 hour before eating.

import Foundation

public protocol TargetGlucoseService {
    func targetGlucoseInMgDl(at: Date, settings: CodableSettings) async -> Double
}

actor LocalTargetGlucoseService: TargetGlucoseService {
    let maxTargetGlucose = 140.0
    let minTargetGlucose = 70.0

    static let shared = LocalTargetGlucoseService()

    func targetGlucoseInMgDl(at: Date, settings: CodableSettings) async -> Double {
        return settings.targetGlucoseInMgDl.clamp(low: minTargetGlucose, high: maxTargetGlucose)
    }
}
