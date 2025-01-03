//
//  SettingsViewModel.swift
//  PickerTest
//
//  Created by Sam King on 1/13/24.
//

import Foundation
import SwiftUI
import HealthKit
import LoopKit

public class DecimalSettingSchedule: ObservableObject {
    @Published var midnightToFour: DecimalSetting?
    @Published var fourToEight: DecimalSetting?
    @Published var eightToTwelve: DecimalSetting?
    @Published var twelveToSixteen: DecimalSetting?
    @Published var sixteenToTwenty: DecimalSetting?
    @Published var twentyToTwentyFour: DecimalSetting?
    
    init() {
        midnightToFour = nil
        fourToEight = nil
        eightToTwelve = nil
        twelveToSixteen = nil
        sixteenToTwenty = nil
        twentyToTwentyFour = nil
    }
    
    init(_ settings: LearnedSettingsSchedule, units: String) {
        midnightToFour = settings.midnightToFour.map { DecimalSetting(value: $0, units: units) }
        fourToEight = settings.fourToEight.map { DecimalSetting(value: $0, units: units) }
        eightToTwelve = settings.eightToTwelve.map { DecimalSetting(value: $0, units: units) }
        twelveToSixteen = settings.twelveToSixteen.map { DecimalSetting(value: $0, units: units) }
        sixteenToTwenty = settings.sixteenToTwenty.map { DecimalSetting(value: $0, units: units) }
        twentyToTwentyFour = settings.twentyToTwentyFour.map { DecimalSetting(value: $0, units: units) }
    }
}

public class SettingsViewModel: ObservableObject {
    static let basalRateUnits = "U/h"
    static let insulinSensitivityUnits = "mg/dl / U"
    static let insulinUnits = "U"
    static let glucoseUnits = "mg/dl"
    static let gainUnits = "x"
    
    // these values represent what we want the UI to show as possible settings
    let basalRateValues = stride(from: 0.0, through: 3.0, by: 0.05).map { DecimalSetting(value: $0, units: basalRateUnits) }
    let insulinSensitivityValues = stride(from: 10.0, through: 100.0, by: 1.0).map { DecimalSetting(value: $0, units: insulinSensitivityUnits)}
    let maxBasalRateValues = stride(from: 0.5, through: 30.0, by: 0.5).map { DecimalSetting(value: $0, units: basalRateUnits) }
    let maxBolusValues = stride(from: 0.0, through: 30.0, by: 1.0).map { DecimalSetting(value: $0, units: insulinUnits) }
    let glucoseTargetValues = stride(from: 80.0, through: 140.0, by: 5.0).map { DecimalSetting(value: $0, units: glucoseUnits) }
    let glucoseSafetyShutoffValues = stride(from: 70.0, through: 130.0, by: 5.0).map { DecimalSetting(value: $0, units: glucoseUnits) }
    let microBolusDoseFactorValues = stride(from: 0.25, through: 0.5, by: 0.05).map { DecimalSetting(value: $0, units: gainUnits) }
    let bolusValues = stride(from: 0.5, through: 20.0, by: 0.5).map { DecimalSetting(value: $0, units: insulinUnits) }
    let pidIntegratorValues = stride(from: 0.0, through: 0.085, by: 0.005).map {
        DecimalSetting(value: $0, units: gainUnits) }
    let pidDerivativeValues = stride(from: 0.0, through: 5.0, by: 0.2).map {
        DecimalSetting(value: $0, units: gainUnits) }
    let machineLearningGainValues = stride(from: 0.5, through: 4.0, by: 0.25 ).map { DecimalSetting(value: $0, units: gainUnits) }
    
    // This function will handle the case when the current settings have a value
    // set that isn't represented by the items that we specify here. In this case
    // we just include a DecimalPickerItem for the current value along with the other
    // items that we have defined already.
    /*
    static func itemsWithCurrent(current: DecimalSetting, items: [DecimalSetting]) -> [DecimalSetting] {
        guard items.contains(current) else {
            return (items + [current]).sorted { $0.value < $1.value }
        }
        
        return items
    }*/
    
    // these are the values that the UI can set, these will only be persisted
    // on a successful call to `save()`
    @Published var closedLoopEnabled: Bool
    @Published var useMachineLearningClosedLoop: Bool
    @Published var useMicroBolus: Bool
    @Published var microBolusDoseFactor: DecimalSetting
    @Published var pumpBasalRate: DecimalSetting
    @Published var insulinSensitivity: DecimalSetting
    @Published var maxBasalRate: DecimalSetting
    @Published var maxBolus: DecimalSetting
    @Published var glucoseSafetyShutoff: DecimalSetting
    @Published var glucoseTarget: DecimalSetting
    @Published var bolusAmountForLess: DecimalSetting
    @Published var bolusAmountForUsual: DecimalSetting
    @Published var bolusAmountForMore: DecimalSetting
    @Published var pidIntegratorGain: DecimalSetting
    @Published var pidDerivativeGain: DecimalSetting
    @Published var useBiologicalInvariant: Bool
    @Published var adjustTargetGlucoseDuringExercise: Bool
    @Published var machineLearningGain: DecimalSetting
    
    var mlBasalSchedule: DecimalSettingSchedule
    var mlInsulinSensitivitySchedule: DecimalSettingSchedule
    
    func save() async throws {
        let error = await FaceId.authenticate()
        
        guard error == nil else {
            throw "Not authenticated"
        }
        
        try await persistUpdatedSettings()
    }
    
    func authorizeHealthKit() async throws {
        try await getHealthKitStorage().authorize()
    }
    
    private func persistUpdatedSettings() async throws {
        guard let pumpManager = await getDeviceDataManager().pumpManager else {
            try await getSettingsStorage().writeToDisk(settings: snapshot())
            throw "Pump manager is nil, saved settings to disk but can't sync to the pump"
        }
        
        let maxBasal = HKQuantity(unit: .internationalUnitsPerHour, doubleValue: maxBasalRate.value)
        let maxBolus = HKQuantity(unit: .internationalUnit(), doubleValue: maxBolus.value)
        let schedule = RepeatingScheduleValue(startTime: 0.0, value: pumpBasalRate.value)
        
        try await getSettingsStorage().writeToDisk(settings: snapshot())
        
        // FIXME: if we error at this point the settings will be out of sync with what's running on the pump
        if !closedLoopEnabled {
            if let cancelError = await pumpManager.cancelTempBasal() {
                throw "Could not cancel the current temp basal: \(cancelError.localizedDescription)"
            }
        }
        
        if let basalError = await pumpManager.syncBasalRateSchedule(items: [schedule]) {
            throw "Could not update basal rate: \(basalError.localizedDescription)"
        }
        
        if let limitsError = await pumpManager.syncDeliveryLimits(limits: DeliveryLimits(maximumBasalRate: maxBasal, maximumBolus: maxBolus)) {
            throw "Could not update delivery limits \(limitsError.localizedDescription)"
        }
    }

    func update(using settings: CodableSettings) {
        closedLoopEnabled = settings.closedLoopEnabled
        useMachineLearningClosedLoop = settings.useMachineLearningClosedLoop
        useMicroBolus = settings.isMicroBolusEnabled()
        microBolusDoseFactor = DecimalSetting(value: settings.getMicroBolusDoseFactor(), units: SettingsViewModel.gainUnits)
        pumpBasalRate = DecimalSetting(value: settings.pumpBasalRateUnitsPerHour, units: SettingsViewModel.basalRateUnits)
        insulinSensitivity = DecimalSetting(value: settings.insulinSensitivityInMgDlPerUnit, units: SettingsViewModel.insulinSensitivityUnits)
        maxBasalRate = DecimalSetting(value: settings.maxBasalRateUnitsPerHour, units: SettingsViewModel.basalRateUnits)
        mlBasalSchedule = DecimalSettingSchedule(settings.learnedBasalRatesUnitsPerHour, units: SettingsViewModel.basalRateUnits)
        mlInsulinSensitivitySchedule = DecimalSettingSchedule(settings.learnedInsulinSensivityInMgDlPerUnit, units: SettingsViewModel.insulinSensitivityUnits)
        maxBolus = DecimalSetting(value: settings.maxBolusUnits, units: SettingsViewModel.insulinUnits)
        glucoseSafetyShutoff = DecimalSetting(value: settings.shutOffGlucoseInMgDl, units: SettingsViewModel.glucoseUnits)
        glucoseTarget = DecimalSetting(value: settings.targetGlucoseInMgDl, units: SettingsViewModel.glucoseUnits)
        bolusAmountForLess = DecimalSetting(value: settings.getBolusAmountForLess(), units: SettingsViewModel.insulinUnits)
        bolusAmountForUsual = DecimalSetting(value: settings.getBolusAmountForUsual(), units: SettingsViewModel.insulinUnits)
        bolusAmountForMore = DecimalSetting(value: settings.getBolusAmountForMore(), units: SettingsViewModel.insulinUnits)
        pidIntegratorGain = DecimalSetting(value: settings.getPidIntegratorGain(), units: SettingsViewModel.gainUnits)
        pidDerivativeGain = DecimalSetting(value: settings.getPidDerivativeGain(), units: SettingsViewModel.gainUnits)
        useBiologicalInvariant = settings.isBiologicalInvariantEnabled()
        adjustTargetGlucoseDuringExercise = settings.isTargetGlucoseAdjustedDuringExerciseEnabled()
        machineLearningGain = DecimalSetting(value: settings.getMachineLearningGain(), units: SettingsViewModel.gainUnits)
    }
    
    public init(settings: CodableSettings) {
        closedLoopEnabled = settings.closedLoopEnabled
        useMachineLearningClosedLoop = settings.useMachineLearningClosedLoop
        useMicroBolus = settings.isMicroBolusEnabled()
        microBolusDoseFactor = DecimalSetting(value: settings.getMicroBolusDoseFactor(), units: SettingsViewModel.gainUnits)
        pumpBasalRate = DecimalSetting(value: settings.pumpBasalRateUnitsPerHour, units: SettingsViewModel.basalRateUnits)
        insulinSensitivity = DecimalSetting(value: settings.insulinSensitivityInMgDlPerUnit, units: SettingsViewModel.insulinSensitivityUnits)
        maxBasalRate = DecimalSetting(value: settings.maxBasalRateUnitsPerHour, units: SettingsViewModel.basalRateUnits)
        mlBasalSchedule = DecimalSettingSchedule(settings.learnedBasalRatesUnitsPerHour, units: SettingsViewModel.basalRateUnits)
        mlInsulinSensitivitySchedule = DecimalSettingSchedule(settings.learnedInsulinSensivityInMgDlPerUnit, units: SettingsViewModel.insulinSensitivityUnits)
        maxBolus = DecimalSetting(value: settings.maxBolusUnits, units: SettingsViewModel.insulinUnits)
        glucoseSafetyShutoff = DecimalSetting(value: settings.shutOffGlucoseInMgDl, units: SettingsViewModel.glucoseUnits)
        glucoseTarget = DecimalSetting(value: settings.targetGlucoseInMgDl, units: SettingsViewModel.glucoseUnits)
        bolusAmountForLess = DecimalSetting(value: settings.getBolusAmountForLess(), units: SettingsViewModel.insulinUnits)
        bolusAmountForUsual = DecimalSetting(value: settings.getBolusAmountForUsual(), units: SettingsViewModel.insulinUnits)
        bolusAmountForMore = DecimalSetting(value: settings.getBolusAmountForMore(), units: SettingsViewModel.insulinUnits)
        pidIntegratorGain = DecimalSetting(value: settings.getPidIntegratorGain(), units: SettingsViewModel.gainUnits)
        pidDerivativeGain = DecimalSetting(value: settings.getPidDerivativeGain(), units: SettingsViewModel.gainUnits)
        useBiologicalInvariant = settings.isBiologicalInvariantEnabled()
        adjustTargetGlucoseDuringExercise = settings.isTargetGlucoseAdjustedDuringExerciseEnabled()
        machineLearningGain = DecimalSetting(value: settings.getMachineLearningGain(), units: SettingsViewModel.gainUnits)
    }
    
    func snapshot() -> CodableSettings {
        let learnedBasalRate = LearnedSettingsSchedule.from(schedule: mlBasalSchedule)
        let learnedInsulinSensitivity = LearnedSettingsSchedule.from(schedule: mlInsulinSensitivitySchedule)
        return CodableSettings(created: Date(), pumpBasalRateUnitsPerHour: pumpBasalRate.value, insulinSensitivityInMgDlPerUnit: insulinSensitivity.value, maxBasalRateUnitsPerHour: maxBasalRate.value, maxBolusUnits: maxBolus.value, shutOffGlucoseInMgDl: glucoseSafetyShutoff.value, targetGlucoseInMgDl: glucoseTarget.value, closedLoopEnabled: closedLoopEnabled, useMachineLearningClosedLoop: useMachineLearningClosedLoop, useMicroBolus: useMicroBolus, microBolusDoseFactor: microBolusDoseFactor.value, learnedBasalRateUnitsPerHour: learnedBasalRate, learnedInsulinSensitivityInMgDlPerUnit: learnedInsulinSensitivity, bolusAmountForLess: bolusAmountForLess.value, bolusAmountForUsual: bolusAmountForUsual.value, bolusAmountForMore: bolusAmountForMore.value, pidIntegratorGain: pidIntegratorGain.value, pidDerivativeGain: pidDerivativeGain.value, useBiologicalInvariant: useBiologicalInvariant, adjustTargetGlucoseDuringExercise: adjustTargetGlucoseDuringExercise, machineLearningGain: machineLearningGain.value)
    }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }
}
