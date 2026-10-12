//
//  MealStyle.swift
//  BioKernel
//
//  The handful of tokens the meal screens need to match ClueClue's dosing
//  layout (figure 4 of the ClueClue paper). Ported as *semantics*, not as
//  hex values: ClueClue ships a full design system with light/dark pairs for
//  every colour, and copying that into GlucOS would be a second design system
//  to maintain for three screens.
//
//  So the surfaces and text colours here come from UIKit's semantic set, which
//  gives correct light/dark behaviour for free and already matches the grouped
//  forms GlucOS uses everywhere else. Only the brand colours are ours, from
//  `AppColors`.
//

import SwiftUI

enum MealStyle {
    // MARK: - Surfaces

    /// The screen behind the cards.
    static let canvas = Color(.systemGroupedBackground)
    /// A card.
    static let surface = Color(.secondarySystemGroupedBackground)
    /// Hairlines and dividers.
    static let line = Color(.separator)
    /// Brand wash behind the stepper buttons and the type pill.
    static let brandTint = AppColors.primary.opacity(0.15)

    // MARK: - Metrics

    static let cardRadius: CGFloat = 16.0
    static let chipRadius: CGFloat = 12.0
    /// Inside a card.
    static let cardPadding: CGFloat = 16.0
    /// Between cards.
    static let stackSpacing: CGFloat = 16.0
    /// The dose number. Rounded and heavy, as in the figure — this is the one
    /// number on the screen the user is really reading.
    static let doseFontSize: CGFloat = 56.0

    // MARK: - Timeline

    /// Width of the timeline's time column, so the glyphs line up in a rail.
    static let timelineTimeColumn: CGFloat = 64.0
    static let timelineGlyph: CGFloat = 28.0

    // MARK: - Formatting

    /// Doses, everywhere on these screens.
    static func units(_ value: Double) -> String {
        return String(format: "%0.2f", value)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "WED, AUG 12" — the reference window's header.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE, MMM d")
        return formatter.string(from: date)
    }

    /// "Today" / "Yesterday" / "Wed, Aug 12" — the Meals list's section
    /// headers, matching how ClueClue heads the days in its own meal history.
    ///
    /// The two recent days are named rather than dated because that is how
    /// someone reads a list they are scrolling to find this morning's plate
    /// in; everything older is far enough back that the date is the useful
    /// label.
    static func daySection(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return day(date)
    }

    /// "at meal" for the anchor, otherwise a signed offset: "−15m", "+30m",
    /// "+1h", "+1h20".
    static func offset(_ date: Date, from anchor: Date) -> String {
        let minutes = Int((date.timeIntervalSince(anchor) / 60).rounded())
        if minutes == 0 { return "at meal" }
        let sign = minutes < 0 ? "−" : "+"
        let magnitude = abs(minutes)
        if magnitude < 60 { return "\(sign)\(magnitude)m" }
        let hours = magnitude / 60
        let remainder = magnitude % 60
        return remainder == 0
            ? "\(sign)\(hours)h"
            : "\(sign)\(hours)h\(String(format: "%02d", remainder))"
    }
}

/// A card that dips slightly when pressed, so the chips and the Adjust header
/// feel like controls rather than decoration.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
