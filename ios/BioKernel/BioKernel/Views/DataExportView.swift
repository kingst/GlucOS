//
//  DataExportView.swift
//  BioKernel
//

import SwiftUI

struct DataExportView: View {
    var body: some View {
        Form {
            Section {
                if let url = closedLoopResultsURL() {
                    ShareLink(item: url) {
                        Label("Share closed loop data", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text("No closed loop data yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Data export")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func closedLoopResultsURL() -> URL? {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return nil
        }
        let url = documents.appendingPathComponent("closed_loop_results.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

#Preview {
    NavigationStack {
        DataExportView()
    }
}
