//
//  WorkoutStatusView.swift
//  BioKernel
//
//  Created by Sam King on 12/28/24.
//
import SwiftUI

struct WorkoutStatusView: View {
    let at: Date
    let description: String
    let imageName: String
    
    @State private var currentTime = Date()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    private var duration: Int {
        Int(currentTime.timeIntervalSince(at) / 60.0)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Activity Icon
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 50, height: 50)
                
                Image(systemName: imageName)
                    .font(.title2)
                    .foregroundStyle(.blue)
                
                // Active indicator
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)
                    .offset(x: 18, y: -18)
            }
            
            // Workout Info
            VStack(alignment: .leading, spacing: 4) {
                Text(description)
                    .font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                    Text("\(duration)m")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
            
            Spacer()
            
            // Target Info
            VStack(alignment: .trailing, spacing: 4) {
                Text("Target")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("140")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                Text(" mg/dL")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        )
        .onReceive(timer) { time in
            currentTime = time
        }
    }
}

#Preview {
    WorkoutStatusView(at: Date(), description: "Running", imageName: "figure.run")
}