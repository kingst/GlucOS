//
//  MainViewTargetOverrideView.swift
//  BioKernel
//
//  Created by Sam King on 10/20/26.
//

import SwiftUI

/// The banner under the summary while a settings automation is in effect
/// (dev/backlog/meal-soon.md §7.2, dev/backlog/exercise.md §4,
/// dev/backlog/more-settings-automation.md). One line: which one is on and
/// when it ends.
///
/// Visually distinct from the yellow glucose alert, which means something is
/// wrong; this means something is on. Tapping it opens the Settings automation
/// screen, where the switches are — there is no cancel on the banner itself, so
/// there is one place to turn it off, and that place has the details: the
/// target glucose, the dosing multiplier and the time remaining.
struct MainViewTargetOverrideView: View {
    @EnvironmentObject var appState: AppObservableState
    @Environment(\.composition) var composition: AppComposition?

    var body: some View {
        // Always in the tree, even when empty, so the hydration below runs
        // whether or not a banner is showing. `isActive(at:)` is the view's own
        // test, so expiry clears the banner on the summary view's 30-second
        // re-render without waiting for a loop tick.
        VStack(spacing: 0) {
            if let override = appState.targetOverride, override.isActive(at: Date()) {
                NavigationLink {
                    SettingsAutomationView()
                } label: {
                    Text("\(OverrideAppearance.bannerTitle(forPolicy: override.policyIdentifier)), ends at \(OverrideGuardrails.expiry(of: override).formatted(date: .omitted, time: .shortened))")
                        // Kept to the one line at large text sizes too.
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(OverrideAppearance.color(forPolicy: override.policyIdentifier))
                        .foregroundColor(.white)
                        .bold()
                }
            }
        }
        .task {
            // `appState.targetOverride` is nil until someone asks.
            _ = await composition?.targetGlucoseService.activeOverride(at: Date())
        }
    }
}

/// How each of the five settings is named and coloured, everywhere it shows:
/// the banner, the Settings automation screen, the settings home row and the
/// glucose chart's legend. Adding a setting adds an arm to each of these.
extension TargetOverrideKind {
    var title: String {
        switch self {
        case .mealSoon: return "Meal soon"
        case .digestion: return "Digestion"
        case .exerciseSoon: return "Exercise soon"
        case .exercise: return "Exercise"
        case .postExercise: return "Post exercise"
        }
    }

    /// What the banner calls the setting while it is on. The target and the
    /// dosing multiplier are not in it: they are on the Settings automation
    /// screen.
    var bannerTitle: String {
        switch self {
        case .mealSoon: return "Meal happening soon"
        case .digestion: return "Digesting"
        case .exerciseSoon: return "Exercising soon"
        case .exercise: return "Exercising"
        case .postExercise: return "Post exercise"
        }
    }

    var color: Color {
        switch self {
        case .mealSoon: return AppColors.deepIndigo
        case .digestion: return AppColors.bronze
        case .exerciseSoon: return AppColors.teal
        case .exercise: return AppColors.berry
        case .postExercise: return AppColors.slate
        }
    }
}

/// The name and colour for a policy identifier, which is what an override row
/// and a recorded tick carry. One of the five settings looks the way its kind
/// says. An identifier this build does not know, from another source or a
/// newer build, is "Override" in a neutral colour: it still doses, so it
/// still shows.
enum OverrideAppearance {
    static let unknownTitle = "Override"

    static func title(forPolicy policyIdentifier: String?) -> String {
        return kind(policyIdentifier)?.title ?? unknownTitle
    }

    static func bannerTitle(forPolicy policyIdentifier: String?) -> String {
        return kind(policyIdentifier)?.bannerTitle ?? unknownTitle
    }

    static func color(forPolicy policyIdentifier: String?) -> Color {
        return kind(policyIdentifier)?.color ?? AppColors.graphite
    }

    private static func kind(_ policyIdentifier: String?) -> TargetOverrideKind? {
        return policyIdentifier.flatMap { TargetOverrideKind(rawValue: $0) }
    }
}

extension DosingOverride {
    /// The multiplier as the UI writes it: "1.3", "0.6", "0.8".
    var multiplierText: String {
        return String(format: "%g", dosingMultiplier)
    }
}

#Preview {
    MainViewTargetOverrideView()
        .environmentObject(AppObservableState())
}
