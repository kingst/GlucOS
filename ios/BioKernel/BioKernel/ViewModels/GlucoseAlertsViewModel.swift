//
//  GlucoseAlertsViewModel.swift
//  BioKernel
//
//  Created by Sam King on 7/16/24.
//

import UserNotifications
import UIKit

@MainActor
public class GlucoseAlertsViewModel: ObservableObject {
    // for the never values we set it to 24 hours, which is close enough
    static let never = GlucoseAlertValue(id: "Never", value: 1440)
    let highLevelValues = stride(from: 140, through: 350, by: 10).map { GlucoseAlertValue(id: "\($0) mg/dl", value: $0)}
    let highRepeatsValues = [never] + stride(from:15, through: 60, by: 15).map { GlucoseAlertValue(id: "\($0)m", value: $0)} + [GlucoseAlertValue(id: "120m", value: 120), GlucoseAlertValue(id: "180m", value: 180)]
    let lowLevelValues = stride(from: 60, through: 100, by: 5).map { GlucoseAlertValue(id: "\($0) mg/dl", value: $0)}
    let lowRepeatsValues = [never] + stride(from:15, through: 60, by: 15).map { GlucoseAlertValue(id: "\($0)m", value: $0)}
    
    @Published var enabled = false
    @Published var highLevel = GlucoseAlertValue(id: "250 mg/dl", value: 250)
    @Published var highRepeats = never
    @Published var lowLevel = GlucoseAlertValue(id: "70 mg/dl", value: 70)
    @Published var lowRepeats = never
    @Published var alertString: String? = nil
    @Published var mostRecentPredictedGlucose: Double? = nil
    var alertStringFromSettings: String? = nil
    
    func glucoseAlertValue(from: Double) -> GlucoseAlertValue {
        let value = Int(from.rounded())
        return GlucoseAlertValue(id: "\(value) mg/dl", value: value)
    }
    func repeatsValue(fromSeconds: Double) -> GlucoseAlertValue {
        let value = Int(fromSeconds.secondsToMinutes().rounded())
        if value == GlucoseAlertsViewModel.never.value {
            return GlucoseAlertsViewModel.never
        }
        return GlucoseAlertValue(id: "\(value)m", value: value)
    }
    func update(settings: GlucoseAlertSettings, predictedGlucose: Double?) {
        enabled = settings.enabled
        highLevel = glucoseAlertValue(from: settings.highLevelMgDl)
        highRepeats = repeatsValue(fromSeconds: settings.highRepeatsSeconds)
        lowLevel = glucoseAlertValue(from: settings.lowLevelMgDl)
        lowRepeats = repeatsValue(fromSeconds: settings.lowRepeatsSeconds)
        alertStringFromSettings = settings.alertString
        mostRecentPredictedGlucose = predictedGlucose
        
        if settings.enabled {
            alertString = settings.alertString
        } else {
            alertString = nil
        }
    }
    
    func updateEnabled(_ enabled: Bool) {
        getGlucoseAlertsService().update(enabled: enabled)
        if enabled {
            alertString = alertStringFromSettings
            checkNotificationPermission()
        } else {
            alertString = nil
        }
    }
    func updateHighLevel(_ level: GlucoseAlertValue) {
        getGlucoseAlertsService().update(highLevelMgDl: Double(level.value))
        Task { await getGlucoseAlertsService().onNewGlucoseValue() }
    }
    func updateHighRepeats(_ minutes: GlucoseAlertValue) {
        getGlucoseAlertsService().update(highRepeatsSeconds: Double(minutes.value).minutesToSeconds())
    }
    func updateLowLevel(_ level: GlucoseAlertValue) {
        getGlucoseAlertsService().update(lowLevelMgDl: Double(level.value))
        Task { await getGlucoseAlertsService().onNewGlucoseValue() }
    }
    func updateLowRepeats(_ minutes: GlucoseAlertValue) {
        getGlucoseAlertsService().update(lowRepeatsSeconds: Double(minutes.value).minutesToSeconds())
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                getGlucoseAlertsService().update(notificationsPermissions: .authorized)
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } else {
                getGlucoseAlertsService().update(notificationsPermissions: .denied)
            }
            
            if let error = error {
                print("Error requesting notification permission: \(error.localizedDescription)")
            }
        }
    }
    
    private func checkNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized:
                getGlucoseAlertsService().update(notificationsPermissions: .authorized)
            case .denied:
                getGlucoseAlertsService().update(notificationsPermissions: .denied)
            case .notDetermined:
                self.requestNotificationPermission()
            case .provisional:
                print("Provisional notification permission granted")
            case .ephemeral:
                print("Ephemeral notification permission granted")
            @unknown default:
                print("Unknown notification permission status")
            }
        }
    }
}
