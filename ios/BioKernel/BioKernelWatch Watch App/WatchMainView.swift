//
//  ContentView.swift
//  BioKernelWatch Watch App
//
//  Created by Sam King on 12/10/24.
//

import SwiftUI

struct WatchMainView: View {
    @State private var selection = 0
    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                VStack {
                    GlucoseView()
                    GlucoseChart()
                }
                .tag(0)
                // comment out until we get it working
                //StartWorkoutView()
                //.tag(1)
            }
        }
    }
}

#Preview {
    WatchMainView()
}
