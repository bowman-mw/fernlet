import SwiftUI

/// Fernlet's palette for the world shell, in two families.
///
/// The app family is copied from the light values of the shipping tokens in
/// `FernletKit/Sources/FernletUI/FernletUIComponents.swift` and `FernletTheme.swift` (moss, fern,
/// goldenrod, dusty rose, terracotta, slate, bark, parchment, cream), so the companion's state
/// colours match `CompanionState.color` in `ModelColors.swift` exactly. The game family is the warm
/// autumn pixel palette of the status bar, item bar and blue button, from the design page
/// "A World for Fernlet" (version 9). Prototype-only: the shipping app keeps its own tokens.
nonisolated enum FernColors {
    // App family (shipping light values).
    static let parchment = rgb(0xF5EFDF)
    static let cream = rgb(0xFBF7EE)
    static let bark = rgb(0x3D2E1E)
    static let slate = rgb(0x5C6B78)
    static let moss = rgb(0x5E844D)
    static let mossInk = rgb(0x46683A)
    static let fern = rgb(0x72A364)
    static let fernStem = rgb(0x4E7A48)
    static let goldenrod = rgb(0xD2973B)
    static let dustyRose = rgb(0xB67073)
    static let terracotta = rgb(0xB9543D)
    static let sun = rgb(0xEBB551)
    static let rule = Color(.sRGB, red: 0.239, green: 0.180, blue: 0.118, opacity: 0.13)
    static let dim = rgb(0x6B5C4A)

    // Game family (design page).
    static let ink = rgb(0x4A2E1C)
    static let gameCream = rgb(0xFFF1CF)
    static let gameCreamShade = rgb(0xE2C893)
    static let paper = rgb(0xFFF8E4)
    static let wood = rgb(0xC98E54)
    static let woodDark = rgb(0xA86E3C)
    static let woodLight = rgb(0xE0AE74)
    static let woodLabel = rgb(0xFFF1D6)
    static let teal = rgb(0x5FB8C9)
    static let tealDark = rgb(0x24505E)
    static let tealShade = rgb(0x3F95A8)
    static let tealLight = rgb(0x9ADDEA)
    static let speechInk = rgb(0x3A2414)
    static let toast = rgb(0x3D2E1E)
    static let toastAction = rgb(0xC8DBC2)
    static let fog = rgb(0xEFE8DA)
    static let fogEdge = rgb(0xD9CFBC)
    static let trail = rgb(0x3F6B39)
    static let protein = rgb(0xD9532F)
    static let carbs = rgb(0xF2C14E)
    static let fat = rgb(0x5FB8C9)
    static let walkBlue = rgb(0x2C5FA8)

    /// An opaque sRGB colour from a `0xRRGGBB` literal.
    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
