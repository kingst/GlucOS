//
//  OverviewViewModifier.swift
//  Type Zero
//
//  Created by Sam King on 4/4/23.
//

import SwiftUI

struct NavigationModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .navigationViewStyle(.stack)
            .navigationBarTitleDisplayMode(.inline)
            // Resolved for the app's scheme rather than handed the dynamic
            // color: the dark scheme forced below puts the bar in its own dark
            // appearance, and that is where the bar resolves dynamic colors, so
            // `AppColors.primary` always came out as its half-transparent dark
            // variant and in light mode washed out the bar and its white title.
            .toolbarBackground(AppColors.primary(for: colorScheme), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
