//
//  SettingsManager.swift
//  BioKernel
//
//  Created by Sam King on 11/8/23.
//

import Foundation

@MainActor
public protocol SettingsStorage {
    func viewModel() -> SettingsViewModel
    func snapshot() -> CodableSettings
    func writeToDisk(settings: CodableSettings) throws
}

@MainActor
class LocalSettingsStorage: SettingsStorage {
    static let shared = LocalSettingsStorage()
    private let storage = getStoredObject().create(fileName: "settings.json")
    
    func viewModel() -> SettingsViewModel {
        return SettingsViewModel(settings: snapshot())
    }
    
    func snapshot() -> CodableSettings {
        let settings: [CodableSettings]? = try? storage.read()
        return settings?.first ?? CodableSettings.defaults()
    }
    
    func writeToDisk(settings: CodableSettings) throws {
        settings.validate()
        try storage.write([settings])
    }
}
