//
//  GlucoseAlertStorage.swift
//  BioKernel
//
//  Created by Sam King on 7/16/24.
//

import Foundation
import UserNotifications


public enum NotificationPermissions: String, Codable {
    case notDetermined = "notDetermined"
    case denied = "denied"
    case authorized = "authorized"
}

public enum GlucoseAlertState: String, Codable {
    case predictedHigh = "predictedHigh"
    case predictedLow = "predictedLow"
    case inRange = "inRange"
}

public struct GlucoseAlertSettings: Codable {
    let updatedAt: Date
    let enabled: Bool
    let highLevelMgDl: Double
    let highRepeatsSeconds: Double
    let lowLevelMgDl: Double
    let lowRepeatsSeconds: Double
    let alertState: GlucoseAlertState
    let alertString: String?
    let notificationsPermissions: NotificationPermissions
    
    static func defaults() -> GlucoseAlertSettings {
        let now = Date()
        return GlucoseAlertSettings(updatedAt: now, enabled: false, highLevelMgDl: 250, highRepeatsSeconds: 30.minutesToSeconds(), lowLevelMgDl: 70, lowRepeatsSeconds: 30.minutesToSeconds(), alertState: .inRange, alertString: nil, notificationsPermissions: .notDetermined)
    }
    
    func updated(enabled: Bool) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: enabled, highLevelMgDl: self.highLevelMgDl, highRepeatsSeconds: self.highRepeatsSeconds, lowLevelMgDl: self.lowLevelMgDl, lowRepeatsSeconds: self.lowRepeatsSeconds, alertState: self.alertState, alertString: self.alertString, notificationsPermissions: self.notificationsPermissions)
    }
    func updated(highLevelMgDl: Double) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: self.enabled, highLevelMgDl: highLevelMgDl, highRepeatsSeconds: self.highRepeatsSeconds, lowLevelMgDl: self.lowLevelMgDl, lowRepeatsSeconds: self.lowRepeatsSeconds, alertState: self.alertState, alertString: self.alertString, notificationsPermissions: self.notificationsPermissions)
    }
    func updated(highRepeatsSeconds: Double) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: self.enabled, highLevelMgDl: self.highLevelMgDl, highRepeatsSeconds: highRepeatsSeconds, lowLevelMgDl: self.lowLevelMgDl, lowRepeatsSeconds: self.lowRepeatsSeconds, alertState: self.alertState, alertString: self.alertString, notificationsPermissions: self.notificationsPermissions)
    }
    func updated(lowLevelMgDl: Double) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: self.enabled, highLevelMgDl: self.highLevelMgDl, highRepeatsSeconds: self.highRepeatsSeconds, lowLevelMgDl: lowLevelMgDl, lowRepeatsSeconds: self.lowRepeatsSeconds, alertState: self.alertState, alertString: self.alertString, notificationsPermissions: self.notificationsPermissions)
    }
    func updated(lowRepeatsSeconds: Double) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: self.enabled, highLevelMgDl: self.highLevelMgDl, highRepeatsSeconds: self.highRepeatsSeconds, lowLevelMgDl: self.lowLevelMgDl, lowRepeatsSeconds: lowRepeatsSeconds, alertState: self.alertState, alertString: self.alertString, notificationsPermissions: self.notificationsPermissions)
    }
    func updated(alertState: GlucoseAlertState, alertString: String?) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: self.enabled, highLevelMgDl: self.highLevelMgDl, highRepeatsSeconds: self.highRepeatsSeconds, lowLevelMgDl: self.lowLevelMgDl, lowRepeatsSeconds: self.lowRepeatsSeconds, alertState: alertState, alertString: alertString, notificationsPermissions: self.notificationsPermissions)
    }
    func updated(notificationsPermissions: NotificationPermissions) -> GlucoseAlertSettings {
        return GlucoseAlertSettings(updatedAt: Date(), enabled: self.enabled, highLevelMgDl: self.highLevelMgDl, highRepeatsSeconds: self.highRepeatsSeconds, lowLevelMgDl: self.lowLevelMgDl, lowRepeatsSeconds: self.lowRepeatsSeconds, alertState: self.alertState, alertString: self.alertString, notificationsPermissions: notificationsPermissions)
    }
    
    func nextState(predictedGlucose: Double) -> GlucoseAlertState {
        switch (predictedGlucose) {
        case _ where predictedGlucose >= self.highLevelMgDl:
            return .predictedHigh
        case _ where predictedGlucose <= self.lowLevelMgDl:
            return .predictedLow
        default:
            return .inRange
        }
    }
}

public struct GlucoseAlert: Codable {
    let at: Date
    let predictedGlucose: Double
    let glucose: Double
    let sentNotification: Bool
    let alertState: GlucoseAlertState
    let alertString: String?
    let settings: GlucoseAlertSettings
}

@MainActor
public protocol GlucoseAlertStorage {
    func viewModel() -> GlucoseAlertsViewModel
    func update(enabled: Bool)
    func update(highLevelMgDl: Double)
    func update(highRepeatsSeconds: Double)
    func update(lowLevelMgDl: Double)
    func update(lowRepeatsSeconds: Double)
    func update(notificationsPermissions: NotificationPermissions)
    func onNewGlucoseValue() async
    func isInRange(glucose: Double) -> Bool
}

@MainActor
class PredictiveGlucoseAlertStorage: GlucoseAlertStorage {
    static let shared = PredictiveGlucoseAlertStorage()
    
    let alertViewModel = GlucoseAlertsViewModel()
    var glucoseAlertSettings: GlucoseAlertSettings
    var storage = getStoredObject().create(fileName: "glucose_alerts.json")
    let replayLogger = getEventLogger()
    let notificationIdKey = "notificationId"
    let notificationSentAtKey = "notificationSentAt"
    
    init() {
        let settings = (try? storage.read()) ?? GlucoseAlertSettings.defaults()
        glucoseAlertSettings = settings
        DispatchQueue.main.async {
            self.alertViewModel.update(settings: settings, predictedGlucose: nil)
        }
    }
    func viewModel() -> GlucoseAlertsViewModel {
        return alertViewModel
    }
    
    func isInRange(glucose: Double) -> Bool {
        return glucoseAlertSettings.highLevelMgDl >= glucose && glucose >= glucoseAlertSettings.lowLevelMgDl
    }
    
    func clearCurrentNotification() {
        guard let notificationId = UserDefaults.standard.string(forKey: notificationIdKey) else { return }
        NotificationManager.shared.removeDeliveredNotification(withIdentifier: notificationId)
        UserDefaults.standard.setValue(nil, forKey: notificationIdKey)
        UserDefaults.standard.setValue(nil, forKey: notificationSentAtKey)
    }
    
    func scheduleNotification(at: Date, alertString: String) {
        clearCurrentNotification()
        print("NOTIF: schedule notification")
        let notificationId = NotificationManager.shared.scheduleNotification(title: "BeaGL Alert", body: alertString, timeInterval: 10)
        UserDefaults.standard.setValue(notificationId, forKey: notificationIdKey)
        UserDefaults.standard.setValue(at, forKey: notificationSentAtKey)
    }
    
    func updateNotification(alertString: String) {
        guard let notificationId = UserDefaults.standard.string(forKey: notificationIdKey) else { return }
        NotificationManager.shared.updateDeliveredNotification(withIdentifier: notificationId, newBody: alertString)
    }
    
    func updateNotification(at: Date, currentState: GlucoseAlertState, nextState: GlucoseAlertState, alertString: String?) -> Bool {
        let alertString = alertString ?? "Your glucose is in range"
        
        let notificationSentAt = UserDefaults.standard.object(forKey: notificationSentAtKey) as? Date
        // add a minute to deal with sensor timing noise, etc
        let duration = (notificationSentAt.map({ at.timeIntervalSince($0) }) ?? 24.hoursToSeconds()) + 1.minutesToSeconds()
        print("NOTIF: duration \(duration.secondsToMinutes())m")
        switch(currentState, nextState) {
        case (_, .inRange):
            print("NOTIF: in range, clear notifications")
            clearCurrentNotification()
            return false
        case (.predictedHigh, .predictedHigh):
            if duration > glucoseAlertSettings.highRepeatsSeconds {
                print("NOTIF: repeat notification for high")
                scheduleNotification(at: at, alertString: alertString)
                return true
            } else {
                print("NOTIF: update prediction for high")
                updateNotification(alertString: alertString)
                return false
            }
        case (.predictedLow, .predictedHigh), (.inRange, .predictedHigh):
            scheduleNotification(at: at, alertString: alertString)
            print("NOTIF: high state transition, send notification")
            return true
        case (.predictedLow, .predictedLow):
            if duration > glucoseAlertSettings.lowRepeatsSeconds {
                print("NOTIF: repeat notification for low")
                scheduleNotification(at: at, alertString: alertString)
                return true
            } else {
                print("NOTIF: update prediction for low")
                updateNotification(alertString: alertString)
                return false
            }
        case (.predictedHigh, .predictedLow), (.inRange, .predictedLow):
            print("NOTIF: low state transition, send notification")
            scheduleNotification(at: at, alertString: alertString)
            return true
        }
    }
    
    func createAlertString(predictedGlucose: Double) -> String {
        let glucose = Int(predictedGlucose.rounded())
        switch (glucose) {
        case 400...:
            return "Your glucose is predicted to be above 400 mg/dl"
        case ...39:
            return "Your glucose is predicted to be below 40 mg/dl"
        default:
            return "Your glucose is predicted to be \(glucose) mg/dl in 15 min."
        }
    }
    
    func onNewGlucoseValue() async {
        let now = Date()
        guard let mostRecentGlucose = await getGlucoseStorage().lastReading()?.quantity.doubleValue(for: .milligramsPerDeciliter) else { return }
        let predictedGlucose = await getPhysiologicalModels().predictGlucoseIn15Minutes(from: now) ?? mostRecentGlucose
        let currentState = glucoseAlertSettings.alertState
        let nextState = glucoseAlertSettings.nextState(predictedGlucose: predictedGlucose)
        
        let alertString = nextState == .inRange ? nil : createAlertString(predictedGlucose: predictedGlucose)
        let sentNotification = updateNotification(at: now, currentState: currentState, nextState: nextState, alertString: alertString)
        
        // log the result with the settings _before_ we update them based on these results
        await getEventLogger().add(glucoseAlert: GlucoseAlert(at: now, predictedGlucose: predictedGlucose, glucose: mostRecentGlucose, sentNotification: sentNotification, alertState: nextState, alertString: alertString, settings: glucoseAlertSettings))
        
        let newSettings = glucoseAlertSettings.updated(alertState: nextState, alertString: alertString)
        update(alertSettings: newSettings)
        
        print("Predicted: \(predictedGlucose)")
        
        DispatchQueue.main.async {
            self.alertViewModel.update(settings: newSettings, predictedGlucose: predictedGlucose)
        }
    }
    
    func update(enabled: Bool) {
        update(alertSettings: glucoseAlertSettings.updated(enabled: enabled))
    }
    func update(highLevelMgDl: Double) {
        update(alertSettings: glucoseAlertSettings.updated(highLevelMgDl: highLevelMgDl))
    }
    func update(highRepeatsSeconds: Double) {
        update(alertSettings: glucoseAlertSettings.updated(highRepeatsSeconds: highRepeatsSeconds))
    }
    func update(lowLevelMgDl: Double) {
        update(alertSettings: glucoseAlertSettings.updated(lowLevelMgDl: lowLevelMgDl))
    }
    func update(lowRepeatsSeconds: Double) {
        update(alertSettings: glucoseAlertSettings.updated(lowRepeatsSeconds: lowRepeatsSeconds))
    }
    func update(notificationsPermissions: NotificationPermissions) {
        update(alertSettings: glucoseAlertSettings.updated(notificationsPermissions: notificationsPermissions))
    }
    private func update(alertSettings: GlucoseAlertSettings) {
        self.glucoseAlertSettings = alertSettings
        do {
            try storage.write(alertSettings)
        } catch {
            print("Could not write glucose alert settings to disk")
        }
    }
}
