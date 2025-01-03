//
//  ContentView.swift
//  PickerTest
//
//  Created by Sam King on 1/13/24.
//

import SwiftUI

struct SettingsView: View {
    var settingsFromUrl: CodableSettings?
    @StateObject var settingsViewModel = getSettingsStorage().viewModel()
    @Environment(\.dismiss) var dismiss
    @State var hasModifications = false
    @State var errorString: String?
    @State var readOnlyAuthToken: String?
    @State var showCopyCheck = false
    @State var navigateToSaveData = false
    
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
                    }.onChange(of: settingsViewModel.closedLoopEnabled) { _ in
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.adjustTargetGlucoseDuringExercise) {
                        Text("Adjust target glucose during exercise")
                    }.onChange(of: settingsViewModel.adjustTargetGlucoseDuringExercise) { _ in
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.useMachineLearningClosedLoop) {
                        Text("Use ML closed loop")
                    }.onChange(of: settingsViewModel.useMachineLearningClosedLoop) { _ in
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.useMicroBolus) {
                        Text("Use µBolus")
                    }.onChange(of: settingsViewModel.useMicroBolus) { _ in
                        hasModifications = true
                    }
                    Toggle(isOn: $settingsViewModel.useBiologicalInvariant) {
                        Text("Use biological invariant")
                    }.onChange(of: settingsViewModel.useBiologicalInvariant) { _ in
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
                    
                    Button {
                        navigateToSaveData = true
                    } label: {
                        Text("Save data to cloud for ML")
                    }
                    
                    /*
                    Button {
                        if let token = readOnlyAuthToken {
                            let pasteboard = UIPasteboard.general
                            pasteboard.string = token
                            showCopyCheck = true
                        }
                    } label: {
                        HStack {
                            Text("Copy auth token")
                            Spacer()
                            if showCopyCheck {
                                Image(systemName: "checkmark.circle.fill")
                            } else {
                                Image(systemName: "doc.on.doc")
                            }
                        }
                    }
                    .disabled(readOnlyAuthToken == nil)
                     */
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
        .navigationDestination(isPresented: $navigateToSaveData) {
            SaveDataView()
        }
        .onAppear {
            guard let settingsFromUrl = settingsFromUrl else {
                return
            }
            
            settingsViewModel.update(using: settingsFromUrl)
            hasModifications = true
        }
        .task {
            readOnlyAuthToken = await getEventLogger().getReadOnlyAuthToken()
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView(settingsFromUrl: nil)
    }
}
