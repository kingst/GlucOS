//
//  SettingsHomeView.swift
//  BioKernel
//

import SwiftUI

struct SettingsHomeView: View {
    @Environment(\.composition) var composition: AppComposition?

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    if let composition {
                        SettingsView(
                            settingsFromUrl: nil,
                            settingsViewModel: SettingsViewModel(
                                settings: composition.settingsStorage.snapshot(),
                                settingsStorage: composition.settingsStorage,
                                deviceDataManager: composition.deviceDataManager
                            )
                        )
                        .modifier(NavigationModifier())
                    }
                } label: {
                    Label("Therapy settings", systemImage: "slider.horizontal.3")
                }

                NavigationLink {
                    HealthKitSettingsView()
                } label: {
                    Label("HealthKit", systemImage: "heart.fill")
                }

                NavigationLink {
                    DataExportView()
                } label: {
                    Label("Data export", systemImage: "square.and.arrow.up")
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsHomeView()
    }
}
