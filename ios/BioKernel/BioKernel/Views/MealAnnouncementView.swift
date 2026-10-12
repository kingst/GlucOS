//
//  MealAnnouncementView.swift
//  BioKernel
//
//  What GlucOS would like to bolus for a meal an AI app just announced, and the
//  place the user delivers it. Reached by universal link from the AI app that
//  logged the meal (see `MealAnnouncementLink`), or from the Dose button on a
//  recent meal's detail screen.
//
//  The layout is ClueClue's verification screen — figure 4 of the ClueClue
//  paper — ported: a recommendation card (slot eyebrow, the dose as one large
//  number, the three tiers, one line of reasoning, and the decision context as
//  a stat row), a collapsed Adjust card, the reference window under it, and the
//  primary action pinned to the bottom.
//
//  Two things are deliberately not ported. ClueClue's mascot heads its version
//  of this card; it stays out of GlucOS, both because GlucOS is not ClueClue
//  and because ClueClue's own guidance keeps her off live dosing surfaces. And
//  ClueClue's Adjust card offers dose, insulin type and time — here only dose
//  is adjustable, because the pump chooses the insulin and delivery is now.
//
//  The other conceptual difference from ClueClue, which is the whole reason
//  this screen exists on this side: ClueClue logs a dose the user is about to
//  inject, and this delivers one. So it ends in `BolusView`'s gauntlet — pump
//  rounding, the `maxBolusUnits` bound, and Face ID, in that order.
//

import SwiftUI

struct MealAnnouncementView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var viewModel: MealAnnouncementViewModel
    @StateObject private var windowViewModel: MealWindowViewModel
    /// The reference meal's window, loaded only when there is one — a
    /// first-time meal has no evidence to show.
    private let referenceMeal: StoredMeal?

    init(meal: StoredMeal, referenceMeal: StoredMeal?, composition: AppComposition) {
        self.referenceMeal = referenceMeal
        _viewModel = StateObject(wrappedValue: MealAnnouncementViewModel(
            meal: meal,
            mealStorage: composition.mealStorage,
            settingsStorage: composition.settingsStorage,
            insulinStorage: composition.insulinStorage,
            glucoseStorage: composition.glucoseStorage,
            deviceDataManager: composition.deviceDataManager,
            doseProgress: composition.doseProgress
        ))
        _windowViewModel = StateObject(wrappedValue: MealWindowViewModel(
            meal: referenceMeal ?? meal,
            glucoseStorage: composition.glucoseStorage,
            insulinStorage: composition.insulinStorage,
            mealStorage: composition.mealStorage
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: MealStyle.stackSpacing) {
                    header
                    if viewModel.recommendation != nil {
                        recommendationCard
                        adjustSection
                        reference
                    } else if !viewModel.hasLoaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal, MealStyle.stackSpacing)
                .padding(.top, MealStyle.stackSpacing)
                .padding(.bottom, 24)
            }

            if viewModel.recommendation != nil {
                footer
                    .padding(.horizontal, MealStyle.stackSpacing)
                    .padding(.bottom, MealStyle.stackSpacing)
            }
        }
        .background(MealStyle.canvas.ignoresSafeArea())
        .modifier(NavigationModifier())
        .navigationTitle("Add insulin")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
            if referenceMeal != nil {
                await windowViewModel.load()
            }
        }
    }

    // MARK: - Header

    /// What the AI said the meal is, at full weight and on its own.
    ///
    /// It used to sit in caption grey under an "AI meal" label, which had it
    /// backwards: how the meal got here is the one thing the user already
    /// knows — they arrived from the app that announced it — while the
    /// description is what they have to check before delivering insulin. Not
    /// clamped to two lines for the same reason. ClueClue puts its mascot and
    /// "ClueClue suggests" in this position; naming the app that announced it
    /// belongs on the detail screen.
    private var header: some View {
        // Empty only for a cancellation of a meal we never saw announced,
        // which stores no description. A word beats a blank line.
        Text(viewModel.meal.mealDescription.isEmpty ? "Meal" : viewModel.meal.mealDescription)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recommendation card

    @ViewBuilder
    private var recommendationCard: some View {
        if let recommendation = viewModel.recommendation {
            VStack(alignment: .leading, spacing: 12) {
                cardEyebrow
                cardDose
                cardChips(recommendation)
                cardRationale
                Divider().overlay(MealStyle.line)
                cardStats
            }
            .padding(MealStyle.cardPadding)
            .background(
                MealStyle.surface,
                in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
            )
        }
    }

    private var cardEyebrow: some View {
        HStack {
            Text(viewModel.contextLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.deepIndigo)
                .kerning(0.5)
            Spacer()
            Text(MealStyle.time(viewModel.meal.startTime))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cardDose: some View {
        // The big number's `.bottom` guide is anchored to its baseline so the
        // "units" label sits flush with the visible bottom of the digits
        // rather than under the rounded font's empty descender slot.
        HStack(alignment: .bottom, spacing: 8) {
            Text(MealStyle.units(viewModel.units ?? 0))
                .font(.system(size: MealStyle.doseFontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .alignmentGuide(.bottom) { $0[.lastTextBaseline] }
            Text("units")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// Less / usual / more, one step apart — the insulin that moves this
    /// person's glucose by 25 mg/dL. `usual` is the algorithm's answer and the
    /// default.
    private func cardChips(_ recommendation: MealDoseRecommendation) -> some View {
        HStack(spacing: 8) {
            ForEach(MealDoseTier.allCases, id: \.self) { tier in
                chip(for: tier, recommendation: recommendation)
            }
        }
    }

    private func chip(for tier: MealDoseTier, recommendation: MealDoseRecommendation) -> some View {
        let isSelected = isSelected(tier)
        return Button {
            // Picking a tier abandons a hand-entered number, so the screen
            // never shows a selected chip while delivering something else.
            viewModel.manualUnits = ""
            viewModel.selectedTier = tier
        } label: {
            VStack(spacing: 2) {
                Text("\(MealStyle.units(recommendation.units(for: tier)))u")
                    .font(.headline)
                    .foregroundStyle(isSelected ? .white : AppColors.deepIndigo)
                Text(tier.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? AppColors.primary : MealStyle.surface)
            .overlay(
                RoundedRectangle(cornerRadius: MealStyle.chipRadius, style: .continuous)
                    .stroke(isSelected ? Color.clear : MealStyle.line, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: MealStyle.chipRadius, style: .continuous))
        }
        .buttonStyle(PressableCardStyle())
    }

    private func isSelected(_ tier: MealDoseTier) -> Bool {
        return viewModel.highlightedTier == tier
    }

    private var cardRationale: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(AppColors.primary)
            Text(viewModel.reasoning)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The decision context. Same three numbers ClueClue shows, and for the
    /// same reason: they are what would make someone override the suggestion.
    private var cardStats: some View {
        HStack(spacing: 0) {
            statTile(label: "IOB", value: iobStat.value, unit: iobStat.unit)
            Divider().frame(height: 28).overlay(MealStyle.line)
            statTile(label: "LAST BOLUS", value: lastBolusStat, unit: nil)
            Divider().frame(height: 28).overlay(MealStyle.line)
            statTile(label: "GLUCOSE", value: glucoseStat.value, unit: glucoseStat.unit)
        }
    }

    private static let statPlaceholder = "—"

    private var iobStat: (value: String, unit: String?) {
        guard let iob = viewModel.insulinOnBoard else { return (Self.statPlaceholder, nil) }
        return (String(format: "%0.1f", iob), "u")
    }

    private var lastBolusStat: String {
        guard let at = viewModel.lastBolusAt else { return Self.statPlaceholder }
        return MealStyle.time(at)
    }

    private var glucoseStat: (value: String, unit: String?) {
        guard let glucose = viewModel.currentGlucose else { return (Self.statPlaceholder, nil) }
        return ("\(Int(glucose.rounded()))", "mg/dL")
    }

    private func statTile(label: String, value: String, unit: String?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .kerning(0.5)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Adjust

    /// Collapsed by default. The doc allows a value outside the three tiers,
    /// and this is where it goes — a stepper on the same increment the tiers
    /// are spaced on, plus a field for typing one straight in.
    private var adjustSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { viewModel.adjustExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text("Adjust")
                        .font(.subheadline.weight(.semibold))
                    Text("dose")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: viewModel.adjustExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(MealStyle.cardPadding)
                .background(
                    MealStyle.surface,
                    in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
                )
            }
            .buttonStyle(PressableCardStyle())

            if viewModel.adjustExpanded {
                adjustDoseRow
                    .padding(MealStyle.cardPadding)
                    .background(
                        MealStyle.surface,
                        in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
                    )
                    .padding(.top, 8)
            }
        }
    }

    private var adjustDoseRow: some View {
        HStack {
            Text("Dose")
                .font(.subheadline)
            Spacer()
            stepperButton(systemName: "minus") {
                viewModel.adjustDose(by: -viewModel.doseStep)
            }
            TextField("", text: $viewModel.manualUnits, prompt: Text(MealStyle.units(viewModel.units ?? 0)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.headline)
                .monospacedDigit()
                .frame(minWidth: 64)
            stepperButton(systemName: "plus") {
                viewModel.adjustDose(by: viewModel.doseStep)
            }
        }
    }

    private func stepperButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.deepIndigo)
                .frame(width: 28, height: 28)
                .background(MealStyle.brandTint)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reference window

    /// The past instance the recommendation is anchored on, with the same
    /// visualization the detail screen uses — so "how it went last time" sits
    /// directly under the numbers derived from it.
    @ViewBuilder
    private var reference: some View {
        if let referenceMeal, let data = windowViewModel.data {
            VStack(alignment: .leading, spacing: 12) {
                Text("LAST TIME · \(MealStyle.day(referenceMeal.startTime).uppercased())")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.6)
                MealWindowChartView(meal: referenceMeal, data: data)
                if !data.events.isEmpty {
                    MealWindowTimelineView(events: data.events, anchor: referenceMeal.startTime)
                        .padding(.top, 4)
                }
                totalInsulinCard(referenceMeal: referenceMeal, data: data)
                    .padding(.top, 4)
            }
        }
    }

    /// Every unit the pump delivered over that window, meal bolus included.
    ///
    /// The tiers above move off one number — the bolus the user picked last
    /// time — and on a closed loop that is not the whole story: a 1.20u meal
    /// bolus the loop then had to follow with 2u of correction was a plate
    /// that came up short by far more than a tier step. The chart shows that
    /// as a shape; this says it as a number.
    ///
    /// Last thing on the screen because it is context for the choice, not the
    /// choice, and inside the reference section because "the last time you ate
    /// this" is the only window it can be read over — a first-time meal has no
    /// total to show.
    private func totalInsulinCard(referenceMeal: StoredMeal, data: MealWindowData) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                Text("Total insulin")
                    .font(.subheadline.weight(.semibold))
                    .alignmentGuide(.bottom) { $0[.lastTextBaseline] }
                Spacer(minLength: 8)
                Text(MealStyle.units(data.insulinDelivered))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .alignmentGuide(.bottom) { $0[.lastTextBaseline] }
                Text("units")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .alignmentGuide(.bottom) { $0[.lastTextBaseline] }
            }
            if let split = insulinSplit(referenceMeal: referenceMeal, data: data) {
                Text(split)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(coverage(data))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MealStyle.cardPadding)
        .background(
            MealStyle.surface,
            in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
        )
    }

    /// "1.20u meal bolus · 2.25u basal and corrections" — which half of the
    /// total was the decision and which half was the loop cleaning up after it.
    ///
    /// Dropped rather than forced when the remainder isn't a real amount: the
    /// count starts at the meal, so a dose given *before* the plate — pre-
    /// bolusing, which this feature deliberately allows — is not inside it,
    /// and a "0.00u" or a negative second half would be worse than no split.
    private func insulinSplit(referenceMeal: StoredMeal, data: MealWindowData) -> String? {
        guard let dose = referenceMeal.doseUnits else { return nil }
        let rest = data.insulinDelivered - dose
        guard rest >= MealDosingPolicy.minimumDoseIncrement else { return nil }
        return "\(MealStyle.units(dose))u meal bolus · \(MealStyle.units(rest))u basal and corrections"
    }

    /// What the total covers. It stops where the analysis stops — the next
    /// meal when there was one, the present when the window is still running —
    /// so the end time is named rather than described as "3.5 hours".
    private func coverage(_ data: MealWindowData) -> String {
        return data.truncatedByNextMeal
            ? "From the meal to the next one at \(MealStyle.time(data.analysisEnd))"
            : "From the meal through \(MealStyle.time(data.analysisEnd))"
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 8) {
            // The AI took the meal back, possibly while this screen was open.
            // Said plainly above the button rather than left to a failure
            // message after the tap.
            if viewModel.isCancelled {
                Label("Cancelled by the app that announced it", systemImage: "xmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task {
                    if await viewModel.deliver() {
                        dismiss()
                    }
                }
            } label: {
                Text(viewModel.units.map { "Deliver \(MealStyle.units($0))U" } ?? "Deliver")
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(canDeliver ? AppColors.primary : Color.gray)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .font(.headline)
            .disabled(!canDeliver)

            if let error = viewModel.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var canDeliver: Bool {
        return !viewModel.delivered && !viewModel.isCancelled
    }
}
