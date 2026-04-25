
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
    
    private let closedLoopService: ClosedLoopService
    private let insulinStorage: InsulinStorage

    init(
        closedLoopService: ClosedLoopService,
        insulinStorage: InsulinStorage
    ) {
        self.closedLoopService = closedLoopService
        self.insulinStorage = insulinStorage
        Task { @MainActor in
            let results = await self.closedLoopService.registerClosedLoopChartDataDelegate(delegate: self)
            self.chartData = results.compactMap { self.convertToChartData(result: $0) }
        }

        Task {
            let entries = await self.insulinStorage.registerForPumpEntryUpdates(delegate: self)
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
            if let chart = self.convertToChartData(result: result) {
                self.chartData.append(chart)
            }
        }
    }

    private func convertToChartData(result: ClosedLoopResult) -> ClosedLoopChartData? {
        guard case .dosed(let snapshot) = result.outcome else { return nil }

        let pid = snapshot.outputs.pidTempBasalResult
        let safetyAnalysis = snapshot.outputs.safetyAnalysis

        let derivative = pid.derivative ?? 0
        let proportionalContribution = pid.Kp * pid.error
        let derivativeContribution = pid.Kd * derivative
        let integratorContribution = pid.Ki * pid.accumulatedError
        let totalPidContribution = proportionalContribution + derivativeContribution + integratorContribution

        let tempBasal: Double = snapshot.outputs.decision.tempBasalUnitsPerHour ?? 0
        let microBolus: Double = snapshot.outputs.decision.microBolusUnits ?? 0

        let mlInsulin = safetyAnalysis.machineLearningTempBasal / 12 + safetyAnalysis.machineLearningMicroBolus
        let physiologicalInsulin = safetyAnalysis.physiologicalTempBasal / 12 + safetyAnalysis.physiologicalMicroBolus
        let actualInsulin = tempBasal / 12 + microBolus

        return ClosedLoopChartData(
            at: result.at,
            glucose: snapshot.inputs.glucoseInMgDl,
            insulinOnBoard: snapshot.inputs.insulinOnBoard,
            basalRate: snapshot.outputs.basalRate,
            basalRateInsulinOnBoard: pid.basalRateInsulinOnBoard ?? 0,
            proportionalContribution: proportionalContribution,
            derivativeContribution: derivativeContribution,
            integratorContribution: integratorContribution,
            totalPidContribution: totalPidContribution,
            deltaGlucoseError: pid.deltaGlucoseError ?? 0,
            accumulatedError: pid.accumulatedError,
            mlInsulin: mlInsulin,
            physiologicalInsulin: physiologicalInsulin,
            actualInsulin: actualInsulin,
            machineLearningInsulinLastThreeHours: safetyAnalysis.machineLearningInsulinLastThreeHours,
            tempBasal: tempBasal,
            microBolusAmount: microBolus
        )
    }
}
