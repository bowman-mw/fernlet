import SwiftUI
import UIKit

/// The World Home's colours: the pixel world's palette, ported from the World Shell prototype's
/// `FernColors` (`Prototypes/WorldShell/WorldShell/Art/FernColors.swift`) and the design page
/// "A World for Fernlet" (v9).
///
/// This is the one look behind the theme seam. The owner chose the original pixel world on
/// 2026-10-23; the seam stays as structure, but no other look is built (World app plan,
/// `~/.claude/plans/serene-wibbling-flamingo.md`).
///
/// **Text gets no shadow or outline anywhere** (owner, 2026-10-23). Every label is one solid colour
/// that clears WCAG AA 4.5:1 against what is directly behind it, and the label colours follow
/// Increase Contrast to clear 7:1, the target FernletUI's high-contrast palette uses. Measured pairs
/// are noted beside each token.
nonisolated enum WorldPalette {
    // MARK: The app family (shipping light values)

    static let parchment = rgb(0xF5EFDF)
    static let cream = rgb(0xFBF7EE)
    static let bark = rgb(0x3D2E1E)

    // MARK: The game family (design page)

    /// Plate borders and text on cream plates: 11.0:1 on the cream plate; 14.9:1 under Increase Contrast.
    static let ink = adaptive(0x4A2E1C, increasedContrast: 0x2A1A10)
    static let gameCream = rgb(0xFFF1CF)
    static let gameCreamShade = rgb(0xE2C893)
    /// Small text on cream plates (the offline map note): 14.1:1; higher under Increase Contrast.
    static let speechInk = adaptive(0x3A2414, increasedContrast: 0x2A1A10)

    // MARK: The ground (map layers)

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

    /// A colour that follows Increase Contrast, the way FernletUI's tokens do: the trait's
    /// `accessibilityContrast` picks the value. The provider is `@Sendable` because UIKit may resolve
    /// it off the main actor.
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
