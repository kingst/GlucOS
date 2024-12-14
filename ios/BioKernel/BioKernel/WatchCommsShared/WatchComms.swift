//
//  WatchComms.swift
//  BioKernel
//
//  Created by Sam King on 12/10/24.
//
import WatchConnectivity

struct PayloadKeys {
    static let timestamp = "timestamp"
    static let glucoseReadingsData = "glucoseReadingsData"
    static let predictedGlucose = "predictedGlucose"
    static let isPredictedGlucoseInRange = "isPredictedGlucoseInRange"
    static let insulinOnBoard = "insulinOnBoard"
}

struct StateGlucoseReadings: Codable {
    let at: Date
    let glucoseReadingInMgDl: Double
    let trend: String?
}

struct BioKernelState: Codable {
    let timestamp: Date
    let glucoseReadings: [StateGlucoseReadings]
    let predictedGlucose: Double
    let isPredictedGlucoseInRange: Bool
    let insulinOnBoard: Double?
    
    enum ParsingError: Error {
        case missingTimestamp
        case missingPredictedGlucose
        case missingGlucoseReadings
        case missingIsPredictedGlucoseInRange
    }
    
    init(_ context: [String: Any]) throws {
        guard let timestamp = context[PayloadKeys.timestamp] as? Date else {
            throw ParsingError.missingTimestamp
        }
        self.timestamp = timestamp
        
        guard let predictedGlucose = context[PayloadKeys.predictedGlucose] as? Double else {
            throw ParsingError.missingPredictedGlucose
        }
        self.predictedGlucose = predictedGlucose
        
        guard let isPredictedGlucoseInRange = context[PayloadKeys.isPredictedGlucoseInRange] as? Bool else {
            throw ParsingError.missingIsPredictedGlucoseInRange
        }
        self.isPredictedGlucoseInRange = isPredictedGlucoseInRange
        
        self.insulinOnBoard = context[PayloadKeys.insulinOnBoard] as? Double
        
        guard let readingsData = context[PayloadKeys.glucoseReadingsData] as? Data else {
            throw ParsingError.missingGlucoseReadings
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let readings = try? decoder.decode([StateGlucoseReadings].self, from: readingsData) else {
            throw ParsingError.missingGlucoseReadings
        }
        self.glucoseReadings = readings
    }
}
