//
//  Bindings.swift
//  Type Zero
//
//  Created by Sam King on 1/24/23.
//  Copyright © 2023 Sam King. All rights reserved.
//

import Foundation
import LoopKit
import G7SensorKit

let getBluetoothProvider: () -> BluetoothProvider = Dependency.bind { BluetoothStateManager.shared }
let getDeviceDataManager: () -> DeviceDataManager = Dependency.bind { LocalDeviceDataManager.shared }
let getInsulinStorage: () -> InsulinStorage = Dependency.bind { LocalInsulinStorage.shared }
let getSettingsStorage: () -> SettingsStorage = Dependency.bind { LocalSettingsStorage.shared }
let getGlucoseStorage: () -> GlucoseStorage = Dependency.bind { LocalGlucoseStorage.shared }
let getClosedLoopService: () -> ClosedLoopService = Dependency.bind { LocalClosedLoopService.shared }
let getStoredObject: () -> StoredObject.Type = Dependency.bind { StoredJsonObject.self }
let getJsonHttp: () -> Http = Dependency.bind { JsonHttp.shared }
let getEventLogger: () -> EventLogger = Dependency.bind { LocalEventLogger.shared }
let getAlertStorage: () -> AlertStorage = Dependency.bind { LocalAlertStorage.shared }
let getHealthKitStorage: () -> HealthKitStorage = Dependency.bind { LocalHealthKitStorage.shared }
let getMachineLearning: () -> MachineLearning = Dependency.bind { LocalMachineLearning.shared }
let getPhysiologicalModels: () -> PhysiologicalModels = Dependency.bind { LocalPhysiologicalModels.shared }
let getSafetyService: () -> SafetyService = Dependency.bind { LocalSafetyService.shared }
let getDebugLogger: () -> G7DebugLogger = Dependency.bind { LocalEventLogger.shared }
let getBackgroundService: () -> BackgroundService = Dependency.bind { LocalBackgroundService.shared }
let getGlucoseAlertsService: () -> GlucoseAlertStorage = Dependency.bind { PredictiveGlucoseAlertStorage.shared }
