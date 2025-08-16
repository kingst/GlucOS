//
//  DiagnosticChartScrollView.swift
//  BioKernel
//
//  Created by Sam King on 8/16/25.
//

import SwiftUI

struct DiagnosticChartScrollView<Content: View>: View {
    @Binding var selectedHours: Int
    let content: Content
    let scrollAndAnchorId = "scroll_end_anchor"
    
    init(selectedHours: Binding<Int>, @ViewBuilder content: () -> Content) {
        self._selectedHours = selectedHours
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // avoid divide by 0
                    let hours = selectedHours != 0 ? selectedHours : 4
                    HStack(spacing: 0) {
                        content
                            .padding()
                            .frame(width: geometry.size.width * CGFloat(24 / hours))
                        
                        Color.clear.frame(width: 0, height: 0).id(scrollAndAnchorId)
                    }
                }
                .onAppear {
                    proxy.scrollTo(scrollAndAnchorId, anchor: .trailing)
                }
                .onChange(of: selectedHours) { _ in
                    withAnimation {
                        proxy.scrollTo(scrollAndAnchorId, anchor: .trailing)
                    }
                }
            }
        }
    }
}
