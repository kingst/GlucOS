//
//  MainView.swift
//  BioKernel
//
//  Created by Sam King on 12/18/23.
//

import SwiftUI
import LoopKit
import LoopKitUI



let addButtonRadius = 30.0

/// A meal handoff, resolved. Held as one value so the view can't render a meal
/// paired with another meal's reference window.
struct MealAnnouncementTarget {
    let meal: StoredMeal
    let reference: StoredMeal?
}

struct MainView: View {
    @EnvironmentObject var appState: AppObservableState
    @Environment(\.composition) var composition: AppComposition?
    @State var navigateToSettingsHome = false
    @State var navigateToAddCgm = false
    @State var navigateToCgmSettings = false
    @State var navigateToAddPump = false
    @State var navigateToPumpSettings = false
    @State var navigateToBolus = false
    @State var navigateToMeals = false
    @State var navigateToMealAnnouncement = false
    @State var mealFromUrl: MealAnnouncementTarget? = nil
    @State var selectedHours = 4
    @State var showChartSettingsSheet = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MainViewSummaryView()
                MainViewAlertView()
                Spacer()
                VStack {
                    GlucoseChartView(selectedHours: selectedHours)
                    
                    HStack {
                        Button(action: {
                            showChartSettingsSheet = true
                        }) {
                            Image(systemName: "wrench.and.screwdriver")
                        }
                        ForEach([2, 4, 6, 12], id: \.self) { hour in
                            Button(action: {
                                selectedHours = hour
                            }) {
                                Text(selectedHours == hour ? "\(hour) hrs" : "\(hour)")
                                    .padding(.vertical, 5)
                                    .padding(.horizontal)
                                    .background(selectedHours == hour ? Color.gray : Color.clear)
                                    .foregroundColor(selectedHours == hour ? .white : .blue)
                                    .cornerRadius(8)
                                    .animation(nil, value: selectedHours)
                            }
                        }
                        Spacer()
                        Button {
                            navigateToBolus = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .frame(width: 2 * addButtonRadius, height: 2 * addButtonRadius)
                        .background(AppColors.primary)
                        .foregroundColor(.white)
                        .clipShape(Circle())
                    }
                }
                .padding()
            }
            .modifier(NavigationModifier())
            .navigationTitle("BioKernel")
            .toolbar {
                // One item per button. iOS 26+ merges adjacent items in the
                // same placement into a single Liquid Glass capsule, so a
                // fixed spacer between them gives each its own glass button.
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if appState.cgmManager == nil {
                            navigateToAddCgm = true
                        } else {
                            navigateToCgmSettings = true
                        }
                    } label: {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                            .tint(.white)
                    }
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if appState.pumpManager == nil {
                            navigateToAddPump = true
                        } else {
                            navigateToPumpSettings = true
                        }
                    } label: {
                        // Template asset, so it tints white like the SF Symbol
                        // buttons; sized to sit level with them.
                        Image("pod-icon")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 32)
                            .tint(.white)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        navigateToMeals = true
                    } label: {
                        Image(systemName: "fork.knife").tint(.white)
                    }
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        navigateToSettingsHome = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .tint(.white)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToSettingsHome) {
                SettingsHomeView()
            }
            .navigationDestination(isPresented: $navigateToAddCgm) {
                AddCGMView()
            }
            .sheet(isPresented: $navigateToCgmSettings) {
                if let cgmManager = appState.cgmManager, let cgmManagerUI = cgmManager as? CGMManagerUI {
                    CGMManagerView(cgmManagerUI: cgmManagerUI)
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(isPresented: $navigateToAddPump) {
                AddPumpView()
            }
            .sheet(isPresented: $navigateToPumpSettings) {
                if let pumpManager = appState.pumpManager {
                    PumpManagerView(pumpManagerUI: pumpManager)
                } else {
                    EmptyView()
                }
            }
            .navigationDestination(isPresented: $navigateToBolus) {
                BolusView()
            }
            .navigationDestination(isPresented: $navigateToMeals) {
                if let composition {
                    MealsView(mealStorage: composition.mealStorage)
                }
            }
            .navigationDestination(isPresented: $navigateToMealAnnouncement) {
                if let composition, let mealFromUrl {
                    MealAnnouncementView(
                        meal: mealFromUrl.meal,
                        referenceMeal: mealFromUrl.reference,
                        composition: composition
                    )
                    // Identity is the meal, not the slot in the stack.
                    //
                    // A second handoff can arrive while this screen is still
                    // pushed: the user leaves for the AI app without dosing —
                    // `MealAnnouncementView` only dismisses after a delivered
                    // bolus — announces another meal there, and its link comes
                    // straight back here. `navigateToMealAnnouncement` is
                    // already true at that point, so the presentation doesn't
                    // change, and `MealAnnouncementView` seeds both of its
                    // `@StateObject`s from `meal` in `init` — an autoclosure
                    // SwiftUI only runs when it creates storage for a *new*
                    // view identity. Without this the screen keeps rendering
                    // the previous meal, which is a dose recommendation for
                    // food the user isn't eating.
                    //
                    // `StoredMeal.id` is the `bundleIdentifier`/`mealId` pair,
                    // so a different meal is a different view with fresh view
                    // models, and re-opening the same meal's link is still a
                    // no-op rather than a reload.
                    .id(mealFromUrl.meal.id)
                }
            }
            .sheet(isPresented: $showChartSettingsSheet) {
                if let composition {
                    DiagnosticDataView(viewModel: DiagnosticViewModel(
                        closedLoopService: composition.closedLoopService,
                        insulinStorage: composition.insulinStorage
                    ))
                }
            }
            .onOpenURL { url in
                // A meal handoff from an AI app, and the only universal link
                // GlucOS handles. `applinks:typezero.ai` is the app's one
                // associated domain and its association file claims only
                // `/meal`, so a URL that doesn't parse as one should not have
                // been delivered here at all — the right response is to ignore
                // it, not to guess at what else it might have meant.
                //
                // Guessing is what the retired settings-import link did: it
                // decoded whatever the last path component held as
                // `CodableSettings` and pre-filled the therapy settings form
                // with it. That form is max basal rate, ISF and glucose
                // targets, one Save tap from live dosing.
                guard let target = MealAnnouncementLink.parse(url) else { return }
                openMealAnnouncement(target)
            }
        }
    }

    /// Resolve a meal handoff and navigate to it.
    ///
    /// Ingests before looking the meal up. The AI app appends its announcement
    /// and opens this link immediately, so the row is almost never in the store
    /// yet — the next scheduled ingest is up to a loop tick away, and waiting
    /// for it would make the handoff fail for five minutes at a time. Ingestion
    /// is idempotent, so doing it here costs nothing but the read.
    private func openMealAnnouncement(_ target: (bundleIdentifier: String, mealId: String)) {
        guard let composition else { return }
        Task {
            await composition.mealStorage.ingest(at: Date())
            guard let meal = await composition.mealStorage.meal(
                bundleIdentifier: target.bundleIdentifier,
                mealId: target.mealId
            ), !meal.isCancelled else { return }
            let reference = await composition.mealStorage.referenceMeal(for: meal)
            mealFromUrl = MealAnnouncementTarget(meal: meal, reference: reference)
            navigateToMealAnnouncement = true
        }
    }

}

#Preview {
    MainView()
}
