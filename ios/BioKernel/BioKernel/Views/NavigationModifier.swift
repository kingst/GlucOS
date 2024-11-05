//
//  OverviewViewModifier.swift
//  Type Zero
//
//  Created by Sam King on 4/4/23.
//

import SwiftUI

struct NavigationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .navigationViewStyle(.stack)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(AppColors.primary, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
    }
}
