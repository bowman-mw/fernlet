import SwiftUI
import FernletDomainModel
import FernletUI

/// A pixel icon in the framed look's icon tile (design language: every icon is pixel art, inside
/// panels too, and icon tiles share the frame).
struct WorldIconTile: View {
    let sprite: WorldSprite
    /// One-colour sprites draw in the look's text ink, never a fixed hex, so they read on dark paper
    /// (Batch 2 build note).
    var tinted = false
    let look: FernletFramedLook

    var body: some View {
        WorldSpriteView(sprite: sprite, scale: 3, tint: tinted ? look.text : nil)
            .frame(width: 38, height: 38)
            // The frame rule (`ref-frames-today`): bare inside a card, framed on its own.
            .fernletFrameRulePiece(.iconSquare, fill: look.raised, cornerRadius: 9)
            .accessibilityHidden(true)
    }
}

/// The pixel chevron at the end of a card that opens something, in the look's ink.
struct WorldChevron: View {
    let look: FernletFramedLook

    var body: some View {
        WorldSpriteView(sprite: WorldSprites.chevR, scale: 2, tint: look.text)
            .accessibilityHidden(true)
    }
}

/// Which pixel icon each Home card shows in the framed look (nil keeps the card's own symbol).
nonisolated enum WorldCardIcons {
    /// A sprite and whether it is one colour (drawn in the ink token).
    struct Icon: Equatable, Sendable {
        let sprite: WorldSprite
        let tinted: Bool
    }

    /// The icon for a Home action card.
    static func icon(for widget: HomeWidget) -> Icon? {
        switch widget {
        case .trends: Icon(sprite: WorldSprites.chart, tinted: true)
        case .logFood: Icon(sprite: WorldSprites.onigiri, tinted: false)
        case .recipeBook: Icon(sprite: WorldSprites.bowl, tinted: true)
        case .newRecipe: Icon(sprite: WorldSprites.plus, tinted: true)
        case .workout: Icon(sprite: WorldSprites.dumbbell, tinted: true)
        case .journal: Icon(sprite: WorldSprites.diary, tinted: false)
        case .sleep: Icon(sprite: WorldSprites.moon, tinted: true)
        case .water: Icon(sprite: WorldSprites.drop, tinted: false)
        case .hygiene: Icon(sprite: WorldSprites.tub, tinted: false)
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient, .milestones, .firstAid, .mealPhotos, .sillyStats:
            nil
        }
    }

    /// The First aid card's chips, by their symbol name today.
    static func icon(forSymbol symbol: String) -> Icon? {
        switch symbol {
        case "wind": Icon(sprite: WorldSprites.breathe, tinted: true)
        case "scope": Icon(sprite: WorldSprites.target, tinted: true)
        case "archivebox": Icon(sprite: WorldSprites.box, tinted: false)
        default: nil
        }
    }
}
