//
//  SettingsAutomationView.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//

import SwiftUI

/// The switch for the meal-soon target override (dev/backlog/meal-soon.md §7.1).
///
/// No Save button and no FaceID. The change is bounded — 15 mg/dl, floored at
/// 75, for at most an hour, under a shutoff that does not move (§8) — and it
/// touches no `CodableSettings` field, so it is not part of `SettingsViewModel`.
struct SettingsAutomationView: View {
    @EnvironmentObject var appState: AppObservableState
    @Environment(\.composition) var composition: AppComposition?
    /// Mirrors the published override so the switch does not snap back in the
    /// instant between the tap and the service publishing the new row.
    @State private var mealSoonOn = false
    @State private var error: String? = nil

    private var activeOverride: TargetOverride? {
        guard let override = appState.mealSoon, override.isActive(at: Date()) else { return nil }
        return override
    }

    private var isActive: Bool {
        return activeOverride != nil
    }

    private var mealSoonTargetText: String {
        let settingsTarget = composition?.settingsStorage.snapshot().targetGlucoseInMgDl ?? 0
        return String(format: "%0.0f", MealSoonPolicy.target(settingsTargetMgDl: settingsTarget))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Meal soon", isOn: $mealSoonOn)
                if let override = activeOverride {
                    HStack {
                        Text("Ends at")
                        Spacer()
                        Text(override.expiresAt.formatted(date: .omitted, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            } header: {
                Text("Meal soon")
            } footer: {
                // "Within 5 minutes" because it is true: the loop is throttled
                // to one run per 4.2 minutes and starting the override does not
                // force one. The next CGM reading picks it up.
                Text("Lowers your target glucose to \(mealSoonTargetText) mg/dl for 60 minutes, or until your next bolus, whichever comes first. Takes effect on the next loop, within 5 minutes.")
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Settings automation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Hydrate from the store. `appState.mealSoon` is nil until someone
            // asks (§4.3), and this screen may be the first to ask.
            _ = await composition?.targetGlucoseService.activeMealSoon(at: Date())
            mealSoonOn = isActive
        }
        .onChange(of: isActive) { _, nowActive in
            mealSoonOn = nowActive
        }
        .onChange(of: mealSoonOn) { _, isOn in
            // Only a tap gets here with the two disagreeing; the mirror above
            // keeps them equal otherwise.
            guard isOn != isActive else { return }
            Task { await update(isOn: isOn) }
        }
    }

    private func update(isOn: Bool) async {
        guard let composition else { return }
        error = nil
        if isOn {
            do {
                try await composition.targetGlucoseService.startMealSoon(
                    at: Date(),
                    settings: composition.settingsStorage.snapshot()
                )
            } catch {
                self.error = "Could not start meal soon: \(error.localizedDescription)"
                mealSoonOn = false
            }
        } else {
            await composition.targetGlucoseService.cancelMealSoon(at: Date())
        }
    }
}

#Preview {
    NavigationStack {
        SettingsAutomationView()
    }
    .environmentObject(AppObservableState())
}
