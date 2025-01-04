//
//  SettingsDataTypes.swift
//  BioKernel
//
//  Created by Sam King on 12/30/24.
//

import Foundation

public struct LearnedSettingsSchedule: Codable {
    let midnightToFour: Double?
    let fourToEight: Double?
    let eightToTwelve: Double?
    let twelveToSixteen: Double?
    let sixteenToTwenty: Double?
    let twentyToTwentyFour: Double?
    
    public static func empty() -> LearnedSettingsSchedule {
        return LearnedSettingsSchedule(midnightToFour: nil, fourToEight: nil, eightToTwelve: nil, twelveToSixteen: nil, sixteenToTwenty: nil, twentyToTwentyFour: nil)
    }
    
    static func from(schedule: DecimalSettingSchedule) -> LearnedSettingsSchedule {
        return LearnedSettingsSchedule(midnightToFour: schedule.midnightToFour?.value, fourToEight: schedule.fourToEight?.value, eightToTwelve: schedule.eightToTwelve?.value, twelveToSixteen: schedule.twelveToSixteen?.value, sixteenToTwenty: schedule.sixteenToTwenty?.value, twentyToTwentyFour: schedule.twentyToTwentyFour?.value)
    }
    
    func value(at: Date) -> Double? {
        // use the current calendar because these values are intended to be in
        // local time zones
        let hour = Calendar.current.component(.hour, from: at)
        switch hour {
        case 0..<4:
            return midnightToFour
        case 4..<8:
            return fourToEight
        case 8..<12:
            return eightToTwelve
        case 12..<16:
            return twelveToSixteen
        case 16..<20:
            return sixteenToTwenty
        case 20..<24:
            return twentyToTwentyFour
        default:
            return nil
        }
    }
}

public struct CodableSettings: Codable {
    let created: Date
    let pumpBasalRateUnitsPerHour: Double
    let insulinSensitivityInMgDlPerUnit: Double
    let maxBasalRateUnitsPerHour: Double
    let maxBolusUnits: Double
    let shutOffGlucoseInMgDl: Double
    public let targetGlucoseInMgDl: Double
    let freshnessIntervalInSeconds: Double
    let correctionDurationInSeconds: Double
    let closedLoopEnabled: Bool
    let useMachineLearningClosedLoop: Bool
    let useMicroBolus: Bool?
    let microBolusDoseFactor: Double?
    let learnedBasalRatesUnitsPerHour: LearnedSettingsSchedule
    let learnedInsulinSensivityInMgDlPerUnit: LearnedSettingsSchedule
    let bolusAmountForLess: Double?
    let bolusAmountForUsual: Double?
    let bolusAmountForMore: Double?
    let pidIntegratorGain: Double?
    let pidDerivativeGain: Double?
    let useBiologicalInvariant: Bool?
    let adjustTargetGlucoseDuringExercise: Bool?
    let machineLearningGain: Double?
    
    static let useMicroBolusDefault = false
    static let useBiologicalInvariantDefault = false
    static let adjustTargetGlucoseDuringExerciseDefault = false
    static let microBolusDoseFactorDefault = 0.3
    static let bolusAmountForLessDefault = 2.0
    static let bolusAmountForUsualDefault = 3.0
    static let bolusAmountForMoreDefault = 4.0
    static let pidIntegratorGainDefault = 0.055
    static let pidDerivativeGainDefault = 3.0
    static let machineLearningGainDefault = 1.5
    
    func learnedInsulinSensitivity(at: Date) -> Double {
        return learnedInsulinSensivityInMgDlPerUnit.value(at: at) ?? insulinSensitivityInMgDlPerUnit
    }
    
    func isMicroBolusEnabled() -> Bool { useMicroBolus ?? CodableSettings.useMicroBolusDefault }
    func isBiologicalInvariantEnabled() -> Bool { useBiologicalInvariant ?? CodableSettings.useBiologicalInvariantDefault}
    func isTargetGlucoseAdjustedDuringExerciseEnabled() -> Bool { adjustTargetGlucoseDuringExercise ?? CodableSettings.adjustTargetGlucoseDuringExerciseDefault}
    
    func getMicroBolusDoseFactor() -> Double { microBolusDoseFactor ?? CodableSettings.microBolusDoseFactorDefault}
    func getPidIntegratorGain() -> Double { pidIntegratorGain ?? CodableSettings.pidIntegratorGainDefault }
    func getPidDerivativeGain() -> Double { pidDerivativeGain ?? CodableSettings.pidDerivativeGainDefault }
    func getMachineLearningGain() -> Double { machineLearningGain ?? CodableSettings.machineLearningGainDefault }
    
    func learnedBasalRate(at: Date) -> Double {
        return learnedBasalRatesUnitsPerHour.value(at: at) ?? pumpBasalRateUnitsPerHour
    }
    
    func maxBasalRate() -> Double {
        return [learnedBasalRatesUnitsPerHour.midnightToFour,
                learnedBasalRatesUnitsPerHour.fourToEight,
                learnedBasalRatesUnitsPerHour.eightToTwelve,
                learnedBasalRatesUnitsPerHour.twelveToSixteen,
                learnedBasalRatesUnitsPerHour.sixteenToTwenty,
                learnedBasalRatesUnitsPerHour.twentyToTwentyFour,
                pumpBasalRateUnitsPerHour].compactMap({ $0 }).max() ?? pumpBasalRateUnitsPerHour
    }
    
    func getBolusAmountForLess() -> Double { bolusAmountForLess ?? CodableSettings.bolusAmountForLessDefault }
    func getBolusAmountForUsual() -> Double { bolusAmountForUsual ?? CodableSettings.bolusAmountForUsualDefault }
    func getBolusAmountForMore() -> Double { bolusAmountForMore ?? CodableSettings.bolusAmountForMoreDefault}
    
    //The funcion below validates that negative values cannot be assumed by maxBasalRateUnitsPerHour and microBolusDoseFactor.
    //These changes were made in accordance to formal verification using dafny where it was revealed that postconditions on the calculated insulin fail if these quantities are not checked and their properties assured(>0)
    func validate() {
        if maxBasalRateUnitsPerHour < 0 {
            fatalError("maxBasalRateUnitsPerHour must not be less than zero")
        }
        if let microBolusDoseFactor = microBolusDoseFactor, microBolusDoseFactor < 0 {
            fatalError("microBolusDoseFactor must not be less than zero")
        }
    }
    
    public init(created: Date, pumpBasalRateUnitsPerHour: Double, insulinSensitivityInMgDlPerUnit: Double, maxBasalRateUnitsPerHour: Double, maxBolusUnits: Double, shutOffGlucoseInMgDl: Double, targetGlucoseInMgDl: Double, closedLoopEnabled: Bool, useMachineLearningClosedLoop: Bool, useMicroBolus: Bool, microBolusDoseFactor: Double, learnedBasalRateUnitsPerHour: LearnedSettingsSchedule, learnedInsulinSensitivityInMgDlPerUnit: LearnedSettingsSchedule, bolusAmountForLess: Double, bolusAmountForUsual: Double, bolusAmountForMore: Double, pidIntegratorGain: Double, pidDerivativeGain: Double, useBiologicalInvariant: Bool, adjustTargetGlucoseDuringExercise: Bool, machineLearningGain: Double) {
        self.created = created
        self.pumpBasalRateUnitsPerHour = pumpBasalRateUnitsPerHour
        self.insulinSensitivityInMgDlPerUnit = insulinSensitivityInMgDlPerUnit
        self.maxBasalRateUnitsPerHour = maxBasalRateUnitsPerHour
        self.maxBolusUnits = maxBolusUnits
        self.shutOffGlucoseInMgDl = shutOffGlucoseInMgDl
        self.targetGlucoseInMgDl = targetGlucoseInMgDl
        self.closedLoopEnabled = closedLoopEnabled
        self.useMachineLearningClosedLoop = useMachineLearningClosedLoop
        self.useMicroBolus = useMicroBolus
        self.microBolusDoseFactor = microBolusDoseFactor
        self.learnedBasalRatesUnitsPerHour = learnedBasalRateUnitsPerHour
        self.learnedInsulinSensivityInMgDlPerUnit = learnedInsulinSensitivityInMgDlPerUnit
        self.bolusAmountForLess = bolusAmountForLess
        self.bolusAmountForUsual = bolusAmountForUsual
        self.bolusAmountForMore = bolusAmountForMore
        self.pidIntegratorGain = pidIntegratorGain
        self.pidDerivativeGain = pidDerivativeGain
        self.useBiologicalInvariant = useBiologicalInvariant
        self.adjustTargetGlucoseDuringExercise = adjustTargetGlucoseDuringExercise
        self.machineLearningGain = machineLearningGain
        
        // Note: We hard code this at 30 minutes because of Omnipod limitations
        self.correctionDurationInSeconds = 30.minutesToSeconds()
        // Hard code because we don't want to change it
        self.freshnessIntervalInSeconds = 10.minutesToSeconds()
    }
    
    static func defaults() -> CodableSettings {
        return CodableSettings(created: Date(), pumpBasalRateUnitsPerHour: 0.3, insulinSensitivityInMgDlPerUnit: 45, maxBasalRateUnitsPerHour: 2, maxBolusUnits: 5, shutOffGlucoseInMgDl: 85, targetGlucoseInMgDl: 90, closedLoopEnabled: false, useMachineLearningClosedLoop: false, useMicroBolus: useMicroBolusDefault, microBolusDoseFactor: microBolusDoseFactorDefault, learnedBasalRateUnitsPerHour: LearnedSettingsSchedule.empty(), learnedInsulinSensitivityInMgDlPerUnit: LearnedSettingsSchedule.empty(), bolusAmountForLess: bolusAmountForLessDefault, bolusAmountForUsual: bolusAmountForUsualDefault, bolusAmountForMore: bolusAmountForMoreDefault, pidIntegratorGain: pidIntegratorGainDefault, pidDerivativeGain: pidDerivativeGainDefault, useBiologicalInvariant: useBiologicalInvariantDefault, adjustTargetGlucoseDuringExercise: adjustTargetGlucoseDuringExerciseDefault, machineLearningGain: machineLearningGainDefault)
    }
}
