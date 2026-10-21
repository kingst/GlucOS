//
//  MainViewMealSoonView.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//

import SwiftUI

/// The banner under the summary while a meal-soon override is in effect
/// (dev/backlog/meal-soon.md §7.2).
///
/// Visually distinct from the yellow glucose alert, which means something is
/// wrong; this means something is on. Tapping it opens the Settings automation
/// screen, where the switch is — there is no cancel on the banner itself, so
/// there is one place to turn it off, and that place also says what it does.
struct MainViewMealSoonView: View {
    @EnvironmentObject var appState: AppObservableState
    @EnvironmentObject var doseProgress: DoseProgress
    @Environment(\.composition) var composition: AppComposition?

    var body: some View {
        // Always in the tree, even when empty, so the re-evaluation below runs
        // whether or not a banner is showing. `isActive(at:)` is the view's own
        // test, so expiry clears the banner on the summary view's 30-second
        // re-render without waiting for a loop tick.
        VStack(spacing: 0) {
            if let override = appState.mealSoon, override.isActive(at: Date()) {
                NavigationLink {
                    SettingsAutomationView()
                } label: {
                    VStack {
                        Text("Meal happening soon, lower target to \(mealSoonTargetText)")
                        Text("until \(override.expiresAt.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(AppColors.deepIndigo)
                    .foregroundColor(.white)
                    .bold()
                }
            }
        }
        .task {
            await refresh()
        }
        // A bolus from either entry point drops the banner as soon as the pump
        // reports the dose, rather than up to five minutes later at the next
        // tick. The loop reads the same rule from the same rows, so the banner
        // and the dose cannot disagree.
        .onChange(of: doseProgress.isComplete) { _, _ in
            Task { await refresh() }
        }
    }

    private var mealSoonTargetText: String {
        let settingsTarget = composition?.settingsStorage.snapshot().targetGlucoseInMgDl ?? 0
        return String(format: "%0.0f", MealSoonPolicy.target(settingsTargetMgDl: settingsTarget))
    }

    private func refresh() async {
        _ = await composition?.targetGlucoseService.activeMealSoon(at: Date())
    }
}

#Preview {
    MainViewMealSoonView()
        .environmentObject(AppObservableState())
        .environmentObject(DoseProgress())
}
