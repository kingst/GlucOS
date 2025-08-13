//
//  CGMManagerViews.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import SwiftUI
import LoopKitUI
import MockKit

struct CGMManagerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController
    let cgmManagerUI: CGMManagerUI
    
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        let deviceManager = getDeviceDataManager()
        var vc = deviceManager.cgmSettingsUI(for: cgmManagerUI)
        vc.completionDelegate = context.coordinator
        
        // For MockCGMManager, the setup UI is the settings UI. When setting up, a new
        // instance of the cgm manager is created. When viewing settings for an existing
        // cgm, the existing instance is used. We can use this to tell the difference
        // and only add the "Done" button during setup.
        if cgmManagerUI is MockCGMManager {
            if deviceManager.cgmManager !== cgmManagerUI {
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

struct CGMSetupView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController
    let setupViewController: CGMManagerViewController
    
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
