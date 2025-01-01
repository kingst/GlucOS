//
//  PumpManagerExtensions.swift
//  BioKernel
//
//  Created by Sam King on 11/2/23.
//

import LoopKit
import LoopKitUI
import MockKit
import MockKitUI
import SwiftUI
 
extension PumpManager {

    typealias RawValue = [String: Any]
    
    var rawValue: RawValue {
        return [
            "managerIdentifier": self.managerIdentifier,
            "state": self.rawState
        ]
    }
}

extension PumpManagerDescriptor: @retroactive Hashable, @retroactive Identifiable {
    public var id: String { self.identifier }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.identifier)
    }
    
    public static func == (lhs: PumpManagerDescriptor, rhs: PumpManagerDescriptor) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}

extension CGMManagerDescriptor: @retroactive Hashable, @retroactive Identifiable {
    public var id: String { self.identifier }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.identifier)
    }
    
    public static func == (lhs: CGMManagerDescriptor, rhs: CGMManagerDescriptor) -> Bool {
        return lhs.identifier == rhs.identifier
    }
}

extension PumpManager {
    func ensureCurrentPumpData() async -> Date? {
        return await withCheckedContinuation { continuation in
            self.ensureCurrentPumpData() { lastSync in
                continuation.resume(returning: lastSync)
            }
        }
    }
    
    func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>]) async -> Error? {
        return await withCheckedContinuation { continuation in
            self.syncBasalRateSchedule(items: scheduleItems) { result in
                switch result {
                case .success:
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(returning: error)
                }
            }
        }
    }
    
    func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits) async -> Error? {
        return await withCheckedContinuation { continuation in
            self.syncDeliveryLimits(limits: deliveryLimits) { result in
                switch result {
                case .success:
                    continuation.resume(returning: nil)
                case .failure(let error):
                    continuation.resume(returning: error)
                }
            }
        }
    }
    
    func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval) async -> PumpManagerError? {
        return await withCheckedContinuation { continuation in
            self.enactTempBasal(unitsPerHour: unitsPerHour, for: duration) { error in
                continuation.resume(returning: error)
            }
        }
    }
    
    func cancelTempBasal() async -> PumpManagerError? {
        return await withCheckedContinuation { continuation in
            self.enactTempBasal(unitsPerHour: 0, for: 0) { error in
                continuation.resume(returning: error)
            }
        }
    }
    
    func enactBolus(units: Double, activationType: BolusActivationType) async -> PumpManagerError? {
        return await withCheckedContinuation { continuation in
            self.enactBolus(units: units, activationType: activationType) { error in
                if error == nil {
                    DispatchQueue.main.async {
                        if let progress = self.createBolusProgressReporter(reportingOn: .main) {
                            getDeviceDataManager().update(totalAmount:units, bolusProgressReporter: progress)
                        }
                    }
                }
                continuation.resume(returning: error)
            }
        }
    }
}

extension CGMManager {
    func fetchNewDataIfNeeded() async -> CGMReadingResult {
        return await withCheckedContinuation { continuation in
            self.fetchNewDataIfNeeded { result in
                continuation.resume(returning: result)
            }
        }
    }
}
