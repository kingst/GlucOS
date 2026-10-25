//
//  MainViewTargetOverrideView.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//

import SwiftUI

/// The banner under the summary while a target override is in effect
/// (dev/backlog/meal-soon.md §7.2, dev/backlog/exercise.md §4).
///
/// Visually distinct from the yellow glucose alert, which means something is
/// wrong; this means something is on. Tapping it opens the Settings automation
/// screen, where the switches are — there is no cancel on the banner itself, so
/// there is one place to turn it off, and that place also says what it does.
struct MainViewTargetOverrideView: View {
    @EnvironmentObject var appState: AppObservableState
    @EnvironmentObject var doseProgress: DoseProgress
    @Environment(\.composition) var composition: AppComposition?

    var body: some View {
        // Always in the tree, even when empty, so the re-evaluation below runs
        // whether or not a banner is showing. `isActive(at:)` is the view's own
        // test, so expiry clears the banner on the summary view's 30-second
        // re-render without waiting for a loop tick.
        VStack(spacing: 0) {
            if let override = appState.targetOverride, override.isActive(at: Date()) {
                NavigationLink {
                    SettingsAutomationView()
                } label: {
                    VStack {
                        Text(title(for: override.kind))
                        Text("until \(override.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(override.kind.color)
                    .foregroundColor(.white)
                    .bold()
                }
            }
        }
        .task {
            await refresh()
        }
        // A bolus from either entry point drops the meal-soon banner as soon as
        // the pump reports the dose, rather than up to five minutes later at
        // the next tick. The loop reads the same rule from the same rows, so
        // the banner and the dose cannot disagree.
        .onChange(of: doseProgress.isComplete) { _, _ in
            Task { await refresh() }
        }
    }

    private var settingsTarget: Double {
        return composition?.settingsStorage.snapshot().targetGlucoseInMgDl ?? 0
    }

    private func title(for kind: TargetOverrideKind) -> String {
        switch kind {
        case .mealSoon:
            let target = String(format: "%0.0f", MealSoonPolicy.target(settingsTargetMgDl: settingsTarget))
            return "Meal happening soon, lower target to \(target)"
        case .exercise:
            let target = String(format: "%0.0f", ExercisePolicy.target(settingsTargetMgDl: settingsTarget))
            return "Exercising, raise target to \(target)"
        }
    }

    private func refresh() async {
        _ = await composition?.targetGlucoseService.activeOverride(at: Date())
    }
}

/// How each kind of override is named and coloured, everywhere it shows: the
/// banner, the settings home row and the glucose chart's legend.
extension TargetOverrideKind {
    var title: String {
        switch self {
        case .mealSoon: return "Meal soon"
        case .exercise: return "Exercise"
        }
    }

    var color: Color {
        switch self {
        case .mealSoon: return AppColors.deepIndigo
        case .exercise: return AppColors.teal
        }
    }
}

#Preview {
    MainViewTargetOverrideView()
        .environmentObject(AppObservableState())
        .environmentObject(DoseProgress())
}
