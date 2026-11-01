//
//  AppColors.swift
//  Type Zero
//
//  Created by Sam King on 3/31/23.
//

import SwiftUI

struct AppColors {
    // Primary is 0x70A1FF with 0.5 alpha for dark mode
    static let primary = Color("DarkAwarePrimary")
    /// `primary` resolved for `scheme`, as a plain color.
    ///
    /// For a bar under `toolbarColorScheme(.dark)`, which resolves dynamic
    /// colors in its own dark appearance and so would always pick the
    /// half-transparent dark variant.
    static func primary(for scheme: ColorScheme) -> Color {
        guard let dynamic = UIColor(named: "DarkAwarePrimary") else { return primary }
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        return Color(uiColor: dynamic.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
    }
    static let yellow = Color(hex: 0xECCC68)
    static let lightRed = Color(hex: 0xFF7F50)
    static let orange = Color(hex: 0xFFA502)
    static let red = Color(hex: 0xFF6348)
    static let green = Color(hex: 0x7BED9F)
    static let deepIndigo = Color(hex: 0x4A5699)
    /// The exercise override, on the banner and the chart. Dark enough for
    /// white text; distinct from the indigo meal-soon banner and the yellow alert.
    static let teal = Color(hex: 0x1D7874)
}

// https://stackoverflow.com/a/56894458
extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 08) & 0xff) / 255,
            blue: Double((hex >> 00) & 0xff) / 255,
            opacity: alpha
        )
    }
}
