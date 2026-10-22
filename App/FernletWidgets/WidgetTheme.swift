// WidgetTheme.swift
// FernletWidgets
//
// The Home Screen widgets' light and dark colours, fonts and the care bar (design round 2,
// 2026-10-21). The Live Activities keep `FernletWidgetPalette`; these are the companion and water
// widgets' own.

import SwiftUI
import WidgetKit

/// The companion and water widgets' colours for one appearance.
///
/// Muted text measures 6.2:1 on the light card and 8.7:1 on the dark one, and the outline colour
/// 3.7:1 / 4.8:1 — every pairing clears its WCAG floor (4.5:1 text, 3:1 graphics).
struct WidgetTheme {
    /// The card behind most widgets.
    let card: Color
    /// The slightly deeper card behind the thought widget, so its bubble reads as lifted.
    let cardAlt: Color
    /// Primary text.
    let ink: Color
    /// Secondary text: labels, the companion's name.
    let muted: Color
    /// Outlines: the care bar's empty segments, the water bottle.
    let line: Color
    /// The quiet fill behind a chip or a bubble's edge.
    let chip: Color
    /// The "+" button.
    let accent: Color
    /// The "+" on the button.
    let accentInk: Color

    /// Parchment and bark.
    static let light = WidgetTheme(card: Color(token: "#FBF7EE"), cardAlt: Color(token: "#F5EFE0"),
                                   ink: Color(token: "#3D2E1E"), muted: Color(token: "#6B5A47"),
                                   line: Color(token: "#8C7D69"), chip: Color(token: "#F5EFE0"),
                                   accent: Color(token: "#5A7A52"), accentInk: Color(token: "#FBF7EE"))

    /// Warm night browns.
    static let dark = WidgetTheme(card: Color(token: "#2A2219"), cardAlt: Color(token: "#231C15"),
                                  ink: Color(token: "#F5EFE0"), muted: Color(token: "#CDBFA8"),
                                  line: Color(token: "#9C8C76"), chip: Color(token: "#3A3026"),
                                  accent: Color(token: "#8AAD7E"), accentInk: Color(token: "#1A140E"))

    /// The theme for the widget's colour scheme.
    static func current(_ scheme: ColorScheme) -> WidgetTheme {
        scheme == .dark ? dark : light
    }
}

private extension Color {
    /// A literal design-token hex. Every caller passes a well-formed constant, so the bark fallback
    /// is unreachable in practice; it keeps the init non-failable without a trap (R5).
    init(token hex: String) {
        self = Color(widgetHex: hex) ?? Color(red: 0.239, green: 0.180, blue: 0.118)
    }
}

/// The app's bundled faces, by PostScript name — the twins of `FernletFontName` in FernletUI. The
/// files are copied into this extension (an extension cannot read the app's fonts) and registered by
/// its Info.plist `UIAppFonts`. A missing font falls back to the system face, never a blank.
enum WidgetFont {
    /// Fraunces SemiBold: the state word and the water count.
    static func display(_ size: CGFloat) -> Font {
        .custom("Fraunces-72ptSemiBoldNonWonky", size: size, relativeTo: .title3)
    }

    /// DM Sans: labels and the companion's name.
    static func label(_ size: CGFloat) -> Font {
        .custom("DMSans-14ptMedium", size: size, relativeTo: .caption)
    }

    /// DM Sans regular: the line under a number.
    static func body(_ size: CGFloat) -> Font {
        .custom("DMSans-14pt", size: size, relativeTo: .caption)
    }

    /// Instrument Serif italic: the companion's voice.
    static func thought(_ size: CGFloat) -> Font {
        .custom("InstrumentSerif-Italic", size: size, relativeTo: .body)
    }
}

/// The twelve-segment care bar, as on Home: the day's care score in the state's colour, empty
/// segments outlined. No number is drawn; VoiceOver hears the percentage, as on Home.
struct WidgetCareBar: View {
    /// The 0–1 care score.
    let score: Double
    /// The filled segments' colour.
    let fill: Color
    /// The empty segments' outline.
    let line: Color
    var height: CGFloat = 8

    /// Twelve segments, like the app's `HealthBar`.
    static let segments = 12

    private var filled: Int {
        guard score.isFinite else { return 0 }
        return Int((min(max(score, 0), 1) * Double(Self.segments)).rounded())
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.segments, id: \.self) { index in
                segment(isFilled: index < filled)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Care score"))
        .accessibilityValue(Text("\(Int((min(max(score, 0), 1) * 100).rounded())) percent"))
    }

    @ViewBuilder
    private func segment(isFilled: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        if isFilled {
            shape.fill(fill).widgetAccentable()
        } else {
            shape.strokeBorder(line, lineWidth: 1.5)
        }
    }
}
