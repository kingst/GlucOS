//
//  SaveDataViewModel.swift
//  BioKernel
//
//  Created by Sam King on 9/4/24.
//

import SwiftUI
import HealthKit
import LoopKit

public struct HealthKitInsulinRecord: Codable {
    let startDate: Date
    let endDate: Date
    let insulinDelivered: Double
    let insulinType: String?
}

public struct HealthKitGlucoseRecord: Codable {
    let at: Date
    let glucoseInMgDl: Double
}

public struct HealthKitRecords: Codable {
    let at: Date
    let glucose: [HealthKitGlucoseRecord]
    let insulin: [HealthKitInsulinRecord]
}

public struct HealthKitRecordsResponse: Codable {
    let result: String
}

@MainActor
public class SaveDataViewModel: ObservableObject {
    @Published var status = ""
    @Published var saveComplete = true
    
    func extractInsulinType(samples: [HKQuantitySample]) -> [String?] {
        return samples.map{ $0.metadata?["com.loopkit.InsulinKit.MetadataKeyInsulinType"] as? String }
    }
        
    func saveData() async {
        saveComplete = false
        defer { saveComplete = true }
        status = "Authorizing health kit"
        do {
            try await getHealthKitStorage().authorize()
        } catch {
            status = "Health kit not authorized"
            return
        }
        status = "Fetching HealthKit data"
        let endDate = Date()
        let startDate = endDate - 30.daysToSeconds()
        let glucoseSamples = await getHealthKitStorage().fetchGlucoseSamples(startDate: startDate, endDate: endDate)
        print("Glucose sample count: \(glucoseSamples.count)")
        let glucose = glucoseSamples.map { HealthKitGlucoseRecord(at: $0.startDate, glucoseInMgDl: $0.quantity.doubleValue(for: .milligramsPerDeciliter)) }
        let insulinSamples = await getHealthKitStorage().fetchInsulinSamples(startDate: startDate, endDate: endDate)
        let insulinTypes = extractInsulinType(samples: insulinSamples)
        print("Insulin sample count: \(insulinSamples.count)")
        let insulin = zip(insulinSamples, insulinTypes).map { (sample, type) in
            HealthKitInsulinRecord(startDate: sample.startDate, endDate: sample.endDate, insulinDelivered: sample.quantity.doubleValue(for: .internationalUnit()), insulinType: type)
        }
        // split this into two for now because the entity is too big otherwise
        let glucoseRecords = HealthKitRecords(at: endDate, glucose: glucose, insulin: [])
        let insulinRecords = HealthKitRecords(at: endDate, glucose: [], insulin: insulin)
        
        let glucoseSuccess = await getEventLogger().upload(healthKitRecords: glucoseRecords)
        let insulinSuccess = await getEventLogger().upload(healthKitRecords: insulinRecords)
        
        status = glucoseSuccess && insulinSuccess ? "Success" : "Failed to upload"
    }
}
