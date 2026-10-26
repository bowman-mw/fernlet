import SwiftUI
import FernletUI

/// App colors' Wood card (design `b2-colors`): Oak, Birch, Cherry or Walnut for the title plates, the
/// item bar and the grabbers, as framed swatches with "Aa" in the wood's own label ink. A radio group:
/// VoiceOver hears "Oak, selected". The choice is stored through ``WorldAppColors`` and read back from
/// the environment, so the page, the plate above it and the preview redraw at once.
struct AppWoodCard: View {
    @Environment(\.worldAppColors) private var appColors

    var body: some View {
        AppColorChoiceCard(title: "Wood", detail: "The title plates, the item bar and the grabbers.") {
            ForEach(WorldWood.allCases) { wood in
                AppColorChoiceSwatch(name: wood.name, face: wood.swatch, ink: wood.tones.label,
                                     isSelected: appColors.wood == wood) { WorldAppColors.setWood(wood) }
            }
        }
    }
}

/// App colors' Accent card (design `b2-colors`): Moss, Sea, Plum, Clay or Sun for buttons, switches and
/// selected chips, each 5:1 or better with its text. A radio group, like Wood.
struct AppAccentCard: View {
    @Environment(\.worldAppColors) private var appColors

    var body: some View {
        AppColorChoiceCard(title: "Accent", detail: "Buttons, switches and selected chips.") {
            ForEach(WorldAccent.allCases) { accent in
                AppColorChoiceSwatch(name: accent.name, face: accent.tones.accent, ink: accent.tones.onAccent,
                                     isSelected: appColors.accent == accent) { WorldAppColors.setAccent(accent) }
            }
        }
    }
}

/// One App colors card: its Fraunces-style header, a line saying what it colours, then the swatches.
private struct AppColorChoiceCard<Swatches: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let swatches: Swatches

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(WorldPalette.bark)
                    .accessibilityAddTraits(.isHeader)
                Text(detail)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                FlowLayout(spacing: 8) { swatches }
            }
        }
    }
}

/// A wood or accent swatch: a framed square in the colour with "Aa" in the ink that goes on it (a tick
/// when chosen, ringed in moss), its name below.
private struct AppColorChoiceSwatch: View {
    let name: LocalizedStringResource
    let face: Color
    let ink: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if !isSelected { FernletFeedback.system.play(.tick) }
            action()
        } label: {
            VStack(spacing: 4) {
                AppColorSwatchChip(colour: face, size: 40)
                    .overlay {
                        if isSelected {
                            WorldSpriteView(sprite: WorldSprites.check, scale: 2, tint: ink)
                        } else {
                            Text(verbatim: "Aa")
                                .font(.custom(FernletFontName.dmSansBold, size: 13, relativeTo: .caption).italic())
                                .foregroundStyle(ink)
                        }
                    }
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? WorldPalette.moss : .clear, lineWidth: 3))
                Text(name)
                    .font(.fernlet(.labelSmall).weight(.semibold))
                    .foregroundStyle(WorldPalette.dim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
