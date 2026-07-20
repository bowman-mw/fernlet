import SwiftUI

#if canImport(UIKit)
import UIKit
import FernletDomainModel

// Everything in this file is resolved from inside `UIColor` dynamic-provider closures, which UIKit
// invokes on whatever thread is resolving the trait collection — including SwiftUI's off-main view-graph
// render thread on device. Under the target's `defaultIsolation(MainActor.self)` these would otherwise be
// MainActor-isolated, and the Swift 6 executor check traps (SIGTRAP) the moment a color resolves off the
// main thread. The computation is pure and thread-safe, so it is explicitly `nonisolated`.
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
nonisolated public struct FernletThemePalette {
    public let background: UIColor
    public let box: UIColor
    public let primaryText: UIColor
    public let secondaryText: UIColor

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

    private static func defaultPalette(background: UIColor, isDarkMode: Bool) -> FernletThemePalette {
        FernletThemePalette(
            background: background,
            box: UIColor(hex: isDarkMode ? FernletThemeDefaults.darkBoxHex : FernletThemeDefaults.lightBoxHex) ?? .systemBackground,
            primaryText: isDarkMode
                ? UIColor(red: 0.945, green: 0.929, blue: 0.890, alpha: 1)
                : UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1),
            secondaryText: isDarkMode
                ? UIColor(red: 0.620, green: 0.655, blue: 0.682, alpha: 1)
                : UIColor(red: 0.482, green: 0.545, blue: 0.600, alpha: 1)
        )
    }

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

    nonisolated convenience init?(hex: String) {
        guard let rgb = UIColor.rgbBytes(fromHex: hex) else { return nil }
        self.init(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
    }

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
    nonisolated var linearizedSRGB: CGFloat {
        self <= 0.03928 ? self / 12.92 : pow((self + 0.055) / 1.055, 2.4)
    }
}
#endif
