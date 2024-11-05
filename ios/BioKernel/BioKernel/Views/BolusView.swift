//
//  Bolus.swift
//  BioKernel
//
//  Created by Sam King on 11/27/23.
//

import SwiftUI

struct BolusView: View {
    @Environment(\.dismiss) var dismiss
    @State var bolusAmount: String = ""
    @State var bolusError: String? = nil
    @State var useMealAnnoucements = true
    
    var body: some View {
        VStack {
            if useMealAnnoucements {
                MealAnnounceView(bolusAmount: $bolusAmount)
            } else {
                BolusEnterUnitsView(bolusAmount: $bolusAmount)
            }
            Spacer().frame(height: 16)
            Button {
                Task {
                    guard let pumpManager = getDeviceDataManager().pumpManager else {
                        bolusError = "No pump found"
                        return
                    }
                    
                    guard let units = Double(bolusAmount) else {
                        bolusError = "Could not read the bolus amount!"
                        return
                    }
                    
                    let unitsRounded = pumpManager.roundToSupportedBolusVolume(units: units)
                    let maxBolusUnits = getSettingsStorage().snapshot().maxBolusUnits
                    
                    guard unitsRounded <= maxBolusUnits else {
                        bolusError = "Bolus \(unitsRounded)U is above the max of \(maxBolusUnits)U"
                        return
                    }
                    
                    guard unitsRounded > 0.0 else {
                        bolusError = "Bolus must be greater than 0"
                        return
                    }
                    
                    let error = await FaceId.authenticate()
                    
                    switch error {
                    case .some(_):
                        bolusError = "Not authenticated"
                    case .none:
                        if let error = await pumpManager.enactBolus(units: unitsRounded, activationType: .manualNoRecommendation) {
                            bolusError = error.localizedDescription
                            return
                        } else {
                            dismiss()
                        }
                    }
                }
            } label: {
                Text("Deliver").frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(AppColors.primary)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .font(.headline)
            
            Spacer().frame(height: 16)
            if useMealAnnoucements {
                Button {
                    bolusAmount = ""
                    useMealAnnoucements = false
                } label: {
                    Text("Enter units")
                }
            } else {
                Button {
                    bolusAmount = ""
                    useMealAnnoucements = true
                } label: {
                    Text("Announce carbs")
                }
            }
            
            if let error = bolusError {
                Text(error).foregroundColor(.red)
            } else {
                Spacer().frame(height: 24)
            }
            
        }
        .modifier(NavigationModifier())
        .padding()
        .navigationTitle("Bolus")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    BolusView()
}

struct BolusEnterUnitsView: View {
    @Binding var bolusAmount: String
    @FocusState var showKeyboard: Bool
    
    var body: some View {
        Text("Units of insulin").bold()
        TextField("", text: $bolusAmount)
            .keyboardType(.decimalPad)
            .focused($showKeyboard)
            .onAppear {
                DispatchQueue.main.async {
                    self.showKeyboard = true
                }
            }
            .font(.largeTitle)
            .multilineTextAlignment(.center)
    }
}

enum MealItemValue: String, CaseIterable {
    case less, usual, more
}

extension MealItemValue {
    @MainActor func units() -> Double {
        let settings = getSettingsStorage().snapshot()
        switch (self) {
        case .less:
            return settings.getBolusAmountForLess()
        case .usual:
            return settings.getBolusAmountForUsual()
        case .more:
            return settings.getBolusAmountForMore()
        }
    }
}

struct MealItem: Identifiable {
    let id = UUID()
    let description: String
    let emoji: String
    let value: MealItemValue
}

struct MealAnnounceView: View {
    @Binding var bolusAmount: String
    let items = [
        MealItem(description: "More", emoji: "🍔🥤🍟", value: .more),
        MealItem(description: "Usual for me", emoji: "🥪🍎", value: .usual),
        MealItem(description: "Less", emoji: "🥗", value: .less)
    ]
    
    @State private var selectedItem: MealItemValue = .usual
    
    var body: some View {
        Text("Announce carbs").font(.title)
        Form {
            Picker("Select meal size", selection: $selectedItem) {
                ForEach(items) { item in
                    HStack {
                        Text(item.description)
                        Spacer()
                        Text(item.emoji)
                    }
                    .tag(item.value)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: selectedItem) { value in
                bolusAmount = "\(selectedItem.units())"
            }
            .onAppear {
                bolusAmount = "\(selectedItem.units())"
            }
        }
    }
}
