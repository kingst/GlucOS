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
                    Toggle("Write CGM to HealthKit", isOn: $preferences.writeGlucose)
                    Toggle("Write insulin to HealthKit", isOn: $preferences.writeInsulin)
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
        .onChange(of: preferences) { _, newValue in
            guard let storage = composition?.healthKitStorage else { return }
            Task { await storage.updatePreferences(newValue) }
        }
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
}
