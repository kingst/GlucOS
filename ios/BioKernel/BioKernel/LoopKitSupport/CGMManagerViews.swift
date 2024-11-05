//
//  CGMManagerViews.swift
//  BioKernel
//
//  Created by Sam King on 11/9/23.
//

import SwiftUI

import LoopKitUI

struct CGMManagerView: UIViewControllerRepresentable {
    typealias UIViewControllerType = UIViewController
    let cgmManagerUI: CGMManagerUI
    
    @Environment(\.dismiss) var dismiss
    
    func makeUIViewController(context: Context) -> UIViewController {
        let deviceManager = getDeviceDataManager()
        var vc = deviceManager.cgmSettingsUI(for: cgmManagerUI)
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
