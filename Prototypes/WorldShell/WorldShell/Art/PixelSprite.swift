import SwiftUI

/// A small piece of pixel art: rows of palette letters, with `.` for a clear pixel.
///
/// The format is the design page's own (`SPR` in "A World for Fernlet"), so the hearts, drops,
/// coins and item-bar icons here are the ones the owner saw and approved, pixel for pixel.
nonisolated struct PixelSprite: Sendable {
    let rows: [String]
    let palette: [Character: UInt32]

    /// Width in pixels (the first row's length).
    var width: Int { rows.first?.count ?? 0 }
    /// Height in pixels.
    var height: Int { rows.count }

    /// The same drawing with some letters recoloured.
    func recoloured(_ changes: [Character: UInt32]) -> PixelSprite {
        PixelSprite(rows: rows, palette: palette.merging(changes) { _, new in new })
    }

    /// The same drawing with letters swapped by position: `swap(letter, x)` returns the letter to use.
    func remapped(_ swap: (Character, Int) -> Character) -> PixelSprite {
        let newRows = rows.map { row in String(row.enumerated().map { swap($0.element, $0.offset) }) }
        return PixelSprite(rows: newRows, palette: palette)
    }
}

/// Draws a ``PixelSprite`` at a whole-number scale with hard edges: one filled rectangle per run of
/// same-coloured pixels in a row. Decorative by default; callers name what it means.
struct PixelSpriteView: View {
    let sprite: PixelSprite
    var scale: CGFloat = 2

    var body: some View {
        Canvas { context, _ in
            for (y, row) in sprite.rows.enumerated() {
                let letters = Array(row)
                var x = 0
                while x < letters.count {
                    let letter = letters[x]
                    var end = x + 1
                    while end < letters.count && letters[end] == letter { end += 1 }
                    if letter != ".", let hex = sprite.palette[letter] {
                        let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale,
                                          width: CGFloat(end - x) * scale, height: scale)
                        context.fill(Path(rect), with: .color(FernColors.rgb(hex)))
                    }
                    x = end
                }
            }
        }
        .frame(width: CGFloat(sprite.width) * scale, height: CGFloat(sprite.height) * scale)
        .accessibilityHidden(true)
    }
}
