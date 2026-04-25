//
//  AppObservableState.swift
//  BioKernel
//
//  Published app-wide state read by SwiftUI views and written by multiple
//  services (DeviceDataManager, GlucoseStorage, ClosedLoopService). Extracted
//  from DeviceDataManagerObservableObject so services can publish UI state
//  without taking a dependency on DeviceDataManager.
//

import Foundation
import Combine
@preconcurrency import LoopKit
import LoopKitUI

@MainActor
public final class AppObservableState: ObservableObject {
    @Published public var pumpManager: PumpManagerUI?
    @Published public var cgmManager: CGMManager?
    @Published public var insulinOnBoard: Double = 0.0
    @Published public var pumpAlarm: PumpAlarmType?
    @Published public var lastGlucoseReading: NewGlucoseSample? = nil
    @Published public var displayGlucosePreference: DisplayGlucosePreference = DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter)
    @Published public var lastClosedLoopRun: ClosedLoopResult? = nil
    @Published public var activeAlert: LoopKit.Alert? = nil
    @Published public var glucoseChartData: [GlucoseChartPoint] = []
    @Published public var filteredGlucoseChartData: [FilteredGlucose] = []
    @Published public var doseProgress: DoseProgress = DoseProgress()

    public init() { }

    func digestionCalibrated() -> Double? {
        guard let lastRun = lastClosedLoopRun else { return nil }

        let tooOld = Date() - 16.minutesToSeconds()
        guard lastRun.at > tooOld else { return nil }

        guard let snapshot = lastRun.outcome.snapshot else { return nil }

        // added glucose is for an hour, so the basalRate = basalInsulin
        let basalGlucose = snapshot.outputs.insulinSensitivity * snapshot.outputs.basalRate

        // assume that 200 mg/dl is the max added glucose, aim for 0 -> 100
        return 100 * (snapshot.outputs.predictedAddedGlucoseInMgDlPerHour - basalGlucose) / 200
    }
}
