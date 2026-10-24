//
//  FernletMessagesLook.swift
//  FernletMessagesExtension
//
//  The iMessage app's panel in the World design language (World Review Batch 4, `b4-msg-*`, owner,
//  2026-10-24): paper framed in ink, the pixel fern mark, Fraunces titles, DM Sans for the rest, and
//  — new with the redesign — Dark Mode. Today's panel was always light.
//

import UIKit

/// The panel's colours and type: the app's framed look (`WorldTheme.framedLook`, its default App
/// colors) spelled out in dynamic `UIColor`s, because this process cannot import the app's palette.
///
/// Every colour follows Dark Mode and Increase Contrast with the same values as the app's
/// `WorldPalette`, so the panel reads as the app does. The person's App colors pick is not read: it
/// lives in the app's own defaults, and the extension reads only the App Group catalog (no new
/// shared field without the wipe walls), so the panel keeps the default Oak and Moss.
///
/// Text is one solid colour everywhere; nothing gets a shadow or an outline (owner, 2026-10-23).
nonisolated enum FernletMessagesLook {

    // MARK: Colours (WorldPalette's values)

    /// The panel's parchment.
    static let page = adaptive(light: 0xF5EFDF, dark: 0x1C1E1B)
    /// A card's or notice's face.
    static let paper = adaptive(light: 0xFFF6E2, dark: 0x3A2E22)
    /// Raised pieces: catalog cards, icon tiles, the search field, the segmented control.
    static let raised = adaptive(light: 0xFFFBF0, dark: 0x45372A)
    /// Every frame.
    static let ink = adaptive(light: 0x4A2E1C, dark: 0x120A04)
    /// Titles and text on paper.
    static let text = adaptive(light: 0x3A2414, dark: 0xFFF1CF, lightHC: 0x2A1808, darkHC: 0xFFF8E4)
    /// Secondary text on paper.
    static let dim = adaptive(light: 0x6B5C4A, dark: 0xC9BFAE, lightHC: 0x4E4030, darkHC: 0xE2D8C6)
    /// Moss as text: the brand name, the preview line, Browse.
    static let link = adaptive(light: 0x46683A, dark: 0x9BCB84)
    /// Primary buttons, the chosen segment and the picked card's check (the Moss accent).
    static let accent = adaptive(light: 0x46683A, dark: 0x8DBB78)
    /// Text and icons on ``accent``.
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x10170D)
    /// The ring around the picked card (the design's moss).
    static let ring = adaptive(light: 0x5E844D, dark: 0x7FB069)
    /// One-colour pixel icons: ink on light paper, cream on dark.
    static let iconInk = adaptive(light: 0x4A2E1C, dark: 0xFFF1CF, darkHC: 0xFFF8E4)
    /// The solid drop shadow under a card (ink at 22 %).
    static let shadow = UIColor { @Sendable trait in ink.resolvedColor(with: trait).withAlphaComponent(0.22) }
    /// The deeper shadow under a button (ink at 30 %).
    static let buttonShadow = UIColor { @Sendable trait in ink.resolvedColor(with: trait).withAlphaComponent(0.3) }

    // MARK: Shape

    /// A card's corner radius.
    static let cardRadius: CGFloat = 12
    /// A button's, field's or segmented control's corner radius.
    static let controlRadius: CGFloat = 10
    /// A frame's width.
    static let frameWidth: CGFloat = 2

    // MARK: Type (the app's FernletFramedFont sizes, scaled with Dynamic Type)

    /// The panel's title: Fraunces 22.
    static var title: UIFont { font(FernletMessagesFontName.fraunces, size: 22, style: .title2, fallback: .semibold) }
    /// The brand name beside the fern: DM Sans bold 13.
    static var brand: UIFont { font(FernletMessagesFontName.dmSansMedium, size: 13, style: .caption1, fallback: .bold) }
    /// The status line and the notice: DM Sans 15.
    static var body: UIFont { font(FernletMessagesFontName.dmSans, size: 15, style: .subheadline, fallback: .regular) }
    /// The preview line: DM Sans bold 14.
    static var preview: UIFont { font(FernletMessagesFontName.dmSansMedium, size: 14, style: .subheadline, fallback: .semibold) }
    /// A catalog card's title: DM Sans bold 15.
    static var cardTitle: UIFont { font(FernletMessagesFontName.dmSansMedium, size: 15, style: .subheadline, fallback: .bold) }
    /// A catalog card's counts: DM Sans 12.5.
    static var cardDetail: UIFont { font(FernletMessagesFontName.dmSans, size: 12.5, style: .caption1, fallback: .regular) }
    /// A button: DM Sans bold 16.
    static var button: UIFont { font(FernletMessagesFontName.dmSansMedium, size: 16, style: .body, fallback: .bold) }
    /// A quiet text button (Browse your recipes): DM Sans bold 15.
    static var textButton: UIFont { font(FernletMessagesFontName.dmSansMedium, size: 15, style: .subheadline, fallback: .semibold) }
    /// A segment: DM Sans semibold 14.5.
    static var segment: UIFont { font(FernletMessagesFontName.dmSansMedium, size: 14.5, style: .subheadline, fallback: .semibold) }
    /// The search field: DM Sans 16.
    static var field: UIFont { font(FernletMessagesFontName.dmSans, size: 16, style: .body, fallback: .regular) }

    /// `name` at `size`, scaled for Dynamic Type like `style`; the system face at `fallback` weight
    /// if the bundled font is missing.
    static func font(_ name: String, size: CGFloat, style: UIFont.TextStyle, fallback: UIFont.Weight) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: fallback)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
    }

    /// A colour that follows Dark Mode and Increase Contrast, as `WorldPalette.adaptive` does.
    static func adaptive(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> UIColor {
        UIColor { @Sendable trait in
            let high = trait.accessibilityContrast == .high
            if trait.userInterfaceStyle == .dark { return FernletMessagesPalette.rgb(high ? darkHC ?? dark : dark) }
            return FernletMessagesPalette.rgb(high ? lightHC ?? light : light)
        }
    }
}
