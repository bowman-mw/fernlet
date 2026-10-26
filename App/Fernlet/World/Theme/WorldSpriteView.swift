import SwiftUI

/// How a sprite's keys are recoloured for one use, as the approved designs do it (World Review Batch 1).
nonisolated enum WorldSpriteVariant: Equatable, Sendable {
    /// As drawn.
    case plain
    /// A heart of the status plate: full, half (the right side empty), empty, or gold.
    case heart(WorldHeartFill)
    /// A water drop: full, or an empty outline.
    case drop(full: Bool)

    /// The colour key `key` at column `x` draws in, or nil to keep the sprite's own.
    func colour(for key: Character, column x: Int) -> UInt32? {
        switch self {
        case .plain:
            return nil
        case .heart(let fill):
            guard key == "R" || key == "h" else { return nil }
            switch fill {
            case .gold: return key == "R" ? 0xF2C14E : 0xFFF0A8
            case .empty: return 0x8E5E4A
            case .half: return x > 3 ? 0x8E5E4A : nil
            case .full: return nil
            }
        case .drop(let full):
            guard !full, key == "B" || key == "h" else { return nil }
            return 0xA9BCC2
        }
    }
}

/// How full one heart of the status plate is.
nonisolated enum WorldHeartFill: Equatable, Sendable {
    case full, half, empty, gold
}

/// Draws a ``WorldSprite`` crisply: each key one `scale`-point square, no smoothing. This is the one
/// place the World's pixel icons are drawn, the framed FernletUI primitives' icons included
/// (``WorldTheme/iconRenderer``).
///
/// A one-colour ink icon (``WorldSprite/isMonoInk``) takes the ink token, ``WorldPalette/iconInk``,
/// unless it is given a tint: ink on light paper, cream on dark (World Review Batch 2 draft 2, built
/// on Batch 1 screens too). Every other sprite keeps its own colours.
///
/// Decoration to VoiceOver: the element that carries the sprite says what it means.
struct WorldSpriteView: View {
    let sprite: WorldSprite
    /// Points per sprite pixel (whole numbers keep the art crisp).
    var scale: CGFloat = 3
    var variant: WorldSpriteVariant = .plain
    /// One colour for every pixel (white on an accent fill). Nil keeps the sprite's own colours, or the
    /// ink token for a one-colour icon. Never a fixed hex for ink, or the icon vanishes on dark paper.
    var tint: Color? = nil

    var body: some View {
        let ink: Color? = tint ?? (variant == .plain && sprite.isMonoInk ? WorldPalette.iconInk : nil)
        Canvas { context, _ in
            for (y, row) in sprite.rows.enumerated() {
                for (x, key) in row.enumerated() where key != "." {
                    guard let base = sprite.palette[key] else { continue }
                    let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)
                    context.fill(Path(rect), with: .color(ink ?? WorldPalette.rgb(variant.colour(for: key, column: x) ?? base)))
                }
            }
        }
        .frame(width: CGFloat(sprite.width) * scale, height: CGFloat(sprite.height) * scale)
        .accessibilityHidden(true)
    }
}
