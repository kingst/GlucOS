//
//  SaveDataView.swift
//  BioKernel
//
//  Created by Sam King on 9/4/24.
//

import SwiftUI

struct SaveDataView: View {
    @StateObject var saveDataViewModel = SaveDataViewModel()
    var body: some View {
        VStack {
            Text("Saving data...")
            ProgressView()
                .opacity(saveDataViewModel.saveComplete ? 0 : 1)
            Text(saveDataViewModel.status)
        }
        .modifier(NavigationModifier())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await saveDataViewModel.saveData()
        }
    }
}

#Preview {
    NavigationStack {
        SaveDataView()
    }
}
