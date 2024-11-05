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
    
    var body: some View {
        let pumpDescriptors = getDeviceDataManager().pumpManagerDescriptors()
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
        .fullScreenCover(item: $descriptor, onDismiss: didDismiss) { detail in
            let deviceManager = getDeviceDataManager()
            switch deviceManager.setupPumpManagerUI(withIdentifier: detail.identifier) {
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
    func didDismiss() {
        // no action needed
    }
}

#Preview {
    AddPumpView()
}
