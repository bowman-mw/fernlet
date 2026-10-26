import FernletDomainModel
import FernletUI
import SwiftUI

/// A quick-log tile's pixel icon in the World Log panel (World Review Batch 2, `b2-log`): the sprite,
/// and whether it draws in the look's dim ink (one-colour or pale art that would vanish on paper).
nonisolated struct WorldLogIcon: Equatable, Sendable {
    let sprite: WorldSprite
    /// Draw in the dim ink token instead of the sprite's own colours.
    var inDimInk = false
}

extension FernletShortcut {
    /// This shortcut's pixel icon on a Log panel tile (`b2-log`): Meals the onigiri, Water the drop,
    /// Move the shoe, Sleep the moon, Journal the diary, Care the check, and the Private and First aid
    /// tools their own art.
    var worldLogIcon: WorldLogIcon {
        switch self {
        case .meal: WorldLogIcon(sprite: WorldSprites.onigiri)
        case .water: WorldLogIcon(sprite: WorldSprites.drop)
        case .move: WorldLogIcon(sprite: WorldSprites.shoe)
        case .sleep: WorldLogIcon(sprite: WorldSprites.moon, inDimInk: true)
        case .journal, .periodTracking: WorldLogIcon(sprite: WorldSprites.diary)
        case .care: WorldLogIcon(sprite: WorldSprites.check)
        case .logPeriod, .intimacyTracking: WorldLogIcon(sprite: WorldSprites.heart)
        case .friends: WorldLogIcon(sprite: WorldSprites.face)
        case .breathing: WorldLogIcon(sprite: WorldSprites.breathe)
        case .grounding: WorldLogIcon(sprite: WorldSprites.target)
        case .worryBox: WorldLogIcon(sprite: WorldSprites.box)
        }
    }
}

/// The face of one Log panel tile (`b2-log`): a framed paper tile, the pixel icon on top, the noun in
/// ink and today's count in dim ink beneath. Purely drawn; ``QuickLogButton`` owns the action and
/// every spoken name.
struct WorldQuickLogTileFace: View {
    let icon: WorldLogIcon
    let noun: Text
    let state: Text?
    let look: FernletFramedLook

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius, style: .continuous)
        VStack(spacing: 6) {
            WorldSpriteView(sprite: icon.sprite, scale: 3, tint: icon.inDimInk ? look.dim : nil)
                .frame(height: 36)
                .accessibilityHidden(true)
            noun
                .font(FernletFramedFont.rowTitleBold)
                .foregroundStyle(look.text)
                .fixedSize(horizontal: false, vertical: true)
            if let state {
                state
                    .font(FernletFramedFont.rowValue)
                    .foregroundStyle(look.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.numericText())
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 104)
        .background(look.paper, in: shape)
        .overlay(shape.strokeBorder(look.ink, lineWidth: 2.5))
        .background { shape.fill(look.shadow).offset(y: 3) }
        .contentShape(shape)
    }
}

/// The Water tile's quick +1 in the World look (`b2-log` keeps it): a small framed moss square with
/// the pixel plus, inside the caller's 44-pt target.
struct WorldWaterQuickAddFace: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        FernletIcon(.plus, scale: 2, tint: look?.onAccent ?? Color.onMoss)
            .frame(width: 26, height: 26)
            .background(look?.accent ?? Color.mossFill, in: shape)
            .overlay(shape.strokeBorder(look?.ink ?? Color.bark, lineWidth: 2))
    }
}

/// The Log panel's closing line (`b2-log`): where the six tiles are chosen.
struct WorldLogTilesFootnote: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        Text("Change the six tiles in Settings → Quick-log shortcuts.",
             comment: "World Log panel: the line under the quick-log tiles saying where to choose them. 'Quick-log shortcuts' is the Settings page's name.")
            .font(FernletFramedFont.body)
            .foregroundStyle(look?.dim ?? Color.slate)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }
}
