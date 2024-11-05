//
//  CarbCalculatorView.swift
//  BioKernel
//
//  Created by Sam King on 2/21/24.
//

import SwiftUI

struct CarbCalculatorView: View {
    @Environment(\.dismiss) var dismiss
    @Binding var bolusAmount: String
    @State var carbAmount: String = ""
    @State var carbError: String? = nil
    @FocusState var showKeyboard: Bool
    
    var body: some View {
        VStack {
            Text("Carbs (g)").bold()
            TextField("", text: $carbAmount)
                .keyboardType(.decimalPad)
                .focused($showKeyboard)
                .onAppear {
                    DispatchQueue.main.async {
                        self.showKeyboard = true
                    }
                }
                .font(.largeTitle)
                .multilineTextAlignment(.center)
            Spacer().frame(height: 16)
            Button {
                guard let grams = Double(carbAmount) else {
                    carbError = "Could not read the carb amount"
                    return
                }
                
                Task {
                    let bolus = await getPhysiologicalModels().calculateBolus(carbsInG: grams)
                    bolusAmount = "\(String(format: "%0.02f", bolus))"
                    dismiss()
                }
                
            } label: {
                Text("Bolus")
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(AppColors.primary)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .font(.headline)
            
            if let error = carbError {
                Text(error).foregroundColor(.red)
            } else {
                Spacer().frame(height: 24)
            }
        }
        .padding()
    }
}

#Preview {
    CarbCalculatorView(bolusAmount: .constant(""))
}
