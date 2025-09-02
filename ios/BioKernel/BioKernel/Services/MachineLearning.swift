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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ssZZZZZ"
        let at = dateFormatter.string(from: Date())
        
        let logString = "\(at): AI temp basal: \(str)"
        print(logString)
        await getEventLogger().add(debugMessage: logString)
    }

    // This version of the algorithm is specifically to dose more insulin
    func tempBasal(settings: CodableSettings, glucoseInMgDl: Double, targetGlucoseInMgDl: Double, insulinOnBoard: Double, dataFrame: [AddedGlucoseDataRow]?, at: Date, pidTempBasal: PIDTempBasalResult) async -> Double? {
        
        await log("start")
        let dataFrame = dataFrame ?? []
        
        // since this model is just about dosing more, if we have been low at
        // all in the past two hours just bail
        let min = dataFrame.map({ $0.glucose }).min() ?? 75
        guard min >= 70 else { await log("low in dataFrame, bail"); return nil }
        
        // don't dose while exercising, we only want to handle spikes from meals
        await log("Checking if we're exercising")
        guard await !getWorkoutStatusService().isExercising(at: at) else { await log("is working out"); return nil }
        
        return glucosDynamicISF(glucose: glucoseInMgDl, targetGlucose: targetGlucoseInMgDl, pidTempBasal: pidTempBasal)
    }

    /// Simplified version of dynamicISF from Trio. Since dynamicISF isn't based on anything
    /// physiological -- it's just math to dose more when you're high -- let's keep the math super simple.
    ///
    /// Conceptually what this is trying to do is get the individual back into a more manageable range
    /// so that the more principled adaptations can take over.
    func glucosDynamicISF(glucose: Double, targetGlucose: Double, pidTempBasal: PIDTempBasalResult) -> Double? {

        // increase dose by up to 50%
        let maxInsulinScalingIncrease = 0.5
        let glucoseRangeForScaling = 150.0
        
        // This conceptually lowers insulin sensitivity for glucose values between
        // targetGlucose -> targetGlucose + 150 linearly to dose more
        // insulin while above target
        guard glucose > targetGlucose else { return nil }
        let scalingFactor = 1 + maxInsulinScalingIncrease * (glucose - targetGlucose) / glucoseRangeForScaling
        return pidTempBasal.tempBasal * scalingFactor.clamp(low: 1, high: 1 + maxInsulinScalingIncrease)
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
