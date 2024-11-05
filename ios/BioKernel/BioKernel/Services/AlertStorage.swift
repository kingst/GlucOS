//
//  AlarmStorage.swift
//  BioKernel
//
//  Created by Sam King on 11/12/23.
//
//  Note: I haven't figured out how to test this well yet, so who knows if it's correct

import Foundation
import LoopKit

protocol AlertStorage {
    func issueAlert(_ alert: LoopKit.Alert) async
    func retractAlert(identifier: LoopKit.Alert.Identifier) async
    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async -> Result<Bool, Error>
    func lookupAllUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error>
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error>
    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) async
    
    func activeAlert() async -> LoopKit.Alert?
}

// this struct is just a copy of PersistedAlert that we made Codable
public struct LocalPersistedAlert: Codable {
    public let alert: Alert
    public let issuedDate: Date
    public let retractedDate: Date?
    public let acknowledgedDate: Date?
    public init(alert: Alert, issuedDate: Date, retractedDate: Date?, acknowledgedDate: Date?) {
        self.alert = alert
        self.issuedDate = issuedDate
        self.retractedDate = retractedDate
        self.acknowledgedDate = acknowledgedDate
    }
    
    func toPersistedAlert() -> PersistedAlert {
        return PersistedAlert(alert: self.alert, issuedDate: self.issuedDate, retractedDate: self.retractedDate, acknowledgedDate: self.acknowledgedDate)
    }
}

actor LocalAlertStorage: AlertStorage {
    static let shared = LocalAlertStorage()
    
    var alerts: [LocalPersistedAlert] = []
    var hasDoneInitialReadFromDisk = false
    
    let storage = getStoredObject().create(fileName: "alerts.json")
    
    private func readFromDisk() async {
        guard !hasDoneInitialReadFromDisk else { return }
        alerts = (try? storage.read()) ?? []
        hasDoneInitialReadFromDisk = true
    }
    
    private func syncDataToDisk() {
        // just swallow these errors for now, eventually we can log these events and rebuild them from
        // the network event logger
        
        // FIXME: do some sort of pruining (low priority given the infrequency of alerts)
        try? storage.write(alerts)
    }
    
    func issueAlert(_ alert: LoopKit.Alert) async {
        await readFromDisk()
        let persistedAlert = LocalPersistedAlert(alert: alert, issuedDate: Date(), retractedDate: nil, acknowledgedDate: nil)
        alerts.append(persistedAlert)
        syncDataToDisk()
    }
    
    func retractAlert(identifier: LoopKit.Alert.Identifier) async {
        await readFromDisk()
        
        alerts = alerts.map { alert in
            if alert.alert.identifier == identifier {
                return LocalPersistedAlert(alert: alert.alert, issuedDate: alert.issuedDate, retractedDate: Date(), acknowledgedDate: alert.acknowledgedDate)
            } else {
                return alert
            }
        }
        
        syncDataToDisk()
    }
    
    func doesIssuedAlertExist(identifier: LoopKit.Alert.Identifier) async -> Result<Bool, Error> {
        await readFromDisk()
        let filteredAlerts = alerts.filter { $0.alert.identifier == identifier }
        return .success(filteredAlerts.count > 0)
    }
    
    func lookupAllUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error> {
        await readFromDisk()
        
        let unretractedAlerts = alerts.compactMap { alert in
            if alert.alert.identifier.managerIdentifier == managerIdentifier && alert.retractedDate == nil {
                return alert.toPersistedAlert()
            }
            
            return nil
        }
        
        return .success(unretractedAlerts)
    }
    
    func lookupAllUnacknowledgedUnretracted(managerIdentifier: String) async -> Result<[LoopKit.PersistedAlert], Error> {
        await readFromDisk()
        
        let unacknowledgedUnretractedAlerts = alerts.compactMap { alert in
            if alert.alert.identifier.managerIdentifier == managerIdentifier && alert.retractedDate == nil && alert.acknowledgedDate == nil {
                return alert.toPersistedAlert()
            }
            
            return nil
        }
        
        return .success(unacknowledgedUnretractedAlerts)
    }
    
    func recordRetractedAlert(_ alert: LoopKit.Alert, at date: Date) async {
        await readFromDisk()
        
        let persistedAlert = LocalPersistedAlert(alert: alert, issuedDate: date, retractedDate: date, acknowledgedDate: nil)
        alerts.append(persistedAlert)
        
        syncDataToDisk()
    }
    
    func activeAlert() async -> LoopKit.Alert? {
        await readFromDisk()
        
        let unacknowledgedUnretractedAlerts = alerts.filter { $0.retractedDate == nil && $0.acknowledgedDate == nil }
        
        // just return the most recent one for know but once we get more experience with alerts
        // we can formulate some sort of priority
        return unacknowledgedUnretractedAlerts.last?.alert
    }
}
