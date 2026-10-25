//
//  SettingsHomeView.swift
//  BioKernel
//

import SwiftUI

struct SettingsHomeView: View {
    @Environment(\.composition) var composition: AppComposition?
    /// Injected at the app root (`BioKernelApp`), so it reaches here through
    /// the same navigation stack the main view pushes from.
    @EnvironmentObject var glucoseAlertsViewModel: GlucoseAlertsViewModel
    @EnvironmentObject var appState: AppObservableState

    /// "Meal soon", "Exercise" or "Off": which timed override is in effect.
    private var automationStatus: String {
        guard let override = appState.targetOverride, override.isActive(at: Date()) else { return "Off" }
        return override.kind.title
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    if let composition {
                        SettingsView(
                            settingsViewModel: SettingsViewModel(
                                settings: composition.settingsStorage.snapshot(),
                                settingsStorage: composition.settingsStorage,
                                deviceDataManager: composition.deviceDataManager,
                                insulinStorage: composition.insulinStorage
                            )
                        )
                        .modifier(NavigationModifier())
                    }
                } label: {
                    Label("Therapy settings", systemImage: "slider.horizontal.3")
                }

                NavigationLink {
                    GlucoseAlertsView()
                } label: {
                    // The on/off state rides along as the row's trailing
                    // value. It used to be readable at a glance from the
                    // toolbar bell's fill-vs-slash; a plain row would have
                    // quietly dropped that, and "are my alerts on" is worth
                    // answering without opening the screen.
                    HStack {
                        Label("Glucose alerts", systemImage: glucoseAlertsViewModel.enabled ? "bell.fill" : "bell.slash.fill")
                        Spacer()
                        Text(glucoseAlertsViewModel.enabled ? "On" : "Off")
                            .foregroundStyle(.secondary)
                    }
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

            // Timed overrides the app applies on its own. Its own section, so it
            // is visibly separate from therapy settings: nothing in here is
            // FaceID-gated and nothing in here touches `CodableSettings`
            // (dev/backlog/meal-soon.md §7.1).
            Section {
                NavigationLink {
                    SettingsAutomationView()
                } label: {
                    // Same pattern as the alerts row: the state is readable
                    // without opening the screen.
                    HStack {
                        Label("Settings automation", systemImage: "wand.and.stars")
                        Spacer()
                        Text(automationStatus)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    // Needs the environment objects `BioKernelApp` installs at the root —
    // `GlucoseAlertsView`, which the alerts row opens, has the same
    // requirement and the same bare preview.
    NavigationStack {
        SettingsHomeView()
    }
}
