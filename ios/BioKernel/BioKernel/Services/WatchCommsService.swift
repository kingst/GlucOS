//
//  WatchCommsService.swift
//  BioKernel
//
//  Created by Sam King on 12/10/24.
//

import Foundation

protocol WatchComms {
    func updateAppContext() async
}

struct LocalWatchComms: WatchComms, SessionCommands {
    static let shared = LocalWatchComms()
    
    func updateAppContext() async {
        let now = Date()
        let glucose = await getGlucoseStorage().readingsBetween(startDate: now - 3.hoursToSeconds(), endDate: now).map { StateGlucoseReadings(at: $0.date, glucoseReadingInMgDl: $0.quantity.doubleValue(for: .milligramsPerDeciliter), trend: $0.trend?.symbol) }
        guard let mostRecentReading = glucose.last else { return }
        let prediction = await (getPhysiologicalModels().predictGlucoseIn15Minutes(from: now) ?? mostRecentReading.glucoseReadingInMgDl).clamp(low: 40.0, high: 400.0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let glucoseReadingData = try? encoder.encode(glucose) else {
            assertionFailure("Could not encode glucose readings")
            return
        }
        
        let isPredictedGlucoseInRange = await getGlucoseAlertsService().isInRange(glucose: prediction)
        
        updateAppContext([PayloadKeys.glucoseReadingsData: glucoseReadingData,
                          PayloadKeys.predictedGlucose: prediction,
                          PayloadKeys.timestamp: now,
                          PayloadKeys.isPredictedGlucoseInRange: isPredictedGlucoseInRange])
    }
}
