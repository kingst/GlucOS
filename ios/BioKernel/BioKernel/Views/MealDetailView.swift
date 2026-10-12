//
//  MealDetailView.swift
//  BioKernel
//
//  What happened as a result of one meal: 30 minutes before through 3.5 hours
//  after, glucose, insulin on board, the dose, and what the run-to-run rules
//  made of it.
//
//  The outcome line is the reason this screen exists rather than being a chart
//  with a title. It is the same classification that decides what the *next*
//  instance of this meal is offered, so reading it here is how the user can
//  tell why a dose moved — see `MealDosing.outcome`.
//

import SwiftUI

struct MealDetailView: View {
    let meal: StoredMeal
    let composition: AppComposition
    @StateObject private var viewModel: MealWindowViewModel
    @State private var navigateToDosing = false
    @State private var referenceMeal: StoredMeal?
    @State private var canDose = false

    init(meal: StoredMeal, composition: AppComposition) {
        self.meal = meal
        self.composition = composition
        _viewModel = StateObject(wrappedValue: MealWindowViewModel(
            meal: meal,
            glucoseStorage: composition.glucoseStorage,
            insulinStorage: composition.insulinStorage,
            mealStorage: composition.mealStorage
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MealStyle.stackSpacing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meal.mealDescription)
                            .font(.headline)
                        Text(meal.startTime.toMealDateString())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let data = viewModel.data {
                        MealWindowChartView(meal: meal, data: data)
                        if !data.events.isEmpty {
                            MealWindowTimelineView(events: data.events, anchor: meal.startTime)
                        }
                        MealWindowFactsView(meal: meal, data: data)
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

            if canDose {
                doseButton
                    .padding(.horizontal, MealStyle.stackSpacing)
                    .padding(.bottom, MealStyle.stackSpacing)
            }
        }
        .background(MealStyle.canvas.ignoresSafeArea())
        .modifier(NavigationModifier())
        .navigationTitle("Meal")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $navigateToDosing) {
            MealAnnouncementView(
                meal: meal,
                referenceMeal: referenceMeal,
                composition: composition
            )
        }
        .task {
            await viewModel.load()
            await resolveDosing()
        }
    }

    /// The same verification screen the universal link opens.
    private var doseButton: some View {
        Button {
            navigateToDosing = true
        } label: {
            Text("Dose this meal")
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 50)
        .background(AppColors.primary)
        .foregroundColor(.white)
        .clipShape(Capsule())
        .font(.headline)
    }

    /// Whether to offer the Dose button, and what the dosing screen would
    /// learn from. The rule itself lives on `StoredMeal.canDose(at:)` so it is
    /// testable without a view.
    private func resolveDosing() async {
        guard meal.canDose(at: Date()) else {
            canDose = false
            return
        }
        referenceMeal = await composition.mealStorage.referenceMeal(for: meal)
        canDose = true
    }
}

/// The numbers under the chart.
struct MealWindowFactsView: View {
    let meal: StoredMeal
    let data: MealWindowData

    var body: some View {
        VStack(spacing: 0) {
            row("Dose", meal.doseUnits.map { "\(units($0))U" } ?? "not dosed here")
            Divider()
            // Everything GlucOS delivered over the window, from our own
            // records. This is not the meal dose plus a bit — the loop was
            // running the whole time, and most of this is basal.
            //
            // It stops where the analysis does, so a second announcement ends
            // the count: past that point the insulin going in is for the next
            // plate, and adding it here would read as this meal having taken
            // far more than it did.
            row("Insulin delivered", "\(units(data.insulinDelivered))U")
            Divider()
            row("Outcome", outcomeText)
            if data.truncatedByNextMeal {
                Divider()
                // Named with the time, because it is also where the delivered
                // total above stops counting.
                row("Window", "cut short by the next meal at \(MealStyle.time(data.analysisEnd))")
            }
            Divider()
            row("Announced by", meal.bundleIdentifier)
        }
        .font(.footnote)
        .padding(.horizontal, MealStyle.cardPadding)
        .background(
            MealStyle.surface,
            in: RoundedRectangle(cornerRadius: MealStyle.cardRadius, style: .continuous)
        )
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
    }

    private var outcomeText: String {
        switch data.outcome {
        case .predictedLow(let at):
            return "predicted low at \(at.toLocaleTimeString()) — dose less"
        case .roseTooHigh(let at):
            return "rose over \(Int(MealDosingPolicy.excursionThresholdMgDl)) mg/dL by \(at.toLocaleTimeString()) — dose more"
        case .onTarget:
            return "held — no change"
        case .unknown:
            // Said plainly rather than dressed up as a good outcome: "we
            // couldn't see" and "this dose worked" both hold the dose steady,
            // and only one of them is evidence.
            return "not enough data to tell"
        }
    }

    private func units(_ value: Double) -> String {
        return String(format: "%0.2f", value)
    }
}
