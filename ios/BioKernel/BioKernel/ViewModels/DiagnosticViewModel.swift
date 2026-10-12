
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

    /// How much pump history the Pump view shows.
    ///
    /// Previously this was however much the JSON log happened to hold, which came
    /// to the same 24 hours by accident. Now it is a stated window (decision 11),
    /// so that when the record store keeps 90 days the view asks for a day
    /// because that is what it wants to show, not because that is all there is.
    static let pumpHistoryWindow = 24.hoursToSeconds()

    private let closedLoopService: ClosedLoopService
    private let insulinStorage: InsulinStorage

    init(
        closedLoopService: ClosedLoopService,
        insulinStorage: InsulinStorage
    ) {
        self.closedLoopService = closedLoopService
        self.insulinStorage = insulinStorage
        Task { @MainActor in
            let records = await self.closedLoopService.registerClosedLoopChartDataDelegate(delegate: self)
            self.chartData = records.compactMap { self.convertToChartData(record: $0) }
        }

        Task {
            await self.insulinStorage.registerForPumpEntryUpdates(delegate: self)
            await reload()
        }
    }

    // MARK: - PumpEventUpdate

    /// The notification carries nothing, so we ask for the window we want.
    func pumpEventsDidChange() {
        Task {
            await reload()
        }
    }

    private func reload() async {
        let since = Date() - Self.pumpHistoryWindow
        let entries = await insulinStorage.recentPumpEvents(since: since)
        await process(entries: entries)
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
        
        // Process dose events, handling mutable/immutable duplicates. Shared
        // with the IoB path and the AI interface exporter so the Pump view
        // can't drift from what those two see. `.distantFuture` keeps the
        // previous behavior of showing every dose, with no `at` cutoff.
        let processedDoses = InsulinTimeline.deduplicatedDoses(events: entries, at: .distantFuture)

        for dose in processedDoses {
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
    func update(record: LoopRecord) {
        DispatchQueue.main.async {
            if let chart = self.convertToChartData(record: record) {
                self.chartData.append(chart)
            }
        }
    }

    /// The PID contributions are computed here rather than stored, which is why
    /// the store keeps the raw gains. This arithmetic is the thing a reader is
    /// checking; moving it into the write path would hide it.
    private func convertToChartData(record: LoopRecord) -> ClosedLoopChartData? {
        guard case .dosed(let snapshot) = record.outcome else { return nil }

        let pid = snapshot.pid

        let derivative = pid.derivative ?? 0
        let proportionalContribution = pid.Kp * pid.error
        let derivativeContribution = pid.Kd * derivative
        let integratorContribution = pid.Ki * pid.accumulatedError
        let totalPidContribution = proportionalContribution + derivativeContribution + integratorContribution

        let tempBasal: Double = snapshot.decision.tempBasalUnitsPerHour ?? 0
        let microBolus: Double = snapshot.decision.microBolusUnits ?? 0

        let insulin = snapshot.candidates.insulinPerLoopInterval(for: snapshot.decision)

        return ClosedLoopChartData(
            at: record.at,
            glucose: snapshot.glucoseInMgDl,
            insulinOnBoard: snapshot.insulinOnBoard,
            basalRate: snapshot.basalRate,
            basalRateInsulinOnBoard: pid.basalRateInsulinOnBoard ?? 0,
            proportionalContribution: proportionalContribution,
            derivativeContribution: derivativeContribution,
            integratorContribution: integratorContribution,
            totalPidContribution: totalPidContribution,
            deltaGlucoseError: pid.deltaGlucoseError ?? 0,
            accumulatedError: pid.accumulatedError,
            mlInsulin: insulin.ml,
            physiologicalInsulin: insulin.physiological,
            actualInsulin: insulin.programmed,
            machineLearningInsulinLastThreeHours: snapshot.machineLearningInsulinLastThreeHours,
            tempBasal: tempBasal,
            microBolusAmount: microBolus
        )
    }
}
