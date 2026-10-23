import SwiftUI

/// The top-right status bar: the clock badge with the time-of-day sky, and the coin pill under it.
/// No day badge, and nothing in its place for now (design page, answers 8 and 11).
struct StatusBarRight: View {
    let phase: SkyPhase
    /// The clock text: the real time, or the phase's sample time when the phase is a fixture.
    let clock: String
    let coins: Int
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        VStack(alignment: .trailing, spacing: metrics.pt(5)) {
            HStack(spacing: metrics.pt(6)) {
                // The sky chip clips its icons, as the mockup's does: sun and cloud overlap a little.
                HStack(spacing: -metrics.pixel) {
                    ForEach(Array(phase.badgeIcons.enumerated()), id: \.offset) { _, icon in PixelSpriteView(sprite: icon) }
                }
                .frame(width: metrics.pt(30), height: metrics.pt(20))
                .background(FernColors.rgb(phase.badgeSkyHex))
                .clipShape(RoundedRectangle(cornerRadius: metrics.pt(3)))
                .overlay(RoundedRectangle(cornerRadius: metrics.pt(3)).strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
                Text(clock)
                    .font(.system(size: metrics.pt(15), weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(FernColors.ink)
            }
            .padding(EdgeInsets(top: metrics.pt(2), leading: metrics.pt(2), bottom: metrics.pt(2), trailing: metrics.pt(7)))
            .gamePlate(cornerRadius: metrics.pt(6), border: metrics.pt(2))
            HStack(spacing: metrics.pt(4)) {
                PixelSpriteView(sprite: PixelSprites.coin)
                Text(coins.formatted())
                    .font(.system(size: metrics.pt(13), weight: .bold, design: .monospaced))
                    .foregroundStyle(FernColors.ink)
            }
            .padding(EdgeInsets(top: metrics.pt(1), leading: metrics.pt(3), bottom: metrics.pt(1), trailing: metrics.pt(8)))
            .background(FernColors.gameCream.opacity(0.94), in: Capsule())
            .overlay(Capsule().strokeBorder(FernColors.ink, lineWidth: metrics.pt(2)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clock), \(phase.label). \(coins) coins.")
    }
}

extension View {
    /// The game look's cream plate: an ink border, a darker inner bottom edge, a drop shadow. The
    /// shadow is on the plate's shape only, so the text on it stays single and crisp.
    func gamePlate(cornerRadius: CGFloat, border: CGFloat = 2, fill: Color = FernColors.gameCream) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill)
                .overlay(alignment: .bottom) {
                    FernColors.gameCreamShade.frame(height: border).padding(.horizontal, border + 1).padding(.bottom, border)
                }
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(FernColors.ink.opacity(0.45)).offset(y: border)
                }
        }
        .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(FernColors.ink, lineWidth: border))
    }
}
