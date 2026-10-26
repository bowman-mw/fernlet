import SwiftUI
import UIKit

/// Fernlet's palette for the world shell, in two families.
///
/// The app family is copied from the light values of the shipping tokens in
/// `FernletKit/Sources/FernletUI/FernletUIComponents.swift` and `FernletTheme.swift` (moss, fern,
/// goldenrod, dusty rose, terracotta, slate, bark, parchment, cream), so the companion's state
/// colours match `CompanionState.color` in `ModelColors.swift` exactly. The game family is the warm
/// autumn pixel palette of the status bar, item bar and blue button, from the design page
/// "A World for Fernlet" (version 9). Prototype-only: the shipping app keeps its own tokens.
///
/// **Text gets no shadow or outline anywhere** (owner, 2026-10-23: the mockup's offset text shadows
/// were hard to read). Every label is one solid colour that clears WCAG AA 4.5:1 against what is
/// directly behind it, and the label colours are ``adaptive(_:increasedContrast:)``: under Increase
/// Contrast they darken to clear 7:1, the target FernletUI's high-contrast palette uses. Measured
/// pairs are noted beside each token.
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
    /// Secondary text on cards: 6.0:1 on cream, 5.6:1 on parchment; 9.8 / 9.2 under Increase Contrast.
    static let dim = adaptive(0x6B5C4A, increasedContrast: 0x4A3D2E)

    // Game family (design page).
    /// Plate borders and text on cream plates: 11.0:1 on the cream plate; 14.9:1 under Increase Contrast.
    static let ink = adaptive(0x4A2E1C, increasedContrast: 0x2A1A10)
    static let gameCream = rgb(0xFFF1CF)
    static let gameCreamShade = rgb(0xE2C893)
    static let paper = rgb(0xFFF8E4)
    /// The item bar and panel title plates. Under Increase Contrast the wood lightens a step so
    /// the label on it clears 7:1.
    static let wood = adaptive(0xC98E54, increasedContrast: 0xD9A066)
    static let woodDark = rgb(0xA86E3C)
    static let woodLight = rgb(0xE0AE74)
    /// The selected item-bar slot: lighter wood, so its label still clears AA (7.3:1; 10.9:1).
    static let woodSelected = adaptive(0xE0AE74, increasedContrast: 0xEBC08A)
    /// Names on the item bar and titles on the wood plates: 5.2:1 on wood; 8.0:1 under Increase Contrast.
    static let woodLabel = adaptive(0x3A2414, increasedContrast: 0x1E120A)
    static let teal = rgb(0x5FB8C9)
    static let tealDark = rgb(0x24505E)
    static let tealShade = rgb(0x3F95A8)
    static let tealLight = rgb(0x9ADDEA)
    /// Text on the teal "go" row of the quick-start card: 6.4:1; 8.0:1 under Increase Contrast.
    static let onTeal = adaptive(0x3A2414, increasedContrast: 0x1E120A)
    /// Speech, quick-start rows and walk-bar text: 14.1:1 on the bubble.
    static let speechInk = adaptive(0x3A2414, increasedContrast: 0x2A1A10)
    /// Small notes on cream plates: 5.6:1; 8.4:1 under Increase Contrast.
    static let noteInk = adaptive(0x7A5A3A, increasedContrast: 0x5E4024)
    /// The walk bar's End button: white on rust, 6.2:1; 7.4:1 under Increase Contrast.
    static let endButton = adaptive(0x9A4A31, increasedContrast: 0x8A3F28)
    static let toast = rgb(0x3D2E1E)
    static let toastAction = rgb(0xC8DBC2)
    static let fog = rgb(0xEFE8DA)
    static let fogEdge = rgb(0xD9CFBC)
    static let trail = rgb(0x3F6B39)
    static let protein = rgb(0xD9532F)
    static let carbs = rgb(0xF2C14E)
    static let fat = rgb(0x5FB8C9)
    /// "Precise location on for this walk": 5.7:1 on cream; 7.9:1 under Increase Contrast.
    static let walkBlue = adaptive(0x2C5FA8, increasedContrast: 0x1F4A85)

    /// An opaque sRGB colour from a `0xRRGGBB` literal.
    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// A colour that follows Increase Contrast, the way FernletUI's tokens do: the trait's
    /// `accessibilityContrast` picks the value. The provider is `@Sendable` because UIKit may
    /// resolve it off the main actor (see FernletUIComponents.swift).
    static func adaptive(_ normal: UInt32, increasedContrast: UInt32) -> Color {
        Color(UIColor { @Sendable trait in
            uiColor(trait.accessibilityContrast == .high ? increasedContrast : normal)
        })
    }

    /// An opaque UIKit colour from a `0xRRGGBB` literal.
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
