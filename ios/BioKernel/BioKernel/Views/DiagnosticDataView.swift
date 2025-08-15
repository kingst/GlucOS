
//
//  DiagnosticDataView.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import SwiftUI

struct DiagnosticDataView: View {
    @StateObject private var viewModel = DiagnosticViewModel()
    @State private var selectedView = 0
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            VStack {
                Picker("", selection: $selectedView) {
                    Text("History").tag(0)
                    Text("Insulin").tag(1)
                    Text("PID").tag(2)
                    Text("ML").tag(3)
                }
                .pickerStyle(SegmentedPickerStyle())
                
                switch selectedView {
                case 0:
                    HistoryView()
                case 1:
                    InsulinView()
                case 2:
                    PIDView()
                case 3:
                    MLView()
                default:
                    Text("Unknown view")
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("Close") {
                dismiss()
            })
            .environmentObject(viewModel)
        }
    }
}
