//
//  GlucoseAlertsView.swift
//  BioKernel
//
//  Created by Sam King on 7/16/24.
//

import SwiftUI

struct GlucoseAlertValue: Hashable, Identifiable {
    let id: String
    let value: Int
}

struct GlucoseAlertsView: View {
    @EnvironmentObject var viewModel: GlucoseAlertsViewModel
    var body: some View {
        VStack {
            Form {
                Toggle(isOn: $viewModel.enabled, label: {
                    Text("Enable glucose alerts")
                })
                .onChange(of: viewModel.enabled) { _, newValue in
                    viewModel.updateEnabled(newValue)
                }
                
                Section("High alerts") {
                    Picker("High", selection: $viewModel.highLevel) {
                        ForEach(viewModel.highLevelValues) { item in
                            Text(item.id).tag(item)
                        }
                    }
                    .onChange(of: viewModel.highLevel) { _, newValue in
                        viewModel.updateHighLevel(newValue)
                    }
                    Picker("Repeats", selection: $viewModel.highRepeats) {
                        ForEach(viewModel.highRepeatsValues) { item in
                            Text(item.id).tag(item)
                        }
                    }
                    .onChange(of: viewModel.highRepeats) { _, newValue in
                        viewModel.updateHighRepeats(newValue)
                    }
                }
                
                Section("Low alerts") {
                    Picker("Low", selection: $viewModel.lowLevel) {
                        ForEach(viewModel.lowLevelValues) { item in
                            Text(item.id).tag(item)
                        }
                    }
                    .onChange(of: viewModel.lowLevel) { _, newValue in
                        viewModel.updateLowLevel(newValue)
                    }
                    Picker("Repeats", selection: $viewModel.lowRepeats) {
                        ForEach(viewModel.lowRepeatsValues) { item in
                            Text(item.id).tag(item)
                        }
                    }
                    .onChange(of: viewModel.lowRepeats) { _, newValue in
                        viewModel.updateLowRepeats(newValue)
                    }
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Predictive Glucose Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        GlucoseAlertsView()
    }
}
