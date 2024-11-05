//
//  ReplayLogger.swift
//  BioKernel
//
//  Created by Sam King on 11/22/23.
//

import CryptoKit
import LoopKit
import G7SensorKit

public protocol EventLogger {
    func add(events: [NewPumpEvent]) async
    func add(events: [NewGlucoseSample]) async
    func add(events: [ClosedLoopResult]) async
    func add(events: [GlucoseAlert]) async
    func add(debugMessage: String) async
    func upload(healthKitRecords: HealthKitRecords) async -> Bool
    func update(deviceToken: String) async
    func getReadOnlyAuthToken() async -> String?
}

extension EventLogger {
    func add(glucoseAlert: GlucoseAlert) async {
        await add(events: [glucoseAlert])
    }
}

public struct DeviceTokenRequest: Codable {
    let deviceToken: String
}

struct DeviceTokenResponse: Codable {
    let result: String
}

actor LocalEventLogger: EventLogger, G7DebugLogger {
    nonisolated func log(category: String, type: String, message: String) {
        let at = Date()
        let debugMessage = "G7DebugLogger: [\(at)] [\(category)] [\(type)] \(message)"
        Task {
            await self.add(debugMessage: debugMessage)
        }
    }
    
    struct ResponseObject: Decodable {
        let ctime: Date
        let eventLogId: String
        let identifier: String
        let pumpEvents: [NewPumpEvent]?
        let glucoseEvents: [NewGlucoseSample]?
        let closedLoopEvents: [ClosedLoopResult]?
        let glucoseAlerts: [GlucoseAlert]?
    }
    
    struct RequestObject: Codable {
        let identifier: String
        let pumpEvents: [NewPumpEvent]?
        let glucoseEvents: [NewGlucoseSample]?
        let closedLoopEvents: [ClosedLoopResult]?
        let glucoseAlerts: [GlucoseAlert]?
        let debugMessage: String?
        
        static func createFrom(pumpEvents: [NewPumpEvent]) -> RequestObject {
            return RequestObject(identifier: UUID().uuidString, pumpEvents: pumpEvents, glucoseEvents: nil, closedLoopEvents: nil, glucoseAlerts: nil, debugMessage: nil)
        }
        
        static func createFrom(glucoseEvents: [NewGlucoseSample]) -> RequestObject {
            return RequestObject(identifier: UUID().uuidString, pumpEvents: nil, glucoseEvents: glucoseEvents, closedLoopEvents: nil, glucoseAlerts: nil, debugMessage: nil)
        }
        
        static func createFrom(closedLoopEvents: [ClosedLoopResult]) -> RequestObject {
            return RequestObject(identifier: UUID().uuidString, pumpEvents: nil, glucoseEvents: nil, closedLoopEvents: closedLoopEvents, glucoseAlerts: nil, debugMessage: nil)
        }
        
        static func createFrom(glucoseAlerts: [GlucoseAlert]) -> RequestObject {
            return RequestObject(identifier: UUID().uuidString, pumpEvents: nil, glucoseEvents: nil, closedLoopEvents: nil, glucoseAlerts: glucoseAlerts, debugMessage: nil)
        }
        
        static func createFrom(debugMessage: String) -> RequestObject {
            return RequestObject(identifier: UUID().uuidString, pumpEvents: nil, glucoseEvents: nil, closedLoopEvents: nil, glucoseAlerts: nil, debugMessage: debugMessage)
        }
    }
    
    static let shared = LocalEventLogger()
    let baseUrl = "https://event-log-server.uc.r.appspot.com"
    //let baseUrl = "http://127.0.0.1:8080"
    let storedEventsToRetry = getStoredObject().create(fileName: "replay_retry_events.json")
    let maxEventsToRetry = 4096
    var retryTaskRunning = false
    var runningRequests = Set<String>()
    let healthKitStorage = getHealthKitStorage()
    
    func add(events: [NewPumpEvent]) async {
        uploadEvents(RequestObject.createFrom(pumpEvents: events))
        for event in events {
            let metadata = await getMetadataForHealthKit(at: event.date, syncIdentifier: event.dose?.syncIdentifier ?? UUID().uuidString) ?? [:]
            await healthKitStorage.save(event, metadata: metadata)
        }
    }
    
    func add(events: [NewGlucoseSample]) async {
        uploadEvents(RequestObject.createFrom(glucoseEvents: events))
        for reading in events {
            let metadata = await getMetadataForHealthKit(at: reading.date, syncIdentifier: reading.syncIdentifier) ?? [:]
            await healthKitStorage.save(reading, metadata: metadata)
        }
    }
    
    func add(events: [ClosedLoopResult]) async {
        uploadEvents(RequestObject.createFrom(closedLoopEvents: events))
    }
    
    func add(events: [GlucoseAlert]) async {
        uploadEvents(RequestObject.createFrom(glucoseAlerts: events))
    }
    
    func add(debugMessage: String) async {
        uploadEvents(RequestObject.createFrom(debugMessage: debugMessage))
    }
    
    func retryRequests() async {
        let requestsToRetry: [RequestObject] = (try? storedEventsToRetry.read()) ?? []
        print("we have \(requestsToRetry.count) events to retry")
        for request in requestsToRetry {
            if !runningRequests.contains(request.identifier) {
                let success = await post(request)
                if success {
                    print("retried event posted successfully, removing")
                    removeFromEventsToRetry(request)
                }
            }
        }
    }
    
    func uploadEvents(_ requestObject: RequestObject) {
        addToEventsToRetry(requestObject)
        runningRequests.insert(requestObject.identifier)
        
        Task {
            print("Posting events")
            let success = await post(requestObject)
            runningRequests.remove(requestObject.identifier)
            if success {
                print("success, removing event from events to retry")
                removeFromEventsToRetry(requestObject)
            }
            
            print("Looking for more events to post")
            if !retryTaskRunning {
                retryTaskRunning = true
                await retryRequests()
                retryTaskRunning = false
            }
        }
    }
    
    private func addToEventsToRetry(_ requestObject: RequestObject) {
        var events: [RequestObject] = (try? storedEventsToRetry.read()) ?? []
        events.append(requestObject)
        // limit the size of the amount of data we store on disk
        if events.count > maxEventsToRetry {
            events = events.dropFirst(events.count - maxEventsToRetry).map { $0 }
        }
        try? storedEventsToRetry.write(events)
    }
    
    private func removeFromEventsToRetry(_ requestObject: RequestObject) {
        var events: [RequestObject] = (try? storedEventsToRetry.read()) ?? []
        events = events.filter { $0.identifier != requestObject.identifier }
        try? storedEventsToRetry.write(events)
    }
    
    private func post(_ requestObject: RequestObject) async -> Bool {
        let http = getJsonHttp()
        let url = "\(baseUrl)/v1/event_log/append"
        
        guard let authToken = await getAuthToken() else { return false }
        
        let response: Array<ResponseObject>? = await http.post(url: url, data: requestObject, headers: ["x-auth-token": authToken])
        print("response ctime: \(response?.first?.ctime.formatted() ?? "no ctime set") \(response?.first?.ctime.timeIntervalSince1970 ?? 0.0)")
        return response != nil
    }
    
    func upload(healthKitRecords: HealthKitRecords) async -> Bool {
        let http = getJsonHttp()
        let url = "\(baseUrl)/v1/event_log/health_kit_records"
        
        guard let authToken = await getAuthToken() else { return false }
        
        let response: HealthKitRecordsResponse? = await http.post(url: url, data: healthKitRecords, headers: ["x-auth-token": authToken])

        return response != nil
    }
    
    func update(deviceToken: String) async {
        let deviceTokenRequest = DeviceTokenRequest(deviceToken: deviceToken)
        let http = getJsonHttp()
        let url = "\(baseUrl)/v1/event_log/push_device_token"
        
        guard let authToken = await getAuthToken() else { return }
        
        let _: DeviceTokenResponse? = await http.post(url: url, data: deviceTokenRequest, headers: ["x-auth-token": authToken])
    }
    
    struct ReadOnlyResponse: Codable {
        let eventLogId: String
        let authToken: String
    }
    
    struct EventLoggerAuth: Codable {
        let eventLogId: String
        let authToken: String
        let totpSecret: String
        let totpDurationInSeconds: Int
        
        func totpToken(at: Date) -> String? {
            let password = self.totpSecret
            let message = "\(Int(at.timeIntervalSince1970 / Double(self.totpDurationInSeconds)))"
            guard let passwordData = password.data(using: .utf8) else {
                print("Error converting password to data.")
                return nil
            }

            let derivedKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: passwordData), outputByteCount: 32)
            let hmac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: derivedKey)

            return Data(hmac).hex()
        }
    }
    
    private func getMetadataForHealthKit(at: Date, syncIdentifier: String) async -> [String: Any]? {
        guard let eventLoggerAuth: EventLoggerAuth = UserDefaults.standard.json(forKey: "eventLoggerAuth") else { return nil }
        guard let totpToken = eventLoggerAuth.totpToken(at: at) else { return nil }
        
        return [HealthKitMetadataKeys.eventLogIdKey: eventLoggerAuth.eventLogId,
                HealthKitMetadataKeys.totpTokenKey: totpToken,
                HealthKitMetadataKeys.syncIdentifierKey: syncIdentifier]
    }
    
    func getReadOnlyAuthToken() async -> String? {
        if let readOnlyAuth: ReadOnlyResponse = UserDefaults.standard.json(forKey: "eventLoggerReadOnlyAuth") {
            return readOnlyAuth.authToken
        }
        
        guard let authToken = await getAuthToken() else {
            return nil
        }
        
        print("Creating a read only token")
        let url = "\(baseUrl)/v1/event_log/auth/exchange_for_read_only_auth_token"
        guard let readOnlyAuth: ReadOnlyResponse = await getJsonHttp().get(url: url, headers: ["x-auth-token": authToken]) else {
            print("failed to get read only auth token")
            return nil
        }
        
        UserDefaults.standard.set(json: readOnlyAuth, forKey: "eventLoggerReadOnlyAuth")
        return readOnlyAuth.authToken
    }
    
    private func getAuthToken() async -> String? {
        if let eventLoggerAuth: EventLoggerAuth = UserDefaults.standard.json(forKey: "eventLoggerAuth") {
            return eventLoggerAuth.authToken
        }
        
        print("Creating an event log on the server...")
        let eventLogId = UUID().uuidString
        let url = "\(baseUrl)/v1/event_log/auth/\(eventLogId)/auth_token"
        guard let eventLoggerAuth: EventLoggerAuth = await getJsonHttp().get(url: url) else {
            return nil
        }
        
        UserDefaults.standard.set(json: eventLoggerAuth, forKey: "eventLoggerAuth")
        return eventLoggerAuth.authToken
    }
}

extension Data {
    // Convert Data to hex string
    func hex() -> String {
        return map { String(format: "%02hhx", $0) }.joined()
    }
}
