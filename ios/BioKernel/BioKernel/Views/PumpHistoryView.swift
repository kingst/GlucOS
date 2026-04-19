//
//  PumpHistoryView.swift
//  BioKernel
//
//  Created by Sam King on 8/17/25.
//

import SwiftUI

struct PumpHistoryView: View {
    @EnvironmentObject var viewModel: DiagnosticViewModel

    var body: some View {
        List(viewModel.pumpHistory, id: \.self) { dose in
            PumpHistoryRowView(dose: dose)
        }
    }
}

struct PumpHistoryRowView: View {
    let dose: PumpDose

    var body: some View {
        HStack {
            BlinkingDotView(isBlinking: dose.isActive)
                .frame(width: 10, height: 10)
                .foregroundColor(dose.color)
            
            Text(dose.description)
            
            Spacer()
            
            Text(dose.date.toLocaleTimeString())
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

struct BlinkingDotView: View {
    let isBlinking: Bool
    @State private var isVisible = true

    var body: some View {
        Circle()
            .opacity(isVisible ? 1.0 : 0.0)
            .onAppear {
                guard isBlinking else { return }
                // Use a task to run the async animation loop
                Task {
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            isVisible.toggle()
                        }
                        // Use try? await Task.sleep so it can be cancelled
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
    }
}

// MARK: - UI Helpers
extension PumpDose {
    var isActive: Bool {
        switch self {
        case .bolus(let bolus):
            return !bolus.isComplete
        case .basal(let basal):
            return !basal.isComplete
        case .suspend, .resume:
            return false
        }
    }

    var color: Color {
        switch self {
        case .suspend:
            return .yellow
        case .resume:
            return .green
        case .bolus(let bolus):
            return bolus.isMicroBolus ? .teal : .blue
        case .basal:
            return .purple
        }
    }

    var description: String {
        switch self {
        case .suspend:
            return "Suspend"
        case .resume:
            return "Resume"
        case .bolus(let bolus):
            let amount = String(format: "%.2fU", bolus.isComplete ? (bolus.deliveredUnits ?? 0.0) : bolus.programmedUnits)
            return bolus.isMicroBolus ? "Auto bolus \(amount)" : "Bolus \(amount)"
        case .basal(let basal):
            if basal.isComplete {
                let amount = String(format: "%.2fU", basal.deliveredUnits ?? 0.0)
                return "Temp basal \(amount)"
            } else {
                let rate = String(format: "%.2f U/h", basal.rate)
                return "Temp basal \(rate)"
            }
        }
    }
}

extension Date {
    func toLocaleTimeString() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

