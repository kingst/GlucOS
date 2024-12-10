//
//  ContentView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct WatchMainView: View {
    @State private var selection = 1
    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                GlucoseChart()
                    .tag(0)
                GlucoseView()
                    .tag(1)
                StartWorkoutView()
                    .tag(2)
            }
        }
    }
}

#Preview {
    WatchMainView()
}
