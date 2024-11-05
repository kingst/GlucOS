//
//  PumpManagerViews.swift
//  BioKernel
//
//  Created by Sam King on 11/6/23.
//

import SwiftUI

import LoopKitUI

struct PumpManagerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController
    let pumpManagerUI: PumpManagerUI
    
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        let deviceManager = getDeviceDataManager()
        var vc = deviceManager.pumpSettingsUI(for: pumpManagerUI)
        vc.completionDelegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Updates the state of the specified view controller with new information from SwiftUI.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }
    
    class Coordinator: CompletionDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }
        
        func completionNotifyingDidComplete(_ object: LoopKitUI.CompletionNotifying) {
            dismiss()
        }
    }
}

struct PumpSetupView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController
    let setupViewController: PumpManagerViewController
    
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        var vc = setupViewController
        vc.completionDelegate = context.coordinator
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Updates the state of the specified view controller with new information from SwiftUI.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }
    
    class Coordinator: CompletionDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }
        
        func completionNotifyingDidComplete(_ object: LoopKitUI.CompletionNotifying) {
            dismiss()
        }
    }
}
