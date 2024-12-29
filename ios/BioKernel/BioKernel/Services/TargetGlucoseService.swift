//
//  TargetGlucoseService.swift
//  BioKernel
//
//  Created by Sam King on 12/29/24.
//

// Note: for now this service is really simple -- it just deals with exercise
// but eventually I can imagine meal predictions that lower the target
// 1 hour before eating

import Foundation

public protocol TargetGlucoseService {
    func targetGlucoseInMgDl(at: Date, settings: CodableSettings) async -> Double
}

actor LocalTargetGlucoseService: TargetGlucoseService {
    let maxTargetGlucose = 140.0
    let minTargetGlucose = 70.0
    
    static let shared = LocalTargetGlucoseService()

    func targetGlucoseInMgDl(at: Date, settings: CodableSettings) async -> Double {
        return await targetGlucoseInMgDlCalculation(at: at, settings: settings).clamp(low: minTargetGlucose, high: maxTargetGlucose)
    }
    
    func targetGlucoseInMgDlCalculation(at: Date, settings: CodableSettings) async -> Double {
        guard settings.isTargetGlucoseAdjustedDuringExerciseEnabled() else {
            return settings.targetGlucoseInMgDl
        }
        
        let isExercising = await getWorkoutStatusService().isExercising(at: at)
        if isExercising {
            return 140
        } else {
            return settings.targetGlucoseInMgDl
        }
    }
}
