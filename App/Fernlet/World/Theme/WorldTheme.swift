import FernletUI
import SwiftUI

/// The theme seam: the World Home's sprites, faces and sizes in one value, read from the environment
/// by every World view (World app plan; owner, 2026-10-23).
///
/// There is one theme, ``pixel``: the original pixel world in the approved design language. The seam
/// stays as structure, so a later look is a second value of this type rather than an edit to every
/// view, but no other look is built without the owner's say-so.
nonisolated struct WorldTheme: Sendable {
    /// Points per sprite pixel at standard text sizes, and at accessibility text sizes (whole steps
    /// keep the art crisp; the design page steps from 3 to 4).
    let spriteScale: CGFloat
    let spriteScaleAccessibility: CGFloat
    /// The icon each panel and item-bar slot shows.
    let icons: [WorldPanel: WorldSprite]

    /// The approved pixel world.
    static let pixel = WorldTheme(
        spriteScale: 3, spriteScaleAccessibility: 4,
        icons: [.today: WorldSprites.heartSm, .food: WorldSprites.onigiri, .move: WorldSprites.shoe,
                .log: WorldSprites.basket, .friends: WorldSprites.photo, .personal: WorldSprites.diary,
                .settings: WorldSprites.gear])

    /// The sprite scale for a text size.
    func scale(accessibilitySize: Bool) -> CGFloat {
        accessibilitySize ? spriteScaleAccessibility : spriteScale
    }

    /// A panel's icon.
    func icon(for panel: WorldPanel) -> WorldSprite {
        icons[panel] ?? WorldSprites.leaf
    }
}

/// The World's two typefaces (design language: Fraunces for titles, DM Sans for everything else), each
/// scaling with Dynamic Type through `relativeTo:`.
nonisolated enum WorldType {
    /// A panel's title on its wooden plate (25 pt Fraunces).
    static let plateTitle = Font.custom(FernletFontName.frauncesSemiBold, size: 25, relativeTo: .title2)
    /// An item-bar name (12.5 pt DM Sans, bold).
    static let barLabel = Font.custom(FernletFontName.dmSansBold, size: 12.5, relativeTo: .caption)
    /// The status plate's macro letters (13 pt DM Sans, bold).
    static let plateLabel = Font.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .caption)
    /// The status plate's water count: 16 pt, or 22 pt at accessibility sizes, as the approved
    /// largest-text design draws it.
    static func plateCount(large: Bool) -> Font {
        Font.custom(FernletFontName.dmSansBold, size: large ? 22 : 16, relativeTo: .caption)
    }

    /// The companion's speech bubble (14 pt DM Sans).
    static let speech = Font.custom(FernletFontName.dmSans, size: 14, relativeTo: .subheadline)
    /// A banner's title (16 pt DM Sans, bold) and its line under it (13.5 pt).
    static let bannerTitle = Font.custom(FernletFontName.dmSansBold, size: 16, relativeTo: .headline)
    static let bannerDetail = Font.custom(FernletFontName.dmSans, size: 13.5, relativeTo: .subheadline)

    /// The largest the status plate's letters grow: the plate sits on the map, so its text follows the
    /// approved design's fixed steps rather than growing without bound.
    static let plateTextCap = DynamicTypeSize.xLarge

    /// The largest a panel's plate title grows: 25 pt Fraunces reaches the approved largest-text 31 pt
    /// at this size (`.ph.ax .pt h4`), and stops there.
    static let plateTitleCap = DynamicTypeSize.xxxLarge
}

extension WorldTheme {
    /// The design language for everything in the World build (``FernletFramedLook``, `b1-language`):
    /// paper in a 2-pt ink frame with a solid shadow, dotted parchment pages, wood for the sheet's
    /// grabber, in this theme's palette and the stored App colors choice. Set at the root by
    /// `worldDesignLanguage()`, which passes the choice it observes (``framedLook(for:)``).
    @MainActor static var framedLook: FernletFramedLook {
        framedLook(for: WorldAppColors.current())
    }

    /// The framed look in an App colors choice (`b2-colors`): its wood on the grabbers, its accent on
    /// primary buttons, selected chips and switches.
    @MainActor static func framedLook(for colors: WorldAppColorChoice) -> FernletFramedLook {
        let wood = colors.wood.tones
        let accent = colors.accent.tones
        return FernletFramedLook(paper: WorldPalette.paper, paperLow: WorldPalette.paperShade, raised: WorldPalette.paperLight,
                                 ink: WorldPalette.ink, text: WorldPalette.bark, shadow: WorldPalette.ink.opacity(0.22),
                                 sage: WorldPalette.sage, rose: WorldPalette.rose, mark: accent.mark,
                                 accent: accent.accent, onAccent: accent.onAccent, dim: WorldPalette.dim,
                                 page: WorldPalette.page, pageDot: WorldPalette.pageDot, rule: WorldPalette.rule,
                                 link: WorldPalette.mossInk, wood: wood.wood, woodHigh: wood.high,
                                 warn: WorldPalette.warn)
    }

    /// Draws the framed primitives' icons as this theme's pixel sprites, through ``WorldSpriteView`` (the
    /// one place World pixel icons are drawn, so one-colour icons take the ink token in dark mode).
    static let iconRenderer = FernletIconRenderer { icon, scale, tint in
        AnyView(WorldSpriteView(sprite: WorldSprites.sprite(for: icon), scale: scale, tint: tint))
    }
}

extension WorldSprites {
    /// The pixel sprite for one of FernletUI's framed icons.
    static func sprite(for icon: FernletFramedIcon) -> WorldSprite {
        switch icon {
        case .close: xx
        case .back: chevL
        case .chevron: chevR
        case .chevronDown: chevD
        case .plus: plus
        case .check: check
        case .search: search
        case .lock: lock
        }
    }
}

extension View {
    /// The one design language (`b1-language`) for everything below: framed cards, chips, buttons,
    /// switches, fields, Forms (``FernletFormStyle``) and sheets in this theme's palette
    /// (``WorldTheme/framedLook``), with its pixel icons (``WorldTheme/iconRenderer``), in the App
    /// colors the person chose (``WorldAppColorsSource``, outermost, so the look below reads it).
    func worldDesignLanguage() -> some View {
        modifier(WorldDesignLanguage())
            .modifier(WorldAppColorsSource())
    }
}

/// Implements `worldDesignLanguage()`: the framed look in the App colors choice handed down by
/// ``WorldAppColorsSource``, the pixel icons, and the framed switch and Form styles.
struct WorldDesignLanguage: ViewModifier {
    @Environment(\.worldAppColors) private var appColors

    func body(content: Content) -> some View {
        content
            .environment(\.fernletFramedLook, WorldTheme.framedLook(for: appColors))
            .environment(\.fernletIconRenderer, WorldTheme.iconRenderer)
            .toggleStyle(FernletFramedToggleStyle())
            .formStyle(FernletFormStyle())
    }
}

extension EnvironmentValues {
    /// The World theme in use (always ``WorldTheme/pixel`` today).
    @Entry var worldTheme = WorldTheme.pixel
}
