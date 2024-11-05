//
//  NotificationManager.swift
//  BioKernel
//
//  Created by Sam King on 7/17/24.
//

import UserNotifications

class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    func scheduleNotification(title: String, body: String, timeInterval: TimeInterval) -> String {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: timeInterval, repeats: false)
        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            } else {
                print("Notification scheduled successfully with identifier: \(identifier)")
            }
        }
        
        return identifier
    }
    
    func removeDeliveredNotification(withIdentifier identifier: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        print("Removed delivered notification with identifier: \(identifier)")
    }
    
    func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        print("Removed all delivered notifications")
    }
    
    func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            completion(notifications)
        }
    }
    
    func updateDeliveredNotification(withIdentifier identifier: String, newBody: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            guard let notification = notifications.first(where: { $0.request.identifier == identifier }) else {
                print("No delivered notification found with identifier: \(identifier)")
                return
            }
            
            let updatedContent = notification.request.content.mutableCopy() as! UNMutableNotificationContent
            updatedContent.body = newBody
            updatedContent.sound = nil
            updatedContent.interruptionLevel = .passive
            
            NotificationManager.shared.removeDeliveredNotification(withIdentifier: identifier)
            
            let updatedRequest = UNNotificationRequest(identifier: identifier, content: updatedContent, trigger: nil)
            
            UNUserNotificationCenter.current().add(updatedRequest) { error in
                if let error = error {
                    print("NOTIF: Error updating notification: \(error)")
                } else {
                    print("NOTIF: Notification updated successfully with identifier: \(identifier)")
                }
            }
        }
    }
}
