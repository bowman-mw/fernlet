import FernletUI
import SwiftUI

/// A personal care task's pixel icon (World Review Batch 3, `b3-hygiene`), chosen from the task's
/// stored SF Symbol name, a frozen token the domain owns: brushing the tooth, skincare the drop,
/// sunscreen the star, the shower the tub, deodorant the leaf, flossing the floss case, the evening
/// skincare the moon. A task the person wrote themselves (any other symbol) gets the check.
enum PersonalCareSprites {
    /// The sprite for a task's `systemImage` token.
    static func sprite(forSymbol symbol: String) -> WorldSprite {
        switch symbol {
        case "mouth": WorldSprites.tooth
        case "checkmark.seal": WorldSprites.floss
        case "shower": WorldSprites.tub
        case "sparkle": WorldSprites.leaf
        case "sun.max": WorldSprites.drop
        case "drop": WorldSprites.star
        case "moon": WorldSprites.moon
        default: WorldSprites.check
        }
    }

    /// The ink a task's icon draws in: the dim token for the pale moon, which all but vanishes on
    /// light paper; the sprite's own colours (nil) for the rest.
    static func tint(forSymbol symbol: String) -> Color? {
        symbol == "moon" ? WorldPalette.dim : nil
    }
}

/// A sheet's date row in the World look (`b3-log-period`, `b3-log-intimacy`): the field's name in bold
/// ink on the left, the compact date picker on the right; stacked when the two don't fit side by side
/// (the largest text sizes).
struct PrivateDateRow<Picker: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let picker: Picker

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label
                Spacer(minLength: 8)
                picker
            }
            VStack(alignment: .leading, spacing: 8) {
                label
                picker
            }
        }
    }

    /// The field's name.
    private var label: some View {
        Text(title)
            .font(FernletFramedFont.rowTitleBold)
            .foregroundStyle(WorldPalette.bark)
    }
}

/// The tick box at the end of a personal care row (`b3-hygiene`): an empty framed square, or the moss
/// square with a white pixel tick when the task is done. Decorative: the row says "completed" or
/// "not done yet" itself.
struct CareTickBox: View {
    let isDone: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        Group {
            if isDone {
                WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: WorldPalette.onAccent)
                    .frame(width: 28, height: 28)
                    .background(WorldPalette.accent, in: shape)
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
                    .background(WorldPalette.paperLight, in: shape)
            }
        }
        .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 2.5))
        .accessibilityHidden(true)
    }
}
