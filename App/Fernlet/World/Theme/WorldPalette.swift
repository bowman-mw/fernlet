import SwiftUI
import UIKit

/// The World Home's colours in the approved design language (`b1-language`, World Review Batch 1, draft
/// 3; owner, 2026-10-23): wood for navigation only, paper framed in ink for every container, parchment
/// with a faint dot grid for pages, and one set of data colours.
///
/// Every token follows Dark Mode and Increase Contrast with the design page's own values (its `.dk` and
/// `.hc` phone tokens), through a dynamic `UIColor` as FernletUI's palette does. This is the one look
/// behind the theme seam; no other look is built.
///
/// **Text gets no shadow or outline anywhere** (owner, 2026-10-23); every label is one solid colour.
nonisolated enum WorldPalette {
    // MARK: Materials

    /// Frames and outlines.
    static let ink = adaptive(light: 0x4A2E1C, dark: 0x120A04)
    /// Text on wood and on paper: 5.2:1 on wood, 11:1 on paper; darker under Increase Contrast.
    static let bark = adaptive(light: 0x3A2414, dark: 0xFFF1CF, lightHC: 0x2A1808, darkHC: 0xFFF8E4)
    /// Every container's face (the status plate, cards, chips, fields, buttons).
    static let paper = adaptive(light: 0xFFF6E2, dark: 0x3A2E22)
    /// A lighter paper for buttons and fields on paper.
    static let paperLight = adaptive(light: 0xFFFBF0, dark: 0x45372A)
    /// The shade under a container's bottom edge.
    static let paperShade = adaptive(light: 0xEFDDB8, dark: 0x2A2017)
    /// Navigation only: the item bar and title plates, in the wood App colors chose (``WorldAppColors``;
    /// Oak, today's wood, by default). Read where it is drawn, so a pick shows on the next draw; a view
    /// that stays on screen also reads ``EnvironmentValues/worldAppColors`` to be redrawn by it.
    static var wood: Color { WorldAppColors.wood().tones.wood }
    static var woodHigh: Color { WorldAppColors.wood().tones.high }
    static var woodLow: Color { WorldAppColors.wood().tones.low }
    /// The item bar's selected slot: lighter wood, so its label still clears AA.
    static var woodSelected: Color { WorldAppColors.wood().tones.selected }
    /// Text and one-colour icons on wood: ``bark``, or cream on Walnut.
    static var onWood: Color { WorldAppColors.wood().tones.label }
    /// Pages: parchment.
    static let page = adaptive(light: 0xF5EFDF, dark: 0x1C1E1B)
    /// The page's faint dot grid.
    static let pageDot = Color(UIColor { @Sendable trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 241 / 255, blue: 207 / 255, alpha: 0.05)
            : UIColor(red: 74 / 255, green: 46 / 255, blue: 28 / 255, alpha: 0.07)
    })
    /// Secondary text on paper.
    static let dim = adaptive(light: 0x6B5C4A, dark: 0xC9BFAE, lightHC: 0x4E4030, darkHC: 0xE2D8C6)
    /// The moss of section squares and switches.
    static let moss = adaptive(light: 0x5E844D, dark: 0x7FB069)
    /// Primary buttons and selected chips, in the accent App colors chose (``WorldAppColors``; the
    /// design's moss ink by default).
    static var accent: Color { WorldAppColors.accent().tones.accent }
    /// Text on ``accent``.
    static var onAccent: Color { WorldAppColors.accent().tones.onAccent }
    /// Moss as text: links and quiet buttons on paper ("Arrange Today").
    static let mossInk = adaptive(light: 0x46683A, dark: 0x9BCB84)
    /// The calm card's paper (First aid).
    static let sage = adaptive(light: 0xE6ECD2, dark: 0x2F3829)
    /// The gentle-day row's paper ("I'm unwell today").
    static let rose = adaptive(light: 0xF6E1DA, dark: 0x46302A)
    /// A warning notice's paper (`.notice3.warn`, World Review Batch 3).
    static let warn = adaptive(light: 0xF6DCD3, dark: 0x4A2A22)
    /// One-colour pixel icons (✕, chevrons, the back arrow, plus, search): ink on light paper, the cream
    /// text ink on dark paper (World Review Batch 2 draft 2: drawn in fixed ink they vanished in dark mode).
    static let iconInk = adaptive(light: 0x4A2E1C, dark: 0xFFF1CF, darkHC: 0xFFF8E4)
    /// The dotted rule between rows: ink at a quarter on light paper, cream at a sixth on dark.
    static let rule = Color(UIColor { @Sendable trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 241 / 255, blue: 207 / 255, alpha: 0.16)
            : UIColor(red: 74 / 255, green: 46 / 255, blue: 28 / 255, alpha: 0.25)
    })

    // MARK: Data colours (one set everywhere)

    static let protein = rgb(0x5E844D)
    static let carbs = rgb(0xD2973B)
    static let fat = rgb(0xB8543D)
    /// An empty macro bar.
    static let barEmpty = adaptive(light: 0xF3E2BD, dark: 0x2A2017)

    // MARK: The ground (map layers)

    static let gameCream = rgb(0xFFF1CF)
    static let fog = rgb(0xEFE8DA)
    static let fogShade = rgb(0xE6DDC8)
    static let fogEdge = rgb(0xD9CFBC)
    static let nightFog = rgb(0x353A4E)
    static let nightFogShade = rgb(0x30354A)
    static let trail = rgb(0x3F6B39)
    static let nightTrail = rgb(0x8DBB78)
    static let plainGround = rgb(0xEDE6D3)
    static let nightPlainGround = rgb(0x2E2A24)

    /// An opaque sRGB colour from a `0xRRGGBB` literal.
    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A colour that follows Dark Mode and Increase Contrast, the way FernletUI's tokens do. The
    /// provider is `@Sendable` because UIKit may resolve it off the main actor.
    static func adaptive(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> Color {
        Color(UIColor { @Sendable trait in
            let high = trait.accessibilityContrast == .high
            if trait.userInterfaceStyle == .dark { return uiColor(high ? darkHC ?? dark : dark) }
            return uiColor(high ? lightHC ?? light : light)
        })
    }

    /// An opaque UIKit colour from a `0xRRGGBB` literal.
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
