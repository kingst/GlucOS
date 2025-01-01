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

public enum WorkoutMessage: Codable {
    case started(at: Date, description: String, imageName: String)
    case ended(at: Date)
}

struct StateGlucoseReadings: Codable {
    let at: Date
    let glucoseReadingInMgDl: Double
    let trend: String?
}

public struct BioKernelState: Codable {
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

extension BioKernelState {
    static func preview() -> BioKernelState {
        // Create last 15 minutes of glucose readings
        let now = Date()
        var readings: [StateGlucoseReadings] = []
        
        // Generate readings every 5 minutes for the last hour
        for i in 0..<12 {
            let timestamp = now.addingTimeInterval(TimeInterval(-300 * i)) // 5 minutes * i
            // Create a somewhat realistic glucose curve
            let baseGlucose = 118.0
            let variation = sin(Double(i) * 0.5) * 15 // Add some wave-like variation
            let reading = StateGlucoseReadings(
                at: timestamp,
                glucoseReadingInMgDl: baseGlucose + variation,
                trend: ""
            )
            readings.append(reading)
        }
        readings.reverse()
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        
        // Create preview context
        let context: [String: Any] = [
            PayloadKeys.timestamp: now,
            PayloadKeys.predictedGlucose: 125.0,
            PayloadKeys.isPredictedGlucoseInRange: true,
            PayloadKeys.insulinOnBoard: 2.3,
            PayloadKeys.glucoseReadingsData: try! encoder.encode(readings)
        ]
        
        // Create preview state
        return try! BioKernelState(context)
    }
}
