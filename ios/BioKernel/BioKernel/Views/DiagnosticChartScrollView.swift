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

    init(selectedHours: Binding<Int>, @ViewBuilder content: () -> Content) {
        self._selectedHours = selectedHours
        self.content = content()
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        content
                            .padding()
                            .frame(width: geometry.size.width * (selectedHours > 0 ? CGFloat(24 / selectedHours) : 1.0))
                        
                        Color.clear.frame(width: 0, height: 0).id("scroll_end_anchor")
                    }
                }
                .onAppear {
                    proxy.scrollTo("scroll_end_anchor", anchor: .trailing)
                }
                .onChange(of: selectedHours) { _ in
                    withAnimation {
                        proxy.scrollTo("scroll_end_anchor", anchor: .trailing)
                    }
                }
            }
        }
    }
}
