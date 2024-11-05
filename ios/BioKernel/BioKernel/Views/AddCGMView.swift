//
//  AddCGMView.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import SwiftUI

import LoopKit
import LoopKitUI

struct AddCGMView: View {
    @State var descriptor: CGMManagerDescriptor?
    
    var body: some View {
        let cgmDescriptors = getDeviceDataManager().cgmManagerDescriptors()
        List {
            ForEach(cgmDescriptors, id: \.identifier) { cgmDescriptor in
                Button {
                    descriptor = cgmDescriptor
                } label: {
                    Text(cgmDescriptor.localizedTitle)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Add CGM")
        .fullScreenCover(item: $descriptor, onDismiss: didDismiss) { detail in
            let deviceManager = getDeviceDataManager()
            switch deviceManager.setupCGMManagerUI(withIdentifier: detail.identifier) {
            case .failure(let error):
                Text("failed to setup cgm manager: \(String(describing: error))")
            case .success(let success):
                switch success {
                case .userInteractionRequired(let setupViewController):
                    CGMSetupView(setupViewController: setupViewController)
                case .createdAndOnboarded(let cgmManagerUI):
                    CGMManagerView(cgmManagerUI: cgmManagerUI)
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
