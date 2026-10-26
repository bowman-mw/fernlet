import SwiftUI

/// The care score as pixel hearts, gold hearts after them (design language: "the care score is six
/// hearts in both places"). The status plate and the Today panel's Today card draw this one row, so
/// the two always agree.
struct WorldHeartRow: View {
    let status: WorldStatus
    /// Six hearts, or four at accessibility text sizes (``WorldStatus/heartFill(at:of:)``).
    let count: Int
    /// Points per sprite pixel.
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                WorldSpriteView(sprite: WorldSprites.heart, scale: scale, variant: .heart(Self.fill(status, at: index, of: count)))
            }
            ForEach(0..<status.goldHearts, id: \.self) { _ in
                WorldSpriteView(sprite: WorldSprites.heart, scale: scale, variant: .heart(.gold))
            }
        }
        .accessibilityHidden(true)
    }

    /// Full, half or empty for heart `index` of `count` (at four hearts, a third or two counts as half).
    static func fill(_ status: WorldStatus, at index: Int, of count: Int) -> WorldHeartFill {
        let amount = status.heartFill(at: index, of: count)
        if amount >= 1 { return .full }
        return amount > 0 ? .half : .empty
    }
}
