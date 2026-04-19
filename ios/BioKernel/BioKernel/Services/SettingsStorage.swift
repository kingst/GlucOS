//
//  SettingsManager.swift
//  BioKernel
//
//  Created by Sam King on 11/8/23.
//

import Foundation

@MainActor
public protocol SettingsStorage {
    func snapshot() -> CodableSettings
    func writeToDisk(settings: CodableSettings) throws
}

@MainActor
class LocalSettingsStorage: SettingsStorage {
    private let storage: StoredObject

    init(storedObjectFactory: StoredObject.Type) {
        self.storage = storedObjectFactory.create(fileName: "settings.json")
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
