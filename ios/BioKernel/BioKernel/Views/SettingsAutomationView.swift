//
//  SettingsAutomationView.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//

import SwiftUI

/// The switches for the timed target overrides: meal soon
/// (dev/backlog/meal-soon.md §7.1) and exercise (dev/backlog/exercise.md §4).
///
/// No Save button and no FaceID. Both changes are bounded — meal soon lowers by
/// 15 mg/dl floored at 75 for an hour, exercise raises by 50 mg/dl for at most
/// four hours, both under a shutoff that does not move — and neither touches a
/// `CodableSettings` field, so this screen is not part of `SettingsViewModel`.
///
/// Only one override can be open at a time. Turning either on supersedes the
/// other, so the later setting wins; the switches mirror the published override
/// and follow suit.
struct SettingsAutomationView: View {
    @EnvironmentObject var appState: AppObservableState
    @Environment(\.composition) var composition: AppComposition?
    /// Mirror the published override so a switch does not snap back in the
    /// instant between the tap and the service publishing the new row.
    @State private var mealSoonOn = false
    @State private var exerciseOn = false
    /// Nothing is remembered between starts: this is `defaultDuration` whenever
    /// exercise is off, and the running row's duration while it is on. Changing
    /// it while on restarts exercise from now with the new duration.
    @State private var exerciseDuration = ExercisePolicy.defaultDuration
    @State private var error: String? = nil

    private var activeOverride: TargetOverride? {
        guard let override = appState.targetOverride, override.isActive(at: Date()) else { return nil }
        return override
    }

    private var activeKind: TargetOverrideKind? {
        return activeOverride?.kind
    }

    private var settingsTarget: Double {
        return composition?.settingsStorage.snapshot().targetGlucoseInMgDl ?? 0
    }

    private var mealSoonTargetText: String {
        return String(format: "%0.0f", MealSoonPolicy.target(settingsTargetMgDl: settingsTarget))
    }

    private var exerciseTargetText: String {
        return String(format: "%0.0f", ExercisePolicy.target(settingsTargetMgDl: settingsTarget))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Meal soon", isOn: $mealSoonOn)
                if let override = activeOverride, override.kind == .mealSoon {
                    endsAtRow(override)
                }
            } header: {
                Text("Meal soon")
            } footer: {
                // "Within 5 minutes" because it is true: the loop is throttled
                // to one run per 4.2 minutes and starting the override does not
                // force one. The next CGM reading picks it up.
                Text("Lowers your target glucose to \(mealSoonTargetText) mg/dl for 60 minutes, or until your next bolus, whichever comes first. Takes effect on the next loop, within 5 minutes.")
            }

            Section {
                Toggle("Exercise", isOn: $exerciseOn)
                Picker("Duration", selection: $exerciseDuration) {
                    ForEach(ExercisePolicy.durations, id: \.self) { duration in
                        Text(Self.durationText(duration)).tag(duration)
                    }
                }
                if let override = activeOverride, override.kind == .exercise {
                    endsAtRow(override)
                }
            } header: {
                Text("Exercise")
            } footer: {
                Text("Raises your target glucose to \(exerciseTargetText) mg/dl for \(Self.durationText(exerciseDuration)). Changing the duration while exercise is on restarts it from now. Takes effect on the next loop, within 5 minutes. Meal soon and exercise cannot both be on; the one turned on last wins.")
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Settings automation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Hydrate from the store. `appState.targetOverride` is nil until
            // someone asks (meal-soon §4.3), and this screen may be the first
            // to ask.
            _ = await composition?.targetGlucoseService.activeOverride(at: Date())
            mirrorPublishedOverride()
        }
        .onChange(of: activeOverride) { _, _ in
            mirrorPublishedOverride()
        }
        .onChange(of: mealSoonOn) { _, isOn in
            // Only a tap gets here with the two disagreeing; the mirror keeps
            // them equal otherwise.
            guard isOn != (activeKind == .mealSoon) else { return }
            Task { await setMealSoon(isOn) }
        }
        .onChange(of: exerciseOn) { _, isOn in
            guard isOn != (activeKind == .exercise) else { return }
            Task { await setExercise(isOn) }
        }
        .onChange(of: exerciseDuration) { _, duration in
            // Only a pick while exercise is on gets here with the two
            // disagreeing. Compared against the picker's own reading of the
            // running row, so mirroring a row whose duration is not one of the
            // choices does not restart it.
            guard let override = activeOverride, override.kind == .exercise,
                  Self.pickerChoice(for: override.duration) != duration else { return }
            Task { await startExercise(duration: duration) }
        }
    }

    private func endsAtRow(_ override: TargetOverride) -> some View {
        HStack {
            Text("Ends at")
            Spacer()
            Text(override.expiresAt.formatted(date: .omitted, time: .shortened))
                .foregroundStyle(.secondary)
        }
    }

    /// "30 minutes", "1 hour, 30 minutes", "2 hours".
    static func durationText(_ duration: TimeInterval) -> String {
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// The picker choice nearest a row's duration. A row written by this screen
    /// is always exactly one of the choices; this is for any other writer, so
    /// the picker is never left showing nothing.
    static func pickerChoice(for duration: TimeInterval) -> TimeInterval {
        return ExercisePolicy.durations.min { abs($0 - duration) < abs($1 - duration) } ?? ExercisePolicy.defaultDuration
    }

    private func mirrorPublishedOverride() {
        mealSoonOn = activeKind == .mealSoon
        exerciseOn = activeKind == .exercise
        if let override = activeOverride, override.kind == .exercise {
            exerciseDuration = Self.pickerChoice(for: override.duration)
        } else {
            exerciseDuration = ExercisePolicy.defaultDuration
        }
    }

    private func setMealSoon(_ isOn: Bool) async {
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
            await composition.targetGlucoseService.cancelOverride(at: Date())
        }
    }

    private func setExercise(_ isOn: Bool) async {
        if isOn {
            await startExercise(duration: exerciseDuration)
        } else {
            guard let composition else { return }
            error = nil
            await composition.targetGlucoseService.cancelOverride(at: Date())
        }
    }

    private func startExercise(duration: TimeInterval) async {
        guard let composition else { return }
        error = nil
        do {
            try await composition.targetGlucoseService.startExercise(
                at: Date(),
                duration: duration,
                settings: composition.settingsStorage.snapshot()
            )
        } catch {
            self.error = "Could not start exercise: \(error.localizedDescription)"
            mirrorPublishedOverride()
        }
    }
}

#Preview {
    NavigationStack {
        SettingsAutomationView()
    }
    .environmentObject(AppObservableState())
}
