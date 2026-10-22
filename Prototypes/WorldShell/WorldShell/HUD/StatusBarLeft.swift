import SwiftUI

/// The top-left status bar: six hearts with halves, gold hearts after them, protein / carbs / fat
/// bars, and eight water drops. One button: it opens the Today panel.
///
/// The hearts are HealthBar's twelve segments, two to a heart, so nothing is lost (design page,
/// answer "Hearts fit one line"). VoiceOver hears today's sentence, "Care score 58 percent".
struct StatusBarLeft: View {
    let careScore: Double
    let goldHearts: Int
    let protein: Int
    let carbs: Int
    let fat: Int
    let water: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 1) {
                    ForEach(0..<6, id: \.self) { index in PixelSpriteView(sprite: heart(at: index)) }
                    ForEach(0..<min(2, goldHearts), id: \.self) { _ in PixelSpriteView(sprite: PixelSprites.goldHeart) }
                }
                HStack(spacing: 6) {
                    MacroPip(letter: "P", value: protein, target: WorldFixtures.macroTargets.protein, color: FernColors.protein)
                    MacroPip(letter: "C", value: carbs, target: WorldFixtures.macroTargets.carbs, color: FernColors.carbs)
                    MacroPip(letter: "F", value: fat, target: WorldFixtures.macroTargets.fat, color: FernColors.fat)
                }
                HStack(spacing: 2) {
                    ForEach(0..<8, id: \.self) { index in
                        PixelSpriteView(sprite: index < water ? PixelSprites.drop : PixelSprites.emptyDrop)
                    }
                }
                .padding(.top, 2)
            }
            .padding(2)
            .shadow(color: FernColors.ink.opacity(0.35), radius: 0, x: 0, y: 1)
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
private struct MacroPip: View {
    let letter: String
    let value: Int
    let target: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Text(letter)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(FernColors.woodLabel)
                .shadow(color: FernColors.ink, radius: 0, x: 1, y: 1)
                .shadow(color: FernColors.ink, radius: 0, x: -1, y: 0)
                .frame(width: 8)
            ZStack(alignment: .leading) {
                Rectangle().fill(FernColors.gameCream.opacity(0.85))
                Rectangle().fill(color).frame(width: 30 * min(1, Double(value) / Double(max(1, target))))
            }
            .frame(width: 30, height: 5)
            .overlay(Rectangle().strokeBorder(FernColors.ink, lineWidth: 2).padding(-2))
            .padding(2)
        }
    }
}
