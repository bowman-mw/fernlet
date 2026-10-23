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
                .log: WorldSprites.basket, .friends: WorldSprites.face, .personal: WorldSprites.diary,
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
    static let barLabel = Font.custom(FernletFontName.dmSansMedium, size: 12.5, relativeTo: .caption).weight(.bold)
    /// The status plate's macro letters (13 pt DM Sans, bold).
    static let plateLabel = Font.custom(FernletFontName.dmSansMedium, size: 13, relativeTo: .caption).weight(.bold)
    /// The status plate's water count: 16 pt, or 22 pt at accessibility sizes, as the approved
    /// largest-text design draws it.
    static func plateCount(large: Bool) -> Font {
        Font.custom(FernletFontName.dmSansMedium, size: large ? 22 : 16, relativeTo: .caption).weight(.bold)
    }

    /// The largest the status plate's letters grow: the plate sits on the map, so its text follows the
    /// approved design's fixed steps rather than growing without bound.
    static let plateTextCap = DynamicTypeSize.xLarge
}

extension EnvironmentValues {
    /// The World theme in use (always ``WorldTheme/pixel`` today).
    @Entry var worldTheme = WorldTheme.pixel
}
