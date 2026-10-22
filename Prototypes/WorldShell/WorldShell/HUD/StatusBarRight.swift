import SwiftUI

/// The top-right status bar: the clock badge with the time-of-day sky, and the coin pill under it.
/// No day badge, and nothing in its place for now (design page, answers 8 and 11).
struct StatusBarRight: View {
    let phase: SkyPhase
    /// The clock text: the real time, or the phase's sample time when the phase is a fixture.
    let clock: String
    let coins: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 1) {
                    ForEach(Array(phase.badgeIcons.enumerated()), id: \.offset) { _, icon in PixelSpriteView(sprite: icon) }
                }
                .frame(width: 30, height: 20)
                .background(FernColors.rgb(phase.badgeSkyHex))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(FernColors.ink, lineWidth: 2))
                Text(clock)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(FernColors.ink)
            }
            .padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 8))
            .gamePlate(cornerRadius: 6)
            HStack(spacing: 4) {
                PixelSpriteView(sprite: PixelSprites.coin)
                Text(coins.formatted())
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(FernColors.ink)
            }
            .padding(EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 8))
            .background(FernColors.gameCream.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(FernColors.ink, lineWidth: 2))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clock), \(phase.label). \(coins) coins.")
    }
}

extension View {
    /// The game look's cream plate: an ink border, a darker inner bottom edge, a drop shadow.
    func gamePlate(cornerRadius: CGFloat, fill: Color = FernColors.gameCream) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill)
                .overlay(alignment: .bottom) {
                    FernColors.gameCreamShade.frame(height: 2).padding(.horizontal, 3).padding(.bottom, 2)
                }
        }
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(FernColors.ink, lineWidth: 2))
        .shadow(color: FernColors.ink.opacity(0.45), radius: 0, x: 0, y: 2)
    }
}
