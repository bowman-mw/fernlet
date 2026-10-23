import SwiftUI

/// The top-left status bar: six hearts with halves, gold hearts after them, protein / carbs / fat
/// bars, and eight water drops. One button: it opens the Today panel.
///
/// The hearts are HealthBar's twelve segments, two to a heart, so nothing is lost (design page,
/// answer "Hearts fit one line"). VoiceOver hears today's sentence, "Care score 58 percent".
///
/// It sits on a cream plate like the clock and coins, so the P / C / F letters are solid ink on
/// cream (11:1) wherever the map is, with no text shadow.
struct StatusBarLeft: View {
    let careScore: Double
    let goldHearts: Int
    let protein: Int
    let carbs: Int
    let fat: Int
    let water: Int
    let action: () -> Void
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: metrics.pt(3)) {
                HStack(spacing: 1) {
                    ForEach(0..<6, id: \.self) { index in PixelSpriteView(sprite: heart(at: index)) }
                    ForEach(0..<min(2, goldHearts), id: \.self) { _ in PixelSpriteView(sprite: PixelSprites.goldHeart) }
                }
                HStack(spacing: metrics.pt(6)) {
                    MacroPip(letter: "P", value: protein, target: WorldFixtures.macroTargets.protein, color: FernColors.protein)
                    MacroPip(letter: "C", value: carbs, target: WorldFixtures.macroTargets.carbs, color: FernColors.carbs)
                    MacroPip(letter: "F", value: fat, target: WorldFixtures.macroTargets.fat, color: FernColors.fat)
                }
                HStack(spacing: metrics.pt(2)) {
                    ForEach(0..<8, id: \.self) { index in
                        PixelSpriteView(sprite: index < water ? PixelSprites.drop : PixelSprites.emptyDrop)
                    }
                }
                .padding(.top, metrics.pt(1))
            }
            .padding(EdgeInsets(top: metrics.pt(4), leading: metrics.pt(5), bottom: metrics.pt(4), trailing: metrics.pt(5)))
            .gamePlate(cornerRadius: metrics.pt(6), border: metrics.pt(2))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens today")
    }

    /// Full, half or empty for heart `index`, from the score's twelve segments.
    private func heart(at index: Int) -> PixelSprite {
        let halves = Int((careScore * 12).rounded())
        if halves >= 2 * (index + 1) { return PixelSprites.heart }
        if halves == 2 * index + 1 { return PixelSprites.halfHeart }
        return PixelSprites.emptyHeart
    }

    /// The sentence VoiceOver reads for the whole bar.
    private var accessibilityText: String {
        let score = Int((careScore * 100).rounded())
        let boosted = Int((min(1, careScore + Double(goldHearts) / 12) * 100).rounded())
        let gold = goldHearts > 0 ? ", lifted to \(boosted) by \(goldHearts) gold \(goldHearts == 1 ? "heart" : "hearts") from friends" : ""
        let targets = WorldFixtures.macroTargets
        return "Care score \(score) percent\(gold). Protein \(protein) of \(targets.protein) grams, carbs \(carbs) of \(targets.carbs), fat \(fat) of \(targets.fat). Water \(water) of 8."
    }
}

/// One macro bar: a pixel letter and a short framed bar filled to today's share of the target.
/// The mockup's bar is 32 × 7 pt inside a 2 pt border; here it scales with the screen.
private struct MacroPip: View {
    let letter: String
    let value: Int
    let target: Int
    let color: Color
    @Environment(\.shellMetrics) private var metrics

    var body: some View {
        let width = metrics.pt(32), border = metrics.pt(2)
        HStack(spacing: metrics.pt(2)) {
            Text(letter)
                .font(.system(size: metrics.pt(9), weight: .heavy, design: .monospaced))
                .foregroundStyle(FernColors.ink)
                .frame(width: metrics.pt(8))
            ZStack(alignment: .leading) {
                Rectangle().fill(FernColors.gameCream.opacity(0.85))
                Rectangle().fill(color).frame(width: width * min(1, Double(value) / Double(max(1, target))))
            }
            .frame(width: width, height: metrics.pt(7))
            .overlay(Rectangle().strokeBorder(FernColors.ink, lineWidth: border).padding(-border))
            .padding(border)
        }
    }
}
