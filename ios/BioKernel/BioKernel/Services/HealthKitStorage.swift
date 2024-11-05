//
//  HealthKitStorage.swift
//  BioKernel
//
//  Created by Sam King on 11/12/23.
//

// We only store glucose and insulin in HealthKit. Both might have duplicates, but we include
// the syncIdentifier in our metadata so consuming software can clean it up and we have a function
// that we call from the UI to remove duplicates.
//
// The glucose data is solid, but we only store insulin doses that are already immutable. We do not
// include inferred basal insulin or ongoing tempBasal events or pump suspend / resume event, but
// people can use the event log if they want the full state.
//
// For getting a event log totpToken, the glucose readings are the best given the timeliness but the
// pump events should be fine as well since the server will accept totp tokens that are one or two
// epoch's behind
//
// to avoid deleting too many objects make sure that only one duplicate removal is running at any time

import HealthKit
import LoopKit

protocol HealthKitStorage {
    func save(_ glucoseSample: NewGlucoseSample, metadata: [String: Any]) async
    func save(_ pumpEvent: LoopKit.NewPumpEvent, metadata: [String: Any]) async
    func removeDuplicateEntries() async
    func fetchGlucoseSamples(startDate: Date, endDate: Date) async -> [HKQuantitySample]
    func fetchInsulinSamples(startDate: Date, endDate: Date) async -> [HKQuantitySample]
    func authorize() async throws
}

struct HealthKitMetadataKeys {
    static let eventLogIdKey = "bioKernel.eventLogId"
    static let totpTokenKey = "bioKernel.totpToken"
    static let syncIdentifierKey = "bioKernel.syncIdentifier"
    static let insulinTypeKey = "bioKernel.insulinType"
}

actor LocalHealthKitStorage: HealthKitStorage {
    static let shared = LocalHealthKitStorage()
    
    let healthStore = HKHealthStore()
    let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose)!
    let insulinType = HKObjectType.quantityType(forIdentifier: .insulinDelivery)!
    
    var isGlucoseDuplicateRemovalRunning = false
    var isInsulinDuplicateRemovalRunning = false
    
    func save(_ glucoseSample: LoopKit.NewGlucoseSample, metadata: [String: Any]) async {
        guard HKHealthStore.isHealthDataAvailable(), healthStore.authorizationStatus(for: glucoseType) == .sharingAuthorized else {
            return
        }
        
        do {
            let sample = glucoseSample.quantitySampleWithMetadata(metadata)
            try await healthStore.save(sample)
        } catch {
            print("LocalHealthKit: Error storing glucose: \(error)")
        }
        
        Task {
            guard !isGlucoseDuplicateRemovalRunning else { return }
            isGlucoseDuplicateRemovalRunning = true
            await removeDuplicateEntries(sampleType: glucoseType)
            isGlucoseDuplicateRemovalRunning = false
        }
    }
    
    func save(_ pumpEvent: LoopKit.NewPumpEvent, metadata: [String: Any]) async {
        guard HKHealthStore.isHealthDataAvailable(), healthStore.authorizationStatus(for: glucoseType) == .sharingAuthorized else {
            return
        }
        
        guard let dose = pumpEvent.dose, !dose.isMutable, let deliveredUnits = dose.deliveredUnits else { return }
        
        var metadataWithInsulin = metadata
        
        if let brandName = dose.insulinType?.brandName {
            metadataWithInsulin[HealthKitMetadataKeys.insulinTypeKey] = brandName
        }
        
        switch dose.type {
        case .basal, .tempBasal:
            let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: deliveredUnits)
            metadataWithInsulin[HKMetadataKeyInsulinDeliveryReason] = HKInsulinDeliveryReason.basal.rawValue
            let sample = HKQuantitySample(type: insulinType, quantity: quantity, start: dose.startDate, end: dose.endDate, metadata: metadataWithInsulin)
            do {
                try await healthStore.save(sample)
            } catch {
                print("LocalHealthKit: Error storing insulin: \(error)")
            }
        case .bolus:
            let quantity = HKQuantity(unit: .internationalUnit(), doubleValue: deliveredUnits)
            metadataWithInsulin[HKMetadataKeyInsulinDeliveryReason] = HKInsulinDeliveryReason.bolus.rawValue
            let sample = HKQuantitySample(type: insulinType, quantity: quantity, start: dose.startDate, end: dose.endDate, metadata: metadataWithInsulin)
            do {
                try await healthStore.save(sample)
            } catch {
                print("LocalHealthKit: Error storing insulin: \(error)")
            }
        default:
            break
        }
        
        Task {
            guard !isInsulinDuplicateRemovalRunning else { return }
            isInsulinDuplicateRemovalRunning = true
            await removeDuplicateEntries(sampleType: insulinType)
            isInsulinDuplicateRemovalRunning = false
        }
    }
    
    func removeDuplicateEntries() async {
        if !isGlucoseDuplicateRemovalRunning {
            isGlucoseDuplicateRemovalRunning = true
            await removeDuplicateEntries(sampleType: glucoseType)
            isGlucoseDuplicateRemovalRunning = false
        }
        
        if !isInsulinDuplicateRemovalRunning {
            isInsulinDuplicateRemovalRunning = true
            await removeDuplicateEntries(sampleType: insulinType)
            isInsulinDuplicateRemovalRunning = false
        }
    }
    
    func removeDuplicateEntries(sampleType: HKQuantityType) async {
        let endDate = Date()
        let startDate = endDate - 24.hoursToSeconds()
        let samples = await fetchSamples(startDate: startDate, endDate: endDate, sampleType: sampleType)
        
        var samplesToDelete: [HKQuantitySample] = []
        var syncIds = Set<String>()
        for sample in samples {
            if let syncId = sample.metadata?[HealthKitMetadataKeys.syncIdentifierKey] as? String {
                if syncIds.contains(syncId) {
                    samplesToDelete.append(sample)
                } else {
                    syncIds.insert(syncId)
                }
            }
        }
        
        try? await healthStore.delete(samplesToDelete)
    }
    
    func fetchSamples(startDate: Date, endDate: Date, sampleType: HKQuantityType) async -> [HKQuantitySample] {
        return await withCheckedContinuation() { continuation in
            fetchSamples(startDate: startDate, endDate: endDate, sampleType: sampleType) { queriedSamples in
                continuation.resume(returning: queriedSamples)
            }
        }
    }
    
    func fetchGlucoseSamples(startDate: Date, endDate: Date) async -> [HKQuantitySample] {
        await fetchSamples(startDate: startDate, endDate: endDate, sampleType: glucoseType)
    }
    func fetchInsulinSamples(startDate: Date, endDate: Date) async -> [HKQuantitySample] {
        await fetchSamples(startDate: startDate, endDate: endDate, sampleType: insulinType)
    }
    
    func fetchSamples(startDate: Date, endDate: Date, sampleType: HKQuantityType, completion: @escaping ([HKQuantitySample]) -> Void) {
        let datePredicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate, .strictEndDate])
        let query = HKSampleQuery(sampleType: sampleType, predicate: datePredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { (query, results, error) in
            completion(results as? [HKQuantitySample] ?? [])
        }
        healthStore.execute(query)
    }
    
    func authorize() async throws {
        let typesToShare: Set<HKSampleType> = [glucoseType, insulinType]
        try await healthStore.requestAuthorization(toShare: typesToShare, read: typesToShare)
    }
}

extension NewGlucoseSample {
    func quantitySampleWithMetadata(_ metadata: [String: Any]?) -> HKQuantitySample {
        return HKQuantitySample(type: self.quantitySample.quantityType, quantity: self.quantity, start: self.date, end: self.date, device: self.device, metadata: metadata)
    }
}
