import SwiftUI

// MARK: - Fernlet Design System (2026-07-08 redesign foundation)
//
// Canonical tokens + type roles from the Claude-design export (`_ds/colors_and_type.css`): the
// two-system serif/sans type scale, the warm token palette (adds lichen, midnight, and the state +
// journal palettes), the 8pt spacing grid, corner radii, warm bark-tinted shadow, and motion tokens.
//
// The bundled fonts (Fraunces / DM Serif Display / Instrument Serif / DM Sans / Playfair Display)
// live in `Fernlet/Fonts`, are registered via Info.plist `UIAppFonts`, and are referenced here by
// their exact PostScript names. `FernletFontRegistrationTests` asserts every name resolves so a
// wrong filename or PostScript name fails the build's test run rather than silently falling back
// to the system font.

// MARK: - Type roles

/// The two-system type scale: **serif = the companion's world**, **sans = the interface layer**.
/// Sizes mirror the design-system `--text-*` tokens; each role scales with Dynamic Type via the
/// `relativeTo:` text style.
enum FernletTextRole {
    case wordmark        // Playfair Display Italic — app logo only
    case display         // Fraunces SemiBold 36 — avatar state / hero
    case displayMedium   // Fraunces SemiBold 28 — section display
    case header          // DM Serif Display 24 — section headers
    case headerMedium    // DM Serif Display 20 — sub-headers
    case body            // Instrument Serif 17 — body / primary UI
    case bodySmall       // Instrument Serif 15 — compact body
    case bubble          // Instrument Serif Italic 14 — thought bubbles
    case label           // DM Sans Medium 14 — labels / buttons / toggles
    case labelSmall      // DM Sans 12 — secondary labels
    case stat            // DM Sans Medium 14 tabular — numbers / stats
}

extension Font {
    /// Resolve a design-system type role to a bundled font at its canonical size, scaling with
    /// Dynamic Type relative to the nearest system text style.
    static func fernlet(_ role: FernletTextRole) -> Font {
        switch role {
        case .wordmark:      return .custom(FernletFontName.playfairItalic, size: 34, relativeTo: .largeTitle)
        case .display:       return .custom(FernletFontName.frauncesSemiBold, size: 36, relativeTo: .largeTitle)
        case .displayMedium: return .custom(FernletFontName.frauncesSemiBold, size: 28, relativeTo: .title)
        case .header:        return .custom(FernletFontName.dmSerifDisplay, size: 24, relativeTo: .title2)
        case .headerMedium:  return .custom(FernletFontName.dmSerifDisplay, size: 20, relativeTo: .title3)
        case .body:          return .custom(FernletFontName.instrumentSerif, size: 17, relativeTo: .body)
        case .bodySmall:     return .custom(FernletFontName.instrumentSerif, size: 15, relativeTo: .callout)
        case .bubble:        return .custom(FernletFontName.instrumentSerifItalic, size: 14, relativeTo: .footnote)
        case .label:         return .custom(FernletFontName.dmSansMedium, size: 14, relativeTo: .subheadline)
        case .labelSmall:    return .custom(FernletFontName.dmSans, size: 12, relativeTo: .caption)
        case .stat:          return .custom(FernletFontName.dmSansMedium, size: 14, relativeTo: .subheadline).monospacedDigit()
        }
    }
}

/// Exact PostScript names of the bundled fonts (see `Fernlet/Fonts` + Info.plist `UIAppFonts`).
/// These are the instanced static weights — do not guess; they are verified by a test.
enum FernletFontName {
    static let playfairItalic        = "PlayfairDisplayItalic-Italic"
    static let frauncesSemiBold      = "Fraunces-72ptSemiBoldNonWonky"
    static let dmSerifDisplay        = "DMSerifDisplay-Regular"
    static let dmSerifDisplayItalic  = "DMSerifDisplay-Italic"
    static let instrumentSerif       = "InstrumentSerif-Regular"
    static let instrumentSerifItalic = "InstrumentSerif-Italic"
    static let dmSans                = "DMSans-14pt"
    static let dmSansMedium          = "DMSans-14ptMedium"

    /// Every bundled PostScript name — consumed by the registration self-check test.
    static let all = [
        playfairItalic, frauncesSemiBold, dmSerifDisplay, dmSerifDisplayItalic,
        instrumentSerif, instrumentSerifItalic, dmSans, dmSansMedium,
    ]
}

// MARK: - Color tokens

extension Color {
    // New tokens added by the redesign. (parchment / cream / bark / slate / moss / fern / goldenrod /
    // terracotta already live in FernletUIComponents; these extend the palette.) Each is built through
    // the app's single `UIColor(hex:)` parser so there is one hex source of truth.
    static let lichen   = dsColor("#C8DBC2")   // muted fills, tinted backgrounds
    static let midnight = dsColor("#1A1F2E")   // dark-mode background

    /// Fixed dark-brown for warm shadows (non-adaptive, unlike `bark`).
    static let barkShadow = dsColor("#3D2E1E")

    // Avatar wellness states
    static let stateThriving = dsColor("#5A7A52")
    static let stateOkay     = dsColor("#C9964A")
    static let stateTired    = dsColor("#8B7B9E")
    static let stateFainted  = dsColor("#9BA8B4")
    static let stateSick     = dsColor("#C0674A")

    // Journal tag palette
    static let journalBright  = dsColor("#EDD87A")
    static let journalGood    = dsColor("#A8C89C")
    static let journalNeutral = dsColor("#B8B0A4")
    static let journalQuiet   = dsColor("#94AEBF")
    static let journalTired   = dsColor("#A08898")
    static let journalHard    = dsColor("#C88070")

    /// Build a fixed design-system color from a hex literal via the app's shared `UIColor(hex:)`.
    private static func dsColor(_ hex: String) -> Color { Color(UIColor(hex: hex) ?? .clear) }
}

// MARK: - Metrics (8pt grid + corner radii)

enum FernletMetrics {
    // Spacing — 8pt base grid
    static let spaceXs: CGFloat = 4
    static let spaceSm: CGFloat = 8
    static let spaceMd: CGFloat = 16
    static let spaceLg: CGFloat = 24
    static let spaceXl: CGFloat = 40
    static let spaceXxl: CGFloat = 64

    // Corner radii
    static let radiusSm: CGFloat = 10   // chips, tags
    static let radiusMd: CGFloat = 18   // cards, modals
    static let radiusLg: CGFloat = 28   // bottom sheets, floating panels
    static let radiusXl: CGFloat = 40   // full-bleed cards, avatar container
}

// MARK: - Shadow (warm bark-tinted, never cold gray)

extension View {
    /// Warm card shadow — the design-system `--shadow-card` (0 2px 8px + 0 6px 24px, bark-tinted).
    func fernletCardShadow() -> some View {
        self
            .shadow(color: Color.barkShadow.opacity(0.08), radius: 4, x: 0, y: 2)
            .shadow(color: Color.barkShadow.opacity(0.05), radius: 12, x: 0, y: 6)
    }

    /// Softer single-layer shadow — `--shadow-sm`.
    func fernletSmallShadow() -> some View {
        shadow(color: Color.barkShadow.opacity(0.10), radius: 2, x: 0, y: 1)
    }
}

// MARK: - Motion tokens

enum FernletMotion {
    static let ui     = Animation.easeOut(duration: 0.25)   // UI transitions
    static let avatar = Animation.spring(response: 0.4, dampingFraction: 0.7)   // avatar reactions
    static let load   = Animation.easeOut(duration: 0.7)    // loading transitions
    static let fast   = Animation.easeOut(duration: 0.15)   // quick feedback
    /// Gentle overshoot spring matching `--ease-spring` (celebration bounce).
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.62)
}
