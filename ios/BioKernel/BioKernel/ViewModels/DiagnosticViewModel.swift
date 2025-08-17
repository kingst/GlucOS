
//
//  DiagnosticViewModel.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import Foundation
import Combine
import LoopKit

// MARK: - PumpDose Data Structures
struct Suspend: Hashable {
    let at: Date
}

struct Resume: Hashable {
    let at: Date
}

struct Bolus: Hashable {
    let startDate: Date
    let isComplete: Bool
    let programmedUnits: Double
    let isMicroBolus: Bool
    let deliveredUnits: Double?
}

struct Basal: Hashable {
    let startDate: Date
    let isComplete: Bool
    let isTempBasal: Bool
    let duration: Double
    let rate: Double
    let deliveredUnits: Double?
}

enum PumpDose: Hashable {
    case suspend(Suspend)
    case resume(Resume)
    case bolus(Bolus)
    case basal(Basal)
    
    var date: Date {
        switch self {
        case .suspend(let suspend):
            return suspend.at
        case .resume(let resume):
            return resume.at
        case .bolus(let bolus):
            return bolus.startDate
        case .basal(let basal):
            return basal.startDate
        }
    }
}

class DiagnosticViewModel: ObservableObject, ClosedLoopChartDataUpdate, PumpEventUpdate {
    @Published var chartData: [ClosedLoopChartData] = []
    @Published var pumpHistory: [PumpDose] = []
    
    private let closedLoopService = getClosedLoopService()
    private let insulinStorage = getInsulinStorage()
    
    init() {
        Task { @MainActor in
            let results = await self.closedLoopService.registerClosedLoopChartDataDelegate(delegate: self)
            self.chartData = results.filter({ $0.action == .setTempBasal }).map { self.convertToChartData(result: $0) }
        }
        
        Task {
            let entries = await insulinStorage.registerForPumpEntryUpdates(delegate: self)
            await process(entries: entries)
        }
    }
    
    // MARK: - PumpEventUpdate
    func update(entries: [NewPumpEvent]) {
        Task {
            await process(entries: entries)
        }
    }
    
    private func process(entries: [NewPumpEvent]) async {
        var history: [PumpDose] = []

        // Process non-dose events first
        for event in entries {
            switch event.type {
            case .suspend:
                history.append(.suspend(Suspend(at: event.date)))
            case .resume:
                history.append(.resume(Resume(at: event.date)))
            default:
                break // Doses are handled next
            }
        }
        
        // Process dose events, handling mutable/immutable duplicates
        let doseEvents = entries.compactMap { event -> (String, DoseEntry)? in
            guard let dose = event.dose, let syncId = dose.syncIdentifier else {
                return nil
            }
            return (syncId, dose)
        }
        
        var processedDoses: [String: DoseEntry] = [:]
        // Add immutable entries first
        for (syncId, dose) in doseEvents.filter({ !$0.1.isMutable }) {
            processedDoses[syncId] = dose
        }
        // Add mutable entries only if an immutable version doesn't exist
        for (syncId, dose) in doseEvents.filter({ $0.1.isMutable }) {
            if processedDoses[syncId] == nil {
                processedDoses[syncId] = dose
            }
        }
        
        for dose in processedDoses.values {
            switch dose.type {
            case .bolus:
                let bolus = Bolus(startDate: dose.startDate,
                                  isComplete: !dose.isMutable,
                                  programmedUnits: dose.programmedUnits,
                                  isMicroBolus: dose.automatic == true,
                                  deliveredUnits: dose.deliveredUnits)
                history.append(.bolus(bolus))
            case .tempBasal:
                let basal = Basal(startDate: dose.startDate,
                                  isComplete: !dose.isMutable,
                                  isTempBasal: true,
                                  duration: dose.endDate.timeIntervalSince(dose.startDate),
                                  rate: dose.unitsPerHour,
                                  deliveredUnits: dose.deliveredUnits)
                history.append(.basal(basal))
            default:
                break // Other dose types ignored for now
            }
        }
        
        // Sort and publish
        let sortedHistory = history.sorted(by: { $0.date > $1.date })
        
        await MainActor.run {
            self.pumpHistory = sortedHistory
        }
    }

    // MARK: - ClosedLoopChartDataUpdate
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
