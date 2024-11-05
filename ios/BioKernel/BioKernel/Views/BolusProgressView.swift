//
//  BolusProgressView.swift
//  BioKernel
//
//  Created by Sam King on 12/18/23.
//

import SwiftUI

struct BolusProgressView: View {
    @ObservedObject var doseProgress: DoseProgress = getDeviceDataManager().observableObject().doseProgress
    var body: some View {
        VStack {
            Text("Delivered \(String(format: "%0.2f", doseProgress.deliveredUnits)) of \(String(format: "%0.2f", doseProgress.totalUnits)) units")
            Button {
                getDeviceDataManager().pumpManager?.cancelBolus() { result in
                    switch result {
                    case .success:
                        doseProgress.cancel()
                    case .failure(let error):
                        doseProgress.error = error.localizedDescription
                    }
                }
            } label: {
                Text("Cancel").frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(AppColors.red)
            .foregroundColor(.white)
            .clipShape(Capsule())
            .font(.headline)
            
            if let error = doseProgress.error {
                Text(error).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(AppColors.yellow)
        .foregroundColor(.black)
        .bold()
    }
}

#Preview {
    BolusProgressView()
}
