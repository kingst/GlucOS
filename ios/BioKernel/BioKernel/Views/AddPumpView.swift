//
//  AddPumpView.swift
//  BioKernel
//
//  Created by Sam King on 11/6/23.
//

import SwiftUI

import LoopKit
import LoopKitUI


private struct PumpSetup: Identifiable {
    let identifier: String
    let result: Swift.Result<SetupUIResult<PumpManagerViewController, PumpManagerUI>, Error>

    var id: String { identifier }
}

struct AddPumpView: View {
    @State private var pumpSetup: PumpSetup?

    @Environment(\.dismiss) var dismiss
    @Environment(\.composition) var composition: AppComposition?

    var body: some View {
        let pumpDescriptors = composition?.deviceDataManager.pumpManagerDescriptors() ?? []
        List {
            ForEach(pumpDescriptors, id: \.identifier) { pumpDescriptor in
                Button {
                    guard let composition else { return }
                    pumpSetup = PumpSetup(
                        identifier: pumpDescriptor.identifier,
                        result: composition.deviceDataManager.setupPumpManagerUI(withIdentifier: pumpDescriptor.identifier)
                    )
                } label: {
                    Text(pumpDescriptor.localizedTitle)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Add pump")
        .sheet(item: $pumpSetup, onDismiss: didDismiss) { setup in
            switch setup.result {
            case .failure(let error):
                Text("failed to setup pump manager: \(String(describing: error))")
            case .success(.userInteractionRequired(let setupViewController)):
                PumpSetupView(setupViewController: setupViewController)
            case .success(.createdAndOnboarded(let pumpManagerUI)):
                PumpManagerView(pumpManagerUI: pumpManagerUI)
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
