//
//  HealthKitSettingsView.swift
//  BioKernel
//

import SwiftUI
import HealthKit

struct HealthKitSettingsView: View {
    @Environment(\.composition) var composition: AppComposition?
    @State var preferences: HealthKitPreferences = HealthKitPreferences()
    @State var authorizationStatus: HKAuthorizationStatus = .notDetermined
    @State var errorString: String?

    var body: some View {
        Form {
            if let errorString = errorString {
                Section {
                    Text(errorString)
                        .foregroundStyle(.red)
                }
            }

            if authorizationStatus == .sharingAuthorized {
                Section {
                    Toggle("Write CGM to HealthKit", isOn: writeGlucoseBinding)
                    Toggle("Write insulin to HealthKit", isOn: writeInsulinBinding)
                } footer: {
                    Text("When enabled, GlucOS writes new glucose readings and insulin doses to Apple Health.")
                }
            } else {
                Section {
                    Button("Authorize HealthKit") {
                        Task { await authorize() }
                    }
                } footer: {
                    Text("Authorize access so GlucOS can store CGM and insulin values in Apple Health.")
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("HealthKit")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshAuthorizationStatus()
            await loadPreferences()
        }
    }

    private var writeGlucoseBinding: Binding<Bool> {
        Binding(
            get: { preferences.writeGlucose },
            set: { newValue in
                preferences.writeGlucose = newValue
                persistPreferences()
            }
        )
    }

    private var writeInsulinBinding: Binding<Bool> {
        Binding(
            get: { preferences.writeInsulin },
            set: { newValue in
                preferences.writeInsulin = newValue
                persistPreferences()
            }
        )
    }

    func authorize() async {
        guard let storage = composition?.healthKitStorage else { return }
        do {
            try await storage.authorize()
            await refreshAuthorizationStatus()
        } catch {
            errorString = error.localizedDescription
        }
    }

    func refreshAuthorizationStatus() async {
        guard let storage = composition?.healthKitStorage else { return }
        authorizationStatus = await storage.authorizationStatus()
    }

    func loadPreferences() async {
        guard let storage = composition?.healthKitStorage else { return }
        preferences = await storage.preferences()
    }

    private func persistPreferences() {
        guard let storage = composition?.healthKitStorage else { return }
        let snapshot = preferences
        Task { await storage.updatePreferences(snapshot) }
    }
}
