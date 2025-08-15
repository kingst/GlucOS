
//
//  HistoryView.swift
//  BioKernel
//
//  Created by Sam King on 8/15/25.
//

import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var viewModel: DiagnosticViewModel
    
    private let itemFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
    
    var body: some View {
        List(viewModel.chartData.sorted(by: { $0.at > $1.at }), id: \.at) { data in
            VStack(alignment: .leading) {
                Text("Time: \(data.at, formatter: itemFormatter)")
                Text("Glucose: \(Int(data.glucose))")
                Text(String(format: "Temp Basal: %.2f", data.tempBasal))
                Text(String(format: "Micro Bolus: %.2f", data.microBolusAmount))
            }
        }
    }
}
