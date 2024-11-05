//
//  Colors.swift
//  BioKernel
//
//  Created by Sam King on 11/3/23.
//

import LoopKit
import LoopKitUI
import SwiftUI

extension UIColor {
    @nonobjc public static let agingColor = UIColor(Color.warning)
    
    @nonobjc public static let axisLabelColor = secondaryLabel
    
    @nonobjc public static let axisLineColor = clear
    
    @nonobjc public static let cellBackgroundColor = secondarySystemBackground
    
    //@nonobjc public static let carbTintColor = carbs
    
    @nonobjc public static let critical = systemRed
    
    @nonobjc public static let destructive = critical
    
    @nonobjc public static let freshColor = UIColor(Color.fresh)

    @nonobjc public static let glucoseTintColor = UIColor(Color.glucose)
    
    @nonobjc public static let gridColor = systemGray3
    
    @nonobjc public static let invalid = critical

    @nonobjc public static let insulinTintColor = UIColor(Color.insulin)
    
    @nonobjc public static let pumpStatusNormal = UIColor(Color.insulin)
    
    @nonobjc public static let staleColor = critical
    
    @nonobjc public static let unknownColor = systemGray4
}

extension Color {
    public static let agingColor = warning
    
    public static let axisLabelColor = secondary
    
    public static let axisLineColor = clear
    
    public static let cellBackgroundColor = Color(UIColor.cellBackgroundColor)
    
    public static let carbTintColor = carbs
    
    public static let critical = red
    
    public static let destructive = critical
    
    public static let glucoseTintColor = glucose
    
    public static let gridColor = Color(UIColor.gridColor)

    public static let invalid = critical

    public static let insulinTintColor = insulin
    
    public static let pumpStatusNormal = insulin
    
    public static let staleColor = critical
    
    public static let unknownColor = Color(UIColor.unknownColor)
}

extension StateColorPalette {
    static let loopStatus = StateColorPalette(unknown: .unknownColor, normal: .freshColor, warning: .agingColor, error: .staleColor)

    static let cgmStatus = loopStatus

    static let pumpStatus = StateColorPalette(unknown: .unknownColor, normal: .pumpStatusNormal, warning: .agingColor, error: .staleColor)
}

extension ChartColorPalette {
    static var primary: ChartColorPalette {
        return ChartColorPalette(axisLine: .axisLineColor, axisLabel: .axisLabelColor, grid: .gridColor, glucoseTint: .glucoseTintColor, insulinTint: .insulinTintColor)
    }
}

extension GuidanceColors {
    public static var `default`: GuidanceColors {
        return GuidanceColors(acceptable: .primary, warning: .warning, critical: .critical)
    }
}

extension LoopUIColorPalette {
    public static var `default`: LoopUIColorPalette {
        return LoopUIColorPalette(guidanceColors: .default,
                                  carbTintColor: .carbTintColor,
                                  glucoseTintColor: .glucoseTintColor,
                                  insulinTintColor: .insulinTintColor,
                                  loopStatusColorPalette: .loopStatus,
                                  chartColorPalette: .primary)
    }
}
