
//
//  PumpManagerViews.swift
//  BioKernel
//
//  Created by Sam King on 11/6/23.
//

import SwiftUI
import LoopKitUI
import MockKit

struct PumpManagerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController
    let pumpManagerUI: PumpManagerUI
    
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        let deviceManager = getDeviceDataManager()
        var vc = deviceManager.pumpSettingsUI(for: pumpManagerUI)
        vc.completionDelegate = context.coordinator
        
        // For MockPumpManager, the setup UI is the settings UI. When setting up, a new
        // instance of the pump manager is created. When viewing settings for an existing
        // pump, the existing instance is used. We can use this to tell the difference
        // and only add the "Done" button during setup.
        if pumpManagerUI is MockPumpManager {
            if deviceManager.pumpManager !== pumpManagerUI {
                if let nav = vc as? UINavigationController {
                    let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: context.coordinator, action: #selector(Coordinator.dismissView))
                    nav.topViewController?.navigationItem.rightBarButtonItem = doneButton
                }
            }
        }
        
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Updates the state of the specified view controller with new information from SwiftUI.
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }
    
    class Coordinator: NSObject, CompletionDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }
        
        func completionNotifyingDidComplete(_ object: LoopKitUI.CompletionNotifying) {
            dismiss()
        }
        
        @objc func dismissView() {
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
    
    class Coordinator: NSObject, CompletionDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }
        
        func completionNotifyingDidComplete(_ object: LoopKitUI.CompletionNotifying) {
            dismiss()
        }
        
        @objc func dismissView() {
            dismiss()
        }
    }
}

