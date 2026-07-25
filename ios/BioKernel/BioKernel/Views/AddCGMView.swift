//
//  AddCGMView.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import SwiftUI

import LoopKit
import LoopKitUI


private struct CgmSetup: Identifiable {
    let identifier: String
    let result: Swift.Result<SetupUIResult<CGMManagerViewController, CGMManagerUI>, Error>

    var id: String { identifier }
}

struct AddCGMView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.composition) var composition: AppComposition?
    @State private var cgmSetup: CgmSetup?

    var body: some View {
        let cgmDescriptors = composition?.deviceDataManager.cgmManagerDescriptors() ?? []
        List {
            ForEach(cgmDescriptors, id: \.identifier) { cgmDescriptor in
                Button {
                    guard let composition else { return }
                    cgmSetup = CgmSetup(
                        identifier: cgmDescriptor.identifier,
                        result: composition.deviceDataManager.setupCGMManagerUI(withIdentifier: cgmDescriptor.identifier)
                    )
                } label: {
                    Text(cgmDescriptor.localizedTitle)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Add CGM")
        .sheet(item: $cgmSetup, onDismiss: didDismiss) { setup in
            switch setup.result {
            case .failure(let error):
                Text("failed to setup cgm manager: \(String(describing: error))")
            case .success(.userInteractionRequired(let setupViewController)):
                CGMSetupView(setupViewController: setupViewController)
            case .success(.createdAndOnboarded(let cgmManagerUI)):
                CGMManagerView(cgmManagerUI: cgmManagerUI)
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
