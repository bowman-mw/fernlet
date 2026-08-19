import SwiftUI

#if canImport(UIKit)
import UIKit
import FernletDomainModel

// Everything in this file is resolved from inside `UIColor` dynamic-provider closures, which UIKit
// invokes on whatever thread is resolving the trait collection — including SwiftUI's off-main view-graph
// render thread on device. Under the target's `defaultIsolation(MainActor.self)` these would otherwise be
// MainActor-isolated, and the Swift 6 executor check traps (SIGTRAP) the moment a color resolves off the
// main thread. The computation is pure and thread-safe, so it is explicitly `nonisolated`.

/// Canonical hex strings and `UserDefaults` keys for the app's light/dark background theme.
///
/// A caseless namespace enum shared by ``FernletThemePalette`` (which reads the custom-background
/// keys during color resolution) and the app's appearance settings (which write them). Explicitly
/// `nonisolated` so its statics are readable from the `@Sendable` `UIColor` dynamic-provider
/// closures described in the note above.
nonisolated public enum FernletThemeDefaults {
    public static let lightBackgroundHex = "#F5EFDF"
    public static let darkBackgroundHex = "#1C1E1B"
    public static let lightBoxHex = "#FBF7EE"
    public static let darkBoxHex = "#282A26"
    public static let customLightBackgroundKey = "fernletCustomLightBackgroundHex"
    public static let customDarkBackgroundKey = "fernletCustomDarkBackgroundHex"
}

// `nonisolated` on the type, not just on `current(_:)`: a provider closure reads the returned
// `primaryText`/`background`/… too, and those stored properties would otherwise stay MainActor-isolated and
// be rejected from the `@Sendable` closures that call them.

/// The resolved four-color surface palette — background, box, primary ink, secondary ink — for one
/// interface style.
///
/// This is the engine behind the adaptive `Color.parchment` / `.cream` / `.bark` / `.slate` tokens
/// in `FernletUIComponents.swift`: each of those tokens calls ``current(for:)`` from inside a
/// `UIColor` dynamic-provider closure every time UIKit resolves a trait collection. Resolution
/// honors a user-chosen custom background hex stored under the ``FernletThemeDefaults`` keys in
/// `UserDefaults.standard`; a non-default background derives a matching box surface via HSB
/// adjustment and picks light-or-dark ink by relative luminance (dark surfaces below 0.46), so any
/// custom background stays legible.
///
/// Concurrency: the whole type is `nonisolated` (see the note above) because provider closures run
/// on whatever thread resolves the traits — including SwiftUI's off-main render thread on device —
/// and the computation is pure and thread-safe. Failure mode: an unparseable stored hex falls back
/// to the built-in default hex, then to `.systemBackground`.
nonisolated public struct FernletThemePalette {
    /// The screen background color (parchment/midnight by default; user-customizable).
    public let background: UIColor
    /// The raised card/box surface color, derived one step off the background.
    public let box: UIColor
    /// The primary ink color — "bark" in the token vocabulary.
    public let primaryText: UIColor
    /// The secondary, muted ink color — "slate" in the token vocabulary.
    public let secondaryText: UIColor

    /// Resolves the palette for an interface style, honoring any custom background in
    /// `UserDefaults.standard`.
    ///
    /// - Parameter interfaceStyle: The trait collection's current style; `.dark` selects the dark
    ///   defaults and the dark custom-background key.
    /// - Returns: A fully derived palette; never fails (malformed stored hex falls back to defaults).
    public static func current(for interfaceStyle: UIUserInterfaceStyle) -> FernletThemePalette {
        let isDarkMode = interfaceStyle == .dark
        let key = isDarkMode ? FernletThemeDefaults.customDarkBackgroundKey : FernletThemeDefaults.customLightBackgroundKey
        let defaultHex = isDarkMode ? FernletThemeDefaults.darkBackgroundHex : FernletThemeDefaults.lightBackgroundHex
        let selectedHex = UserDefaults.standard.string(forKey: key) ?? defaultHex
        let background = UIColor(hex: selectedHex) ?? UIColor(hex: defaultHex) ?? .systemBackground

        let isDefault = selectedHex.caseInsensitiveCompare(defaultHex) == .orderedSame
        if isDefault {
            return defaultPalette(background: background, isDarkMode: isDarkMode)
        }

        let usesDarkSurfaces = background.relativeLuminance < 0.46
        return FernletThemePalette(
            background: background,
            box: boxColor(from: background, usesDarkSurfaces: usesDarkSurfaces),
            primaryText: usesDarkSurfaces
                ? UIColor(red: 0.945, green: 0.929, blue: 0.890, alpha: 1)
                : UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1),
            secondaryText: usesDarkSurfaces
                ? UIColor(red: 0.730, green: 0.748, blue: 0.760, alpha: 1)
                : UIColor(red: 0.380, green: 0.430, blue: 0.470, alpha: 1)
        )
    }

    /// The stock light/dark palette used when the stored background equals the built-in default.
    ///
    /// The light `secondaryText` ("slate") is deliberately darker than it looks like it should be:
    /// it inks every 12pt section eyebrow, subtitle and sheet Cancel in the app, and the previous
    /// value measured 3.05:1 on parchment — under the 4.5:1 floor for small text. It now clears
    /// 4.8:1 on parchment and 5.1:1 on cream. Dark mode was already fine (5.9–6.9:1) and is unchanged.
    private static func defaultPalette(background: UIColor, isDarkMode: Bool) -> FernletThemePalette {
        FernletThemePalette(
            background: background,
            box: UIColor(hex: isDarkMode ? FernletThemeDefaults.darkBoxHex : FernletThemeDefaults.lightBoxHex) ?? .systemBackground,
            primaryText: isDarkMode
                ? UIColor(red: 0.945, green: 0.929, blue: 0.890, alpha: 1)
                : UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1),
            secondaryText: isDarkMode
                ? UIColor(red: 0.620, green: 0.655, blue: 0.682, alpha: 1)
                : UIColor(red: 0.360, green: 0.420, blue: 0.470, alpha: 1)
        )
    }

    /// Derives the card/box surface from a custom background by clamping its saturation and pinning
    /// brightness (0.17 dark / 0.97 light); falls back to fixed neutrals when the background has no
    /// HSB representation.
    private static func boxColor(from background: UIColor, usesDarkSurfaces: Bool) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        guard background.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return usesDarkSurfaces ? UIColor(white: 0.157, alpha: 1) : UIColor(red: 0.984, green: 0.969, blue: 0.933, alpha: 1)
        }

        let adjustedBrightness: CGFloat = usesDarkSurfaces ? 0.17 : 0.97
        let adjustedSaturation = usesDarkSurfaces
            ? min(max(saturation * 0.70, 0.05), 0.22)
            : min(max(saturation * 0.24, 0.03), 0.10)
        return UIColor(hue: hue, saturation: adjustedSaturation, brightness: adjustedBrightness, alpha: alpha)
    }
}

public extension UIColor {
    /// WCAG relative luminance (0 = black, 1 = white) of the color's sRGB components.
    ///
    /// Used by ``FernletThemePalette`` to decide whether a custom background needs light or dark
    /// ink. Returns 1 (treated as light) when the color has no RGB representation.
    nonisolated var relativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 1 }
        return 0.2126 * red.linearizedSRGB + 0.7152 * green.linearizedSRGB + 0.0722 * blue.linearizedSRGB
    }

    /// Parses a 6-hex `RRGGBB` string (any surrounding non-alphanumerics, e.g. a leading `#`, are
    /// trimmed) into its 0–255 channel bytes. Returns `nil` for any malformed input. The single source
    /// of truth for hex→RGB used by both `UIColor(hex:)` and the item-texture pixel renderer.
    nonisolated static func rgbBytes(fromHex hex: String) -> (UInt8, UInt8, UInt8)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    /// Creates an opaque color from a 6-hex `RRGGBB` string via `rgbBytes(fromHex:)`; fails on
    /// malformed input.
    nonisolated convenience init?(hex: String) {
        guard let rgb = UIColor.rgbBytes(fromHex: hex) else { return nil }
        self.init(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

    /// The color re-encoded as an uppercase `#RRGGBB` string (channels truncated to 0–255), or
    /// `nil` when the color has no RGB representation. The inverse of `init(hex:)`, used when
    /// persisting a custom theme background.
    nonisolated var hexString: String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }
}

private extension CGFloat {
    /// The sRGB-to-linear transfer function used by the WCAG relative-luminance formula.
    nonisolated var linearizedSRGB: CGFloat {
        self <= 0.03928 ? self / 12.92 : pow((self + 0.055) / 1.055, 2.4)
    }
}
#endif
