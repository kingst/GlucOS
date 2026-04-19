//
//  AddPumpView.swift
//  BioKernel
//
//  Created by Sam King on 11/6/23.
//

import SwiftUI

import LoopKit
import LoopKitUI

struct AddPumpView: View {
    @State var descriptor: PumpManagerDescriptor?

    @Environment(\.dismiss) var dismiss
    @Environment(\.composition) var composition: AppComposition?

    var body: some View {
        let pumpDescriptors = composition?.deviceDataManager.pumpManagerDescriptors() ?? []
        List {
            ForEach(pumpDescriptors, id: \.identifier) { pumpDescriptor in
                Button {
                    descriptor = pumpDescriptor
                } label: {
                    Text(pumpDescriptor.localizedTitle)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Add pump")
        .sheet(item: $descriptor, onDismiss: didDismiss) { detail in
            if let composition {
                switch composition.deviceDataManager.setupPumpManagerUI(withIdentifier: detail.identifier) {
                case .failure(let error):
                    Text("failed to setup pump manager: \(String(describing: error))")
                case .success(let success):
                    switch success {
                    case .userInteractionRequired(let setupViewController):
                        PumpSetupView(setupViewController: setupViewController)
                    case .createdAndOnboarded(let pumpManagerUI):
                        PumpManagerView(pumpManagerUI: pumpManagerUI)
                    }
                }
            }
        }
    }
    func didDismiss() {
        dismiss()
    }
}

#Preview {
    AddPumpView()
}
