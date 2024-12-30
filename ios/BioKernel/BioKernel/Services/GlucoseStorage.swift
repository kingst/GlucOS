//
//  GlucoseStorage.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import HealthKit
import LoopKit

public protocol GlucoseStorage {
    func addCgmEvents(glucoseReadings: [NewGlucoseSample]) async
    func lastReading() async -> NewGlucoseSample?
    func readingsBetween(startDate: Date, endDate: Date) async -> [NewGlucoseSample]
}

public struct GlucoseChartPoint {
    let created: Date
    let readingInMgDl: Double
}

actor LocalGlucoseStorage: GlucoseStorage {
    static let shared = LocalGlucoseStorage()
    
    var glucoseReadings: [NewGlucoseSample]
    var storage = getStoredObject().create(fileName: "glucose.json")
    let replayLogger = getEventLogger()
    
    init() {
        glucoseReadings = (try? storage.read()) ?? []
        Task { await updateGlucoseChartData() }
    }
    
    func lastReading() async -> NewGlucoseSample? {
        return glucoseReadings.last
    }
    
    func readingsBetween(startDate: Date, endDate: Date) async -> [NewGlucoseSample] {
        let syncIdDict = glucoseReadings.reduce([String: NewGlucoseSample]()) { (dict, sample) in
            var mutableDict = dict
            mutableDict[sample.syncIdentifier] = sample
            return mutableDict
        }
        
        let samples = syncIdDict.values.sorted { $0.date < $1.date }
        return samples.filter { $0.date >= startDate && $0.date <= endDate }
    }
    
    func updateGlucoseChartData() async {
        let glucoseChartData = self.glucoseReadings.map { reading in
            let glucoseInMgDl = reading.quantity.doubleValue(for: .milligramsPerDeciliter, withRounding: true)
            return GlucoseChartPoint(created: reading.date, readingInMgDl: glucoseInMgDl)
        }
        await getDeviceDataManager().update(glucoseChartData: glucoseChartData.sorted(by: { $0.created < $1.created }))
    }
    
    func addCgmEvents(glucoseReadings: [NewGlucoseSample]) async {
        await replayLogger.add(events: glucoseReadings)
        self.glucoseReadings.append(contentsOf: glucoseReadings)
        self.glucoseReadings = self.glucoseReadings.sorted { $0.date < $1.date }
        if let mostRecent = glucoseReadings.last {
            let cutOff = mostRecent.date - 12.hoursToSeconds()
            self.glucoseReadings = self.glucoseReadings.filter({ $0.date > cutOff })
            let timeSinceLastReading = Date().timeIntervalSince(mostRecent.date)
            print("app refresh time: \(timeSinceLastReading)")
            if timeSinceLastReading < 5.minutesToSeconds() {
                await getGlucoseAlertsService().onNewGlucoseValue()
                print("resetting app refresh from CGM reading")
                // we have recent data so we can reset our background task
                await getBackgroundService().scheduleAppRefresh()
            }
        }
        
        do {
            try storage.write(self.glucoseReadings)
            await getWatchComms().updateAppContext()
            await updateGlucoseChartData()
        } catch {
            print("Failed to save glucose readings to disk")
        }
    }
}

extension NewGlucoseSample: Codable {
    // CodingKeys enum if needed
    enum CodingKeys: String, CodingKey {
        case date
        case quantity
        case condition
        case trend
        case trendRate
        case isDisplayOnly
        case wasUserEntered
        case syncIdentifier
        case syncVersion
        case device
    }

    private struct DeviceContainer: Codable {
        let name: String?
        let manufacturer: String?
        let model: String?
        let hardwareVersion: String?
        let firmwareVersion: String?
        let softwareVersion: String?
        let localIdentifier: String?
        let udiDeviceIdentifier: String?
        
        init(using device: HKDevice) {
            self.name = device.name
            self.manufacturer = device.manufacturer
            self.model = device.model
            self.hardwareVersion = device.hardwareVersion
            self.firmwareVersion = device.firmwareVersion
            self.softwareVersion = device.softwareVersion
            self.localIdentifier = device.localIdentifier
            self.udiDeviceIdentifier = device.udiDeviceIdentifier
        }
        
        func device() -> HKDevice { return HKDevice(name: name, manufacturer: manufacturer, model: model, hardwareVersion: hardwareVersion, firmwareVersion: firmwareVersion, softwareVersion: softwareVersion, localIdentifier: localIdentifier, udiDeviceIdentifier: udiDeviceIdentifier) }
    }

    // Implement Codable methods
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Decode each property into local variables
        let decodedDate = try container.decode(Date.self, forKey: .date)
        let decodedQuantityContainer = try container.decode(Double.self, forKey: .quantity)
        let decodedCondition = try container.decodeIfPresent(GlucoseCondition.self, forKey: .condition)
        let decodedTrend = try container.decodeIfPresent(GlucoseTrend.self, forKey: .trend)
        let decodedTrendRateContainer = try container.decodeIfPresent(Double.self, forKey: .trendRate)
        let decodedIsDisplayOnly = try container.decode(Bool.self, forKey: .isDisplayOnly)
        let decodedWasUserEntered = try container.decode(Bool.self, forKey: .wasUserEntered)
        let decodedSyncIdentifier = try container.decode(String.self, forKey: .syncIdentifier)
        let decodedSyncVersion = try container.decode(Int.self, forKey: .syncVersion)
        let decodedDeviceContainer = try container.decodeIfPresent(DeviceContainer.self, forKey: .device)
        
            // Extract values from QuantityContainer and DeviceContainer
        let decodedQuantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: decodedQuantityContainer)
        let decodedTrendRate = decodedTrendRateContainer.flatMap { HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0) }
        let decodedDevice = decodedDeviceContainer?.device()

        // Call self.init with the local variables
        self.init(date: decodedDate,
                  quantity: decodedQuantity,
                  condition: decodedCondition,
                  trend: decodedTrend,
                  trendRate: decodedTrendRate,
                  isDisplayOnly: decodedIsDisplayOnly,
                  wasUserEntered: decodedWasUserEntered,
                  syncIdentifier: decodedSyncIdentifier,
                  syncVersion: decodedSyncVersion,
                  device: decodedDevice)
        }

    public func encode(to encoder: Encoder) throws {
        let quantityInMgDl = quantity.doubleValue(for: .milligramsPerDeciliter)
        let trendRateInMgDlPerMinute = trendRate.flatMap { $0.doubleValue(for: .milligramsPerDeciliterPerMinute) }
        
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(quantityInMgDl, forKey: .quantity)
        try container.encodeIfPresent(condition, forKey: .condition)
        try container.encodeIfPresent(trend, forKey: .trend)
        try container.encodeIfPresent(trendRateInMgDlPerMinute, forKey: .trendRate)
        try container.encode(isDisplayOnly, forKey: .isDisplayOnly)
        try container.encode(wasUserEntered, forKey: .wasUserEntered)
        try container.encode(syncIdentifier, forKey: .syncIdentifier)
        try container.encode(syncVersion, forKey: .syncVersion)
        try container.encodeIfPresent(device.flatMap { DeviceContainer(using: $0) }, forKey: .device)
    }
}
