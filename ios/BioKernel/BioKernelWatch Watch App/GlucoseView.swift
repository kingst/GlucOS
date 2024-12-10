//
//  GlucoseView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct GlucoseView: View {
    var body: some View {
        VStack {
            HStack {
                VStack {
                    Text("102").font(.title2)
                    Text("mg/dl")
                }
                .frame(maxWidth: .infinity)
                VStack {
                    Text("Pred")
                    Text("111")
                        .font(.title2)
                        .foregroundColor(.blue)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            Text("Last reading: 3m")
                .padding()
        }
    }
}

#Preview {
    GlucoseView()
}
