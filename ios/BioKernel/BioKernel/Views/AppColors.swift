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
    static let yellow = Color(hex: 0xECCC68)
    static let lightRed = Color(hex: 0xFF7F50)
    static let orange = Color(hex: 0xFFA502)
    static let red = Color(hex: 0xFF6348)
    static let green = Color(hex: 0x7BED9F)
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
