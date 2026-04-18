//
//  PushNotificationService.swift
//  BioKernel
//

import UIKit

@MainActor protocol PushNotificationService {
    func register(application: UIApplication)
    func didRegister(deviceToken: Data)
    func didFailToRegister(error: Error)
}

@MainActor
class LocalPushNotificationService: PushNotificationService {
    static let shared = LocalPushNotificationService()

    func register(application: UIApplication) {
        print("PUSH: registering for remote notifications")
        application.registerForRemoteNotifications()
    }

    func didRegister(deviceToken: Data) {
        let hexToken = deviceToken.map { String(format: "%02hhx", $0) }.joined()
        print("PUSH: didRegisterForRemoteNotifications, hextoken: \(hexToken)")
    }

    func didFailToRegister(error: Error) {
        print("PUSH: failed to register \(error)")
    }
}
