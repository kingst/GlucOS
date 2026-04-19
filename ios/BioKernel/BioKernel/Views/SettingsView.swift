//
//  ContentView.swift
//  PickerTest
//
//  Created by Sam King on 1/13/24.
//

import SwiftUI

struct SettingsView: View {
    var settingsFromUrl: CodableSettings?
    @StateObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) var dismiss
    @State var hasModifications = false
    @State var errorString: String?

    init(settingsFromUrl: CodableSettings?, settingsViewModel: @autoclosure @escaping () -> SettingsViewModel) {
        self.settingsFromUrl = settingsFromUrl
        self._settingsViewModel = StateObject(wrappedValue: settingsViewModel())
    }
    
    var body: some View {
        VStack {
            if let errorString = errorString {
                Text(errorString)
                    .foregroundStyle(.red)
            }
            Form {
                Section {
                    Toggle(isOn: $settingsViewModel.closedLoopEnabled) {
                        Text("Closed loop")
                    }.onChange(of: settingsViewModel.closedLoopEnabled) {
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.useMachineLearningClosedLoop) {
                        Text("Use ML closed loop")
                    }.onChange(of: settingsViewModel.useMachineLearningClosedLoop) {
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.useMicroBolus) {
                        Text("Use µBolus")
                    }.onChange(of: settingsViewModel.useMicroBolus) {
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.useBiologicalInvariant) {
                        Text("Use biological invariant")
                    }.onChange(of: settingsViewModel.useBiologicalInvariant) {
                        hasModifications = true
                    }
                    Button {
                        Task {
                            do {
                                try await settingsViewModel.authorizeHealthKit()
                            } catch {
                                errorString = error.localizedDescription
                            }
                        }
                    } label: {
                        Text("Authorize health kit")
                    }
                }
                
                Section("Therapy settings") {
                    DecimalPicker(title: "Insulin sensitivity", selection: $settingsViewModel.insulinSensitivity, items: settingsViewModel.insulinSensitivityValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "Pump basal rate", selection: $settingsViewModel.pumpBasalRate, items: settingsViewModel.basalRateValues, hasModifications: $hasModifications)
                }
                
                Section("Guardrails") {
                    DecimalPicker(title: "Max basal rate", selection: $settingsViewModel.maxBasalRate, items: settingsViewModel.maxBasalRateValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "Max bolus", selection: $settingsViewModel.maxBolus, items: settingsViewModel.maxBolusValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "Glucose safety limit", selection: $settingsViewModel.glucoseSafetyShutoff, items: settingsViewModel.glucoseSafetyShutoffValues, hasModifications: $hasModifications)
                }
                
                Section("Algorithm settings (advanced)") {
                    DecimalPicker(title: "Target glucose", selection: $settingsViewModel.glucoseTarget, items: settingsViewModel.glucoseTargetValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "µBolus dose factor", selection: $settingsViewModel.microBolusDoseFactor, items: settingsViewModel.microBolusDoseFactorValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "PID Integrator gain", selection: $settingsViewModel.pidIntegratorGain, items: settingsViewModel.pidIntegratorValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "PID Derivative gain", selection: $settingsViewModel.pidDerivativeGain, items: settingsViewModel.pidDerivativeValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "ML gain", selection: $settingsViewModel.machineLearningGain, items: settingsViewModel.machineLearningGainValues, hasModifications: $hasModifications)
                }
                
                Section("ML Insulin Sensitivity Schedule") {
                    DecimalSettingScheduleView(schedule: settingsViewModel.mlInsulinSensitivitySchedule, items: settingsViewModel.insulinSensitivityValues, hasModifications: $hasModifications)
                }

                Section("ML Basal Schedule") {
                    DecimalSettingScheduleView(schedule: settingsViewModel.mlBasalSchedule, items: settingsViewModel.basalRateValues, hasModifications: $hasModifications)
                }
                
                Section("ML bolus amounts") {
                    DecimalPicker(title: "More", selection: $settingsViewModel.bolusAmountForMore, items: settingsViewModel.bolusValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "Usual", selection: $settingsViewModel.bolusAmountForUsual, items: settingsViewModel.bolusValues, hasModifications: $hasModifications)
                    DecimalPicker(title: "Less", selection: $settingsViewModel.bolusAmountForLess, items: settingsViewModel.bolusValues, hasModifications: $hasModifications)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    Task {
                        do {
                            try await settingsViewModel.save()
                            dismiss()
                        } catch {
                            errorString = "Unable to save settings: \(error.localizedDescription)"
                        }
                    }
                }
                .disabled(!hasModifications)
            }

        }
        .onAppear {
            guard let settingsFromUrl = settingsFromUrl else {
                return
            }

            settingsViewModel.update(using: settingsFromUrl)
            hasModifications = true
        }
    }
}

