//
//  SettingsAutomationView.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//

import SwiftUI

/// The switches for the settings automations: meal soon
/// (dev/backlog/meal-soon.md §7.1), exercise soon (dev/backlog/exercise.md §4),
/// and digestion, exercise and post exercise
/// (dev/backlog/more-settings-automation.md).
///
/// A status section at the top says what is in effect now: which setting is
/// running, the dosing multiplier, the target glucose and the time remaining.
/// Under it each setting has a switch and a Duration picker, and nothing else.
///
/// This screen is the policy side of dev/backlog/override-mechanism.md: it
/// decides which setting to start and for how long, and the override manager
/// does the rest.
///
/// No Save button and no FaceID. Every change is bounded by
/// `OverrideGuardrails`: the target stays inside its range, the dosing
/// multiplier inside its range, and one start runs for at most
/// `OverrideGuardrails.maxDuration`, all under a shutoff, a max basal rate and
/// a safety bound that do not move. None of them touches a `CodableSettings`
/// field, so this screen is not part of `SettingsViewModel`.
///
/// Only one can be on at a time. Turning any of them on supersedes whichever
/// was on, so the later setting wins; the switches mirror the published
/// override and follow suit.
struct SettingsAutomationView: View {
    @EnvironmentObject var appState: AppObservableState
    @Environment(\.composition) var composition: AppComposition?
    /// The setting whose switch is on. Follows a tap at once, so a switch
    /// does not snap back in the instant between the tap and the service
    /// publishing the new row, and mirrors the published override otherwise.
    /// One value and not a flag per setting, because only one can be on.
    @State private var onKind: TargetOverrideKind? = nil
    /// What each Duration picker shows, for the kinds that are not showing
    /// their default. Nothing is remembered between starts: a setting's entry
    /// is dropped when its switch goes off, so its picker is back on the
    /// default. A pick made while a setting is off waits here for its switch.
    @State private var pickedDurations: [TargetOverrideKind: TimeInterval] = [:]
    @State private var error: String? = nil
    /// The settings target, for the Status section. Read once when the screen
    /// appears: reading it is a read and a decode of `settings.json` on the
    /// main thread, and nothing on this screen changes it.
    @State private var settingsTargetMgDl: Double? = nil
    /// The newest request to the service. Each one waits for the one before
    /// it, so they reach the service one at a time in the order they were
    /// made, and a Duration change just after a flip starts after the flip.
    @State private var lastRequest: Task<Void, Never>? = nil
    /// How many requests have not come back yet. While there are any, the
    /// switches and pickers show what was tapped and are not mirrored.
    @State private var pendingRequests = 0

    /// How often the time remaining is worked out again. It is shown in whole
    /// minutes, so this is how late a minute can tick over.
    private static let refreshInterval: TimeInterval = 10

    private func activeOverride(at now: Date) -> TargetOverride? {
        guard let override = appState.targetOverride, override.isActive(at: now) else { return nil }
        return override
    }

    var body: some View {
        Form {
            statusSection

            ForEach(TargetOverrideKind.allCases, id: \.self) { kind in
                Section {
                    Toggle(isOn: isOn(kind)) {
                        Text(kind.title).bold()
                    }
                    Picker("Duration", selection: pickedDuration(kind)) {
                        ForEach(kind.durations, id: \.self) { duration in
                            Text(Self.durationText(duration)).tag(duration)
                        }
                    }
                }
            }

            if let error {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        // Six short sections: close them up so the status and most of the
        // switches are on screen together.
        .listSectionSpacing(.compact)
        .modifier(NavigationModifier())
        .navigationTitle("Settings automation")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settingsTargetMgDl = composition?.settingsStorage.snapshot().targetGlucoseInMgDl
            // Whatever is already published, before the first frame, so the
            // running setting's switch does not open as off. A tap on it in
            // that state would restart the setting with its default duration.
            mirrorPublishedOverride()
        }
        .onChange(of: appState.targetOverride) { _, _ in
            mirrorPublishedOverride()
        }
        .task {
            // Hydrate from the store. `appState.targetOverride` is nil until
            // someone asks (meal-soon §4.3), and this screen may be the first
            // to ask.
            _ = await composition?.targetGlucoseService.activeOverride(at: Date())
            mirrorPublishedOverride()
        }
        .task(id: appState.targetOverride) {
            await dropAtExpiry(of: appState.targetOverride)
        }
    }

    // MARK: - Status

    /// What is in effect now. The four rows are always there, so the switches
    /// below do not move when a setting starts or ends.
    ///
    /// The target and the multiplier come from `OverrideGuardrails.resolve`
    /// on the published row, which is the rule the loop's next tick applies,
    /// so the status shows the numbers the loop doses with.
    private var statusSection: some View {
        let now = Date()
        let active = activeOverride(at: now)
        let resolved = settingsTargetMgDl.map {
            OverrideGuardrails.resolve(override: active, at: now, settingsTargetMgDl: $0)
        }
        return Section("Status") {
            LabeledContent("Running", value: active.map { OverrideAppearance.title(forPolicy: $0.policyIdentifier) } ?? "None")
            LabeledContent("Dosing multiplier", value: Self.dosingMultiplierText(for: resolved?.dosingOverride))
            LabeledContent("Target glucose", value: resolved.map { String(format: "%0.0f mg/dL", $0.mgDl) } ?? "-")
            // The one label that changes with nothing else changing, so it is
            // the only thing on a clock. The rest of the form is rebuilt when
            // something is tapped, published or runs out.
            TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
                // Not the timeline's own date: that is the last tick, and a
                // setting started since then would show more time remaining
                // than its duration.
                let now = Date()
                LabeledContent(
                    "Time remaining",
                    value: activeOverride(at: now).map { Self.timeRemainingText(until: OverrideGuardrails.expiry(of: $0), at: now) } ?? "-"
                )
            }
        }
    }

    /// "1.3x" while an override that scales dosing is on, and "1x" otherwise:
    /// with nothing on, or with one that only moves the target.
    static func dosingMultiplierText(for dosingOverride: DosingOverride?) -> String {
        guard let dosingOverride else { return "1x" }
        return "\(dosingOverride.multiplierText)x"
    }

    /// The time left until `expiresAt` in whole minutes, rounded up: "1 hour"
    /// for a setting just started for an hour, and "1 minute" through its last
    /// minute, so it never reads zero while the setting is still on.
    static func timeRemainingText(until expiresAt: Date, at now: Date) -> String {
        let minutes = (expiresAt.timeIntervalSince(now) / 60).rounded(.up)
        return durationText(max(minutes, 1) * 60)
    }

    /// Runs while `override` is the published one. When its time is up this
    /// asks the service for the active override, which closes the row and
    /// publishes that nothing is on, and the switch drops.
    private func dropAtExpiry(of override: TargetOverride?) async {
        guard let override else { return }
        // Until the wall clock says it is over. A sleep that returns a
        // moment early, or a clock that moved, goes round again.
        while !Task.isCancelled, override.isActive(at: Date()) {
            let remaining = OverrideGuardrails.expiry(of: override).timeIntervalSinceNow
            try? await Task.sleep(for: .seconds(max(remaining, 0.1)))
        }
        guard !Task.isCancelled else { return }
        _ = await composition?.targetGlucoseService.activeOverride(at: Date())
        mirrorPublishedOverride()
    }

    // MARK: - The switches and pickers

    /// A switch is on when `onKind` says its kind is. Only a tap reaches
    /// `set`: mirroring goes through `show`.
    private func isOn(_ kind: TargetOverrideKind) -> Binding<Bool> {
        return Binding(
            get: { onKind == kind },
            set: { isOn in
                show(isOn ? kind : nil)
                send(isOn ? .start(kind, duration: duration(for: kind)) : .cancel(kind))
            }
        )
    }

    private func duration(for kind: TargetOverrideKind) -> TimeInterval {
        return pickedDurations[kind] ?? kind.defaultDuration
    }

    /// Only a pick reaches `set`, so mirroring a running row whose duration is
    /// not one of the choices does not restart it.
    private func pickedDuration(_ kind: TargetOverrideKind) -> Binding<TimeInterval> {
        return Binding(
            get: { duration(for: kind) },
            set: { duration in
                pickedDurations[kind] = duration
                // Changing the duration while the setting is on restarts it
                // from now. While it is off the pick waits for the switch.
                // "On" is what the switch shows, not what is published yet:
                // a pick just after a flip is for the setting just flipped
                // on, and it is sent behind that flip.
                guard onKind == kind else { return }
                send(.start(kind, duration: duration))
            }
        )
    }

    /// "30 minutes", "1 hour, 30 minutes", "2 hours".
    static func durationText(_ duration: TimeInterval) -> String {
        return Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// The picker choice nearest a row's duration. A row written by this screen
    /// is always exactly one of its kind's choices. This is for any other
    /// writer, whose duration may be one the picker does not offer, so the
    /// picker is never left showing nothing.
    static func pickerChoice(for duration: TimeInterval, kind: TargetOverrideKind) -> TimeInterval {
        return kind.durations.min { abs($0 - duration) < abs($1 - duration) } ?? kind.defaultDuration
    }

    /// Turns `kind`'s switch on and every other switch off, or all of them
    /// off for nil. The setting whose switch goes off gets its picker back on
    /// the default. No other picker is touched, so a pick waiting for a
    /// setting that is off is still there when its switch is flipped.
    private func show(_ kind: TargetOverrideKind?) {
        if let stopped = onKind, stopped != kind {
            pickedDurations[stopped] = nil
        }
        onKind = kind
    }

    // MARK: - Mirroring and the service

    /// Makes the switches and the running setting's picker show the published
    /// override. An override from a source that is not one of the five leaves
    /// every switch off, and the Status section still says what it does.
    private func mirrorPublishedOverride() {
        // A request that has not come back yet will publish something newer
        // than what is published now. Mirroring in between would flip a
        // switch back, or put a picker back, under the user's finger.
        guard pendingRequests == 0 else { return }
        let active = activeOverride(at: Date())
        let kind = active?.kind
        show(kind)
        if let active, let kind {
            pickedDurations[kind] = Self.pickerChoice(for: active.duration, kind: kind)
        }
    }

    private enum Request {
        case start(TargetOverrideKind, duration: TimeInterval)
        case cancel(TargetOverrideKind)
    }

    /// Queues `request` behind every request made before it.
    private func send(_ request: Request) {
        let previous = lastRequest
        pendingRequests += 1
        lastRequest = Task {
            await previous?.value
            await perform(request)
            pendingRequests -= 1
            // Whatever the store says now is what the service published, so
            // a failed start or a failed cancel puts the switches back.
            mirrorPublishedOverride()
        }
    }

    private func perform(_ request: Request) async {
        guard let composition else { return }
        error = nil
        switch request {
        case .start(let kind, let duration):
            do {
                try await composition.targetGlucoseService.start(
                    kind,
                    at: Date(),
                    duration: duration,
                    settings: composition.settingsStorage.snapshot()
                )
            } catch {
                self.error = "Could not start \(kind.title.lowercased()): \(error.localizedDescription)"
            }
        case .cancel(let kind):
            do {
                try await composition.targetGlucoseService.cancelOverride(at: Date())
            } catch {
                self.error = "Could not stop \(kind.title.lowercased()): \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsAutomationView()
    }
    .environmentObject(AppObservableState())
}
