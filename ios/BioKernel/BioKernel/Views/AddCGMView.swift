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
    @Environment(\.dismiss) var dismiss
    @Environment(\.composition) var composition: AppComposition?
    @State var descriptor: CGMManagerDescriptor?

    var body: some View {
        let cgmDescriptors = composition?.deviceDataManager.cgmManagerDescriptors() ?? []
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
        .sheet(item: $descriptor, onDismiss: didDismiss) { detail in
            if let composition {
                switch composition.deviceDataManager.setupCGMManagerUI(withIdentifier: detail.identifier) {
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
    }
    func didDismiss() {
        dismiss()
    }
}

#Preview {
    AddCGMView()
}
