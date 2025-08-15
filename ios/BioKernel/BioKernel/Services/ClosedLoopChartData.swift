
//
//  ClosedLoopChartData.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import Foundation

// Data structure that the view will consume
struct ClosedLoopChartData: Identifiable {
    var id: Date { at }
    let at: Date
    let glucose: Double
    let insulinOnBoard: Double
    let basalRate: Double
    let basalRateInsulinOnBoard: Double
    let poportionalContribution: Double
    let derivativeContribution: Double
    let integratorContribution: Double
    let totalPidContribution: Double
    let deltaGlucoseError: Double
    let mlInsulin: Double
    let physiologicalInsulin: Double
    let actualInsulin: Double
    let machineLearningInsulinLastThreeHours: Double
    let tempBasal: Double
    let microBolusAmount: Double
}

// The protocol / delegate for the ClosedLoopService
protocol ClosedLoopChartDataUpdate: AnyObject {
    func update(result: ClosedLoopResult)
}
