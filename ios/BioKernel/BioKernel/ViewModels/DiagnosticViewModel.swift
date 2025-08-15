
//
//  DiagnosticViewModel.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import Foundation
import Combine

class DiagnosticViewModel: ObservableObject, ClosedLoopChartDataUpdate {
    @Published var chartData: [ClosedLoopChartData] = []
    
    private let closedLoopService = getClosedLoopService()
    
    init() {
        Task { @MainActor in
            let results = await self.closedLoopService.registerClosedLoopChartDataDelegate(delegate: self)
            self.chartData = results.filter({ $0.action == .setTempBasal }).map { self.convertToChartData(result: $0) }
        }
    }
    
    func update(result: ClosedLoopResult) {
        DispatchQueue.main.async {
            if result.action == .setTempBasal {
                self.chartData.append(self.convertToChartData(result: result))
            }
        }
    }
    
    private func convertToChartData(result: ClosedLoopResult) -> ClosedLoopChartData {
        let pidResult = result.pidTempBasalResult
        let safetyResult = result.safetyResult
        
        let proportionalContribution = (pidResult?.Kp ?? 0) * (pidResult?.error ?? 0)
        let derivativeContribution = (pidResult?.Kd ?? 0) * (pidResult?.derivative ?? 0)
        let integratorContribution = (pidResult?.Ki ?? 0) * (pidResult?.accumulatedError ?? 0)
        let totalPidContribution = proportionalContribution + derivativeContribution + integratorContribution
        
        let mlInsulin = (safetyResult?.machineLearningTempBasal ?? 0) / 12 + (safetyResult?.machineLearningMicroBolus ?? 0)
        let physiologicalInsulin = (safetyResult?.physiologicalTempBasal ?? 0) / 12 + (safetyResult?.physiologicalMicroBolus ?? 0)
        let actualInsulin = (safetyResult?.actualTempBasal ?? 0) / 12 + (safetyResult?.actualMicroBolus ?? 0)
        
        return ClosedLoopChartData(
            at: result.at,
            glucose: result.glucoseInMgDl ?? 0,
            insulinOnBoard: result.insulinOnBoard ?? 0,
            basalRate: result.basalRate ?? 0,
            basalRateInsulinOnBoard: result.pidTempBasalResult?.basalRateInsulinOnBoard ?? 0,
            proportionalContribution: proportionalContribution,
            derivativeContribution: derivativeContribution,
            integratorContribution: integratorContribution,
            totalPidContribution: totalPidContribution,
            deltaGlucoseError: pidResult?.deltaGlucoseError ?? 0,
            accumulatedError: pidResult?.accumulatedError ?? 0,
            mlInsulin: mlInsulin,
            physiologicalInsulin: physiologicalInsulin,
            actualInsulin: actualInsulin,
            machineLearningInsulinLastThreeHours: safetyResult?.machineLearningInsulinLastThreeHours ?? 0,
            tempBasal: result.tempBasal ?? 0,
            microBolusAmount: result.microBolusAmount ?? 0
        )
    }
}
