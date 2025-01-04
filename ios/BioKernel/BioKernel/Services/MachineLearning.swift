//
//  MachineLearning.swift
//  BioKernel
//
//  Created by Sam King on 1/15/24.
//

import Foundation
import CoreML
import LoopKit

public protocol MachineLearning {
    func tempBasal(settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [AddedGlucoseDataRow]?, at: Date, pidTempBasal: PIDTempBasalResult) async -> Double?
}

struct MLUtilities {
    static func leastSquaresFit(x: [Double], y: [Double]) -> (slope: Double, intercept: Double)? {
        guard x.count == y.count else {
            print("Input arrays must have the same length.")
            return nil
        }

        let n = Double(x.count)
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).map { $0 * $1 }.reduce(0, +)
        let sumXSquared = x.map { $0 * $0 }.reduce(0, +)

        let slope = (n * sumXY - sumX * sumY) / (n * sumXSquared - sumX * sumX)
        let intercept = (sumY - slope * sumX) / n

        guard !slope.isNaN, !intercept.isNaN else {
            print("NAN in least squares!")
            return nil
        }
        
        return (slope, intercept)
    }
    
    static func stdDev(x: [Double], y: [Double], slope: Double, intercept: Double) -> Double {
        let predicted = x.map { $0 * slope + intercept }
        let errorsSquared = zip(y, predicted).map({ ($0 - $1) * ($0 - $1) }).reduce(0, +)
        return errorsSquared.squareRoot()
    }
}

actor AIDosing: MachineLearning {
    static let shared = AIDosing()
    
    private func log(_ str: String) async {
        let at = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
        let logString = "\(at): AI temp basal: \(str)"
        print(logString)
        await getEventLogger().add(debugMessage: logString)
    }

    // This version of the algorithm is specifically to dose more insulin during
    // active digestion
    func tempBasal(settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [AddedGlucoseDataRow]?, at: Date, pidTempBasal: PIDTempBasalResult) async -> Double? {
        
        await log("start")
        // make sure we have enough data
        guard let dataFrame = dataFrame else { await log("no frame"); return nil }

        // only dose during "waking hours" for now
        let hour = Calendar.current.component(.hour, from: at)
        guard hour < 22 && hour >= 7 else { await log ("hour \(hour) outside waking hours"); return nil }
        
        // don't dose while exercising, we only want to handle spikes from meals
        await log("Checking if we're exercising")
        guard await !getWorkoutStatusService().isExercising(at: at) else { await log("is working out"); return nil }
        
        await log("Checking if glucose is rising")
        // make sure that glucose is rising
        guard let predicted = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: at) else { await log("no predicted glucose"); return nil }
        guard predicted >= 180, predicted > glucoseInMgDl else { await log("Predict \(String(format: "%0.0f", predicted)) mg/dl vs \(String(format: "%0.0f", glucoseInMgDl)) mg/dl not actionable"); return nil }
        
        await log("Final calcs")
        // calculate added glucose and dose
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: at)
        guard let addedGlucose = dataFrame.addedGlucosePerHour30m(insulinSensitivity: insulinSensitivity) else { await log("can't calc added glucose"); return nil }
        
        let aiGain = settings.getMachineLearningGain()
        let insulinNeeded = aiGain * addedGlucose / insulinSensitivity - insulinOnBoard
        let tempBasal = insulinNeeded  * 1.hoursToSeconds() / settings.correctionDurationInSeconds
        
        // if we're going to dose less than the PID controller would, just
        // bail. The whole point of this model is to dose more than PID would
        guard tempBasal > pidTempBasal.tempBasal else { await log("tempBasal <= pidTempBasal: \(String(format: "%0.1f", tempBasal)) <= \(String(format: "%0.1f", pidTempBasal.tempBasal))"); return nil }
        
        await log("***Setting tempBasal \(String(format: "%0.1f", tempBasal)) U/h for 30m, pidTempBasal: \(String(format: "%0.1f", pidTempBasal.tempBasal))")
        
        return tempBasal
    }
}

actor DNNDosing: MachineLearning {
    static let shared = DNNDosing()
    
    // our current prediction uses an ML model to predict addedGlucose
    // then runs it through the same calculations that we use for
    // our physiological models
    func tempBasal(settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [AddedGlucoseDataRow]?, at: Date, pidTempBasal: PIDTempBasalResult) async -> Double? {
        
        // For now we will always return nil for ML, the current model is highly
        // personalized for one individual and not appropriate for use in general.
        // But, it shows what we used when we ran experiments.
        return nil
        
        let targetGlucose = targetGlucoseInMgDl
        let insulinSensitivity = settings.learnedInsulinSensitivity(at: at)
        let correctionDuration = settings.correctionDurationInSeconds
        
        guard let dataFrame = dataFrame else { return nil }
        
        guard let addedGlucose = runModelForAddedGlucose(dataFrame: dataFrame) else {
            print("Unable to predict addedGlucose")
            return nil
        }
        
        let totalGlucose = glucoseInMgDl - targetGlucose + addedGlucose
        let insulinNeeded = totalGlucose / insulinSensitivity - insulinOnBoard
        let tempBasal = insulinNeeded * 60.minutesToSeconds() / correctionDuration
        return tempBasal
    }
    
    func runModelForAddedGlucose(dataFrame: [AddedGlucoseDataRow]) -> Double? {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "AddedGlucoseModel", withExtension:"mlmodelc") else {
            print("can't find mlmodelc in bundle")
            return nil
        }
        
        guard let model = try? AddedGlucoseModel(contentsOf: url, configuration: configuration) else {
            print("Unable to instantiate CoreML model")
            return nil
        }
        
        guard let multiArray = try? MLMultiArray(shape: [1, 72], dataType: .float32) else {
            print("Failed to create MLMultiArray")
            return nil
        }
        
        let glucoseMin = Float32(47.787574839751585)
        let glucoseRange = Float32(272.88275806878147) - glucoseMin
        let iobMin = Float32(0)
        let iobRange = Float32(8.644954537307829) - iobMin
        let insulinDeliveredMin = Float32(0)
        let insulinDeliveredRange = Float32(5) - insulinDeliveredMin
        
        for (index, row) in dataFrame.enumerated() {
            multiArray[index] = NSNumber(value: (Float32(row.glucose) - glucoseMin) / glucoseRange)
            multiArray[index+24] = NSNumber(value: (Float32(row.insulinDelivered) - insulinDeliveredMin) / insulinDeliveredRange)
            multiArray[index+48] = NSNumber(value: (Float32(row.insulinOnBoard) - iobMin) / iobRange)
        }
        
        guard let prediction = try? model.prediction(input: AddedGlucoseModelInput(dense_input: multiArray)) else {
            print("model inference failed")
            return nil
        }
        
        let outputMin = Float32(-74.12046866558583)
        let outputRange = Float32(168.4840743910719) - outputMin
        return Double((prediction.Identity[0].floatValue * outputRange) + outputMin)
    }
}
