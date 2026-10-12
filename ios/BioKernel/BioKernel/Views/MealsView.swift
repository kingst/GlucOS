//
//  MealsView.swift
//  BioKernel
//
//  The 90 days of meals AI apps have announced. See
//  dev/meal-announcements-from-ai-apps.md.
//
//  A record, not a live surface. Meals arrive through ingestion at the top of
//  each loop tick, so nothing here polls — the list loads on appear and the
//  next appear is the next refresh.
//

import SwiftUI

struct MealsView: View {
    @Environment(\.composition) var composition: AppComposition?
    @StateObject private var viewModel: MealsViewModel

    init(mealStorage: MealStorage) {
        _viewModel = StateObject(wrappedValue: MealsViewModel(mealStorage: mealStorage))
    }

    var body: some View {
        Group {
            if !viewModel.hasLoaded {
                ProgressView()
            } else if viewModel.meals.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "fork.knife")
                        .font(.largeTitle)
                        .foregroundColor(.gray)
                    Text("No meals yet")
                        .font(.headline)
                    Text("Meals appear here when an AI app announces one.")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                // Sectioned by day, the way ClueClue heads its own meal
                // history. This list spans 90 days: unbroken, it is a wall of
                // rows with the same date restated on every one of them.
                List {
                    ForEach(viewModel.mealsByDay) { group in
                        Section(MealStyle.daySection(group.day)) {
                            // Keyed on the whole identity, not `mealId`: that
                            // is only unique within one app.
                            ForEach(group.meals) { meal in
                                NavigationLink {
                                    if let composition {
                                        MealDetailView(meal: meal, composition: composition)
                                    }
                                } label: {
                                    MealRowView(meal: meal)
                                }
                            }
                        }
                    }
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Meals")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load()
        }
    }
}

struct MealRowView: View {
    let meal: StoredMeal

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meal.mealDescription)
                .lineLimit(2)
            HStack {
                // Time only: the section header above the row carries the day.
                Text(MealStyle.time(meal.startTime))
                    .font(.caption)
                    .foregroundColor(.gray)
                Spacer()
                // The dose, or its absence. A meal with no dose is not an
                // error — most announced meals are never dosed from this
                // screen — but it is the one thing that decides whether the
                // next plate of this can learn from it.
                if let doseUnits = meal.doseUnits {
                    Text("\(units(doseUnits))U")
                        .font(.caption)
                        .foregroundColor(AppColors.deepIndigo)
                } else {
                    Text("no dose")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
    }

    private func units(_ value: Double) -> String {
        return String(format: "%0.2f", value)
    }
}

extension Date {
    /// Day and time together, for the detail screen — the one meal surface
    /// with no section header to say which day it is.
    func toMealDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}
