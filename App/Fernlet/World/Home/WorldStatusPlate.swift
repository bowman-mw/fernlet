import SwiftUI

/// The World Home's status plate, top left on the map (design `b1-home-day`, draft 3, approved
/// 2026-10-23; World app plan step 2b): six hearts with halves and any gold hearts after them, the
/// protein, carbs and fat bars, and water. No clock, weather or coins up top: the time of day and the
/// weather show on the map, and coins stay in Customize and the friend shop, as today.
///
/// It reads ``WorldStatus`` (today's sources, unchanged). One button: it opens Today, where every Home
/// card lives. VoiceOver hears the care score first, as Home's health bar says it ("Care score 58
/// percent"), then what the gold hearts add, the three macros and the water.
///
/// At accessibility text sizes the hearts drop to four (three steps each), the bars narrow and water
/// reads "n / target", as the approved largest-text design draws them.
struct WorldStatusPlate: View {
    let status: WorldStatus
    let onOpenToday: () -> Void
    @Environment(\.worldTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onOpenToday) {
            VStack(alignment: .leading, spacing: 5) {
                hearts
                macros
                water
            }
            .padding(EdgeInsets(top: 7, leading: 9, bottom: 7, trailing: 9))
            .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .bottom) { WorldPalette.paperShade.frame(height: 3).padding(.horizontal, 3).padding(.bottom, 3) }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color(.sRGB, red: 74 / 255, green: 46 / 255, blue: 28 / 255, opacity: 0.4)).offset(y: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: spokenSummary))
        .accessibilityHint(Text(LocalizedStringResource("worldStatus.hint", defaultValue: "Opens Today",
                                                        comment: "World Home: what tapping the status plate does, for VoiceOver")))
        .accessibilityInputLabels([Text(verbatim: WorldPanel.today.barName),
                                   Text(LocalizedStringResource("worldStatus.inputLabel", defaultValue: "Hearts",
                                                                comment: "World Home: a short name Voice Control can use for the status plate"))])
        .accessibilityIdentifier("world.statusPlate")
    }

    private var isLarge: Bool { dynamicTypeSize.isAccessibilitySize }

    /// Six hearts (four at the largest sizes), then the gold hearts.
    private var hearts: some View {
        let count = isLarge ? 4 : 6, scale = theme.scale(accessibilitySize: isLarge)
        return HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                WorldSpriteView(sprite: WorldSprites.heart, scale: scale, variant: .heart(fill(at: index, of: count)))
            }
            ForEach(0..<status.goldHearts, id: \.self) { _ in
                WorldSpriteView(sprite: WorldSprites.heart, scale: scale, variant: .heart(.gold))
            }
        }
    }

    /// Full, half or empty for heart `index` of `count` (at four hearts, a third or two counts as half).
    private func fill(at index: Int, of count: Int) -> WorldHeartFill {
        let amount = status.heartFill(at: index, of: count)
        if amount >= 1 { return .full }
        return amount > 0 ? .half : .empty
    }

    /// The protein, carbs and fat bars, in the one set of data colours.
    private var macros: some View {
        HStack(spacing: isLarge ? 6 : 8) {
            macroBar(letter: String(localized: "worldStatus.protein", defaultValue: "P", comment: "World Home status plate: the letter before the protein bar (Spanish: P)"),
                     macro: status.protein, colour: WorldPalette.protein)
            macroBar(letter: String(localized: "worldStatus.carbs", defaultValue: "C", comment: "World Home status plate: the letter before the carbs bar (Spanish: C)"),
                     macro: status.carbs, colour: WorldPalette.carbs)
            macroBar(letter: String(localized: "worldStatus.fat", defaultValue: "F", comment: "World Home status plate: the letter before the fat bar (Spanish: G, grasa)"),
                     macro: status.fat, colour: WorldPalette.fat)
        }
    }

    /// One framed macro bar.
    private func macroBar(letter: String, macro: WorldStatus.Macro, colour: Color) -> some View {
        let width: CGFloat = isLarge ? 38 : 46
        return HStack(spacing: 4) {
            Text(verbatim: letter)
                .font(WorldType.plateLabel)
                .dynamicTypeSize(...WorldType.plateTextCap)
                .foregroundStyle(WorldPalette.bark)
                .frame(minWidth: 9)
            ZStack(alignment: .leading) {
                WorldPalette.barEmpty
                colour.frame(width: max(0, width - 6) * macro.fraction)
            }
            .frame(width: width - 6, height: 5)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(WorldPalette.ink, lineWidth: 3))
        }
    }

    /// Water: a drop per bottle of the target with "+n" past it, or one drop and "n / target".
    @ViewBuilder
    private var water: some View {
        let scale = theme.scale(accessibilitySize: isLarge)
        switch status.water(accessibilitySize: isLarge) {
        case .drops(let filled, let total, let extra):
            HStack(spacing: 3) {
                ForEach(0..<total, id: \.self) { index in
                    WorldSpriteView(sprite: WorldSprites.drop, scale: scale, variant: .drop(full: index < filled))
                }
                if extra > 0 {
                    Text(verbatim: "+\(extra.formatted())")
                        .font(WorldType.plateCount(large: false))
                        .dynamicTypeSize(...WorldType.plateTextCap)
                        .foregroundStyle(WorldPalette.bark)
                }
            }
        case .count(let bottles, let target) where target > 0:
            HStack(spacing: 6) {
                WorldSpriteView(sprite: WorldSprites.drop, scale: scale, variant: .drop(full: bottles > 0))
                Text(verbatim: "\(bottles.formatted()) / \(target.formatted())")
                    .font(WorldType.plateCount(large: isLarge))
                    .dynamicTypeSize(...WorldType.plateTextCap)
                    .foregroundStyle(WorldPalette.bark)
            }
        case .count:
            EmptyView()
        }
    }

    /// What VoiceOver reads for the whole plate.
    private var spokenSummary: String {
        let care = String(localized: "worldStatus.a11y.care", defaultValue: "Care score \(status.carePercent) percent",
                          comment: "World Home status plate, VoiceOver: the care score, as Home's health bar says it")
        let goldHearts = String(localized: "worldStatus.a11y.goldHearts", defaultValue: "\(status.goldHearts) gold hearts from friends",
                                comment: "World Home status plate, VoiceOver: how many gold hearts friends gave in person. Plural on the number")
        let gold = status.goldHearts == 0 ? "" : " " + String(
            localized: "worldStatus.a11y.gold", defaultValue: "Lifted to \(status.livePercent) percent by \(goldHearts).",
            comment: "World Home status plate, VoiceOver: the care score with the gold hearts' lift; the second part is 'N gold hearts from friends'")
        let macros = String(
            localized: "worldStatus.a11y.macros",
            defaultValue: "Protein \(status.protein.grams) of \(status.protein.target) grams, carbs \(status.carbs.grams) of \(status.carbs.target), fat \(status.fat.grams) of \(status.fat.target).",
            comment: "World Home status plate, VoiceOver: today's macros against their targets")
        let bottles = String(localized: "worldStatus.a11y.bottles", defaultValue: "\(status.bottles) bottles",
                             comment: "World Home status plate, VoiceOver: bottles of water today. Plural on the number")
        let water = String(localized: "worldStatus.a11y.water", defaultValue: "Water: \(bottles), target \(status.bottleTarget).",
                           comment: "World Home status plate, VoiceOver: water today ('6 bottles') and the day's bottle target")
        return "\(care).\(gold) \(macros) \(water)"
    }
}
