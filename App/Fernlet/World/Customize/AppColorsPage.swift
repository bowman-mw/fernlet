import SwiftUI
import UIKit
import FernletUI

/// App colors (design `b2-colors`, approved 2026-10-24): a small light and dark preview, then Paper,
/// today's Backgrounds as framed swatches (four presets each for light and dark, plus Custom, today's
/// colour picker) with the hex, the contrast line and Reset; then Wood and Accent (``AppWoodCard``,
/// ``AppAccentCard``), stored through ``WorldAppColors``.
///
/// Opens from Customize (and is meant to replace Appearance's Backgrounds). It writes the same two
/// stored backgrounds the Appearance page does (``FernletThemeDefaults``), so both stay in step.
struct AppColorsPage: View {
    var store: FernletStore
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var lightHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var darkHex = FernletThemeDefaults.darkBackgroundHex

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    AppColorsPreview(dark: false)
                    AppColorsPreview(dark: true)
                }
                FernletCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Paper")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(WorldPalette.bark)
                            .accessibilityAddTraits(.isHeader)
                        Text("Choose separate backgrounds for light and dark mode. Cards and input boxes stay in the same color family so the existing text colors remain readable.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(WorldPalette.dim)
                            .fernletWrappingText()
                        FernletDottedRule()
                        AppPaperRow(title: "Light mode", hex: $lightHex, presets: AppPaperPreset.light,
                                    defaultHex: FernletThemeDefaults.lightBackgroundHex, isDark: false)
                        FernletDottedRule()
                        AppPaperRow(title: "Dark mode", hex: $darkHex, presets: AppPaperPreset.dark,
                                    defaultHex: FernletThemeDefaults.darkBackgroundHex, isDark: true)
                    }
                }
                AppWoodCard()
                AppAccentCard()
                Text("Text colours adjust by themselves, so every label stays readable. Protein, carbs and fat keep their colours everywhere, and hearts stay red.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
            }
            .padding(20)
        }
        .fernletPageBackground()
        .fernletPushedPage(AppColorsPage.title)
    }

    /// "App colors".
    static let title = LocalizedStringResource("App colors", comment: "App colors page title (Customize and Appearance): paper, wood and accent")
}

/// One of Paper's preset backgrounds (design `b2-colors`).
struct AppPaperPreset: Identifiable {
    let hex: String
    let name: LocalizedStringResource
    var id: String { hex }

    /// Cream (today's default), Parchment, Mint and Sky.
    static let light: [AppPaperPreset] = [
        AppPaperPreset(hex: FernletThemeDefaults.lightBackgroundHex, name: LocalizedStringResource("Cream", comment: "App colors: the default light paper")),
        AppPaperPreset(hex: "#EFE3C8", name: LocalizedStringResource("Parchment", comment: "App colors: a light paper colour")),
        AppPaperPreset(hex: "#E4EEDD", name: LocalizedStringResource("Mint", comment: "App colors: a light paper colour")),
        AppPaperPreset(hex: "#E2ECF2", name: LocalizedStringResource("Sky", comment: "App colors: a light paper colour")),
    ]

    /// Night (today's default), Forest, Ink and Plum.
    static let dark: [AppPaperPreset] = [
        AppPaperPreset(hex: FernletThemeDefaults.darkBackgroundHex, name: LocalizedStringResource("Night", comment: "App colors: the default dark paper")),
        AppPaperPreset(hex: "#18231B", name: LocalizedStringResource("Forest", comment: "App colors: a dark paper colour")),
        AppPaperPreset(hex: "#171C26", name: LocalizedStringResource("Ink", comment: "App colors: a dark paper colour")),
        AppPaperPreset(hex: "#211A24", name: LocalizedStringResource("Plum", comment: "App colors: a dark paper colour")),
    ]
}

/// One paper row: its name and Reset, the preset swatches and Custom, then the hex and the contrast.
private struct AppPaperRow: View {
    let title: LocalizedStringKey
    @Binding var hex: String
    let presets: [AppPaperPreset]
    let defaultHex: String
    let isDark: Bool
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(FernletFramedFont.rowTitle.weight(.semibold))
                    .foregroundStyle(WorldPalette.bark)
                Spacer()
                Button("Reset") { hex = defaultHex }
                    .buttonStyle(.plain)
                    .font(FernletFramedFont.buttonSmall)
                    .foregroundStyle(WorldPalette.mossInk)
                    .accessibilityInputLabels([Text("Reset"), Text("Reset \(Text(title))")])
                    .disabled(hex.caseInsensitiveCompare(defaultHex) == .orderedSame)
            }
            FlowLayout(spacing: 8) {
                ForEach(presets) { preset in
                    AppPaperSwatch(preset: preset, isSelected: preset.hex.caseInsensitiveCompare(hex) == .orderedSame,
                                   isDark: isDark) { hex = preset.hex }
                }
                AppPaperCustomSwatch(hex: $hex, defaultHex: defaultHex)
            }
            Text(verbatim: "\(hex.uppercased()) · \(contrastText)")
                .font(FernletFramedFont.note)
                .foregroundStyle(WorldPalette.dim)
        }
    }

    /// "Contrast 12.7:1": the worst of the ink pairs this paper produces, on the contrast axis in use.
    private var contrastText: String {
        guard let background = UIColor(hex: hex) else { return "" }
        let contrast: UIAccessibilityContrast = colorSchemeContrast == .increased ? .high : .unspecified
        let palette = hex.caseInsensitiveCompare(defaultHex) == .orderedSame
            ? FernletThemePalette.current(for: isDark ? .dark : .light, contrast: contrast)
            : FernletThemePalette.fitted(background: background, contrast: contrast)
        let worst = min(min(palette.primaryText.contrastRatio(to: palette.background), palette.primaryText.contrastRatio(to: palette.box)),
                        min(palette.secondaryText.contrastRatio(to: palette.background), palette.secondaryText.contrastRatio(to: palette.box)))
        let ratio = Double(worst).formatted(.number.precision(.fractionLength(1)))
        return String(localized: "appColors.contrast", defaultValue: "Contrast \(ratio):1",
                      comment: "App colors: the worst text contrast the chosen paper gives, after its hex ('Contrast 12.7:1')")
    }
}

/// A preset paper: a framed square in the colour with “Aa” (a tick when chosen), its name below. A
/// radio button to VoiceOver: “Parchment, selected”.
private struct AppPaperSwatch: View {
    let preset: AppPaperPreset
    let isSelected: Bool
    let isDark: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if !isSelected { FernletFeedback.system.play(.tick) }
            action()
        } label: {
            VStack(spacing: 4) {
                AppColorSwatchChip(colour: Color(UIColor(hex: preset.hex) ?? .systemBackground), size: 40)
                    .overlay {
                        if isSelected {
                            WorldSpriteView(sprite: WorldSprites.check, scale: 2,
                                            tint: WorldPalette.rgb(isDark ? 0xFFF1CF : 0x3A2414))
                        } else {
                            Text(verbatim: "Aa")
                                .font(.custom(FernletFontName.dmSansMedium, size: 13, relativeTo: .caption).weight(.bold).italic())
                                .foregroundStyle(WorldPalette.rgb(isDark ? 0xFFF1CF : 0x3A2414))
                        }
                    }
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(isSelected ? WorldPalette.moss : .clear, lineWidth: 3))
                Text(preset.name)
                    .font(.fernlet(.labelSmall).weight(.semibold))
                    .foregroundStyle(WorldPalette.dim)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(preset.name))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Custom: today's system colour picker behind a dashed rainbow square.
private struct AppPaperCustomSwatch: View {
    @Binding var hex: String
    let defaultHex: String

    var body: some View {
        VStack(spacing: 4) {
            ColorPicker("Custom", selection: colour, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 46, height: 46)
            Text("Custom")
                .font(.fernlet(.labelSmall).weight(.semibold))
                .foregroundStyle(WorldPalette.dim)
                .accessibilityHidden(true)
        }
    }

    private var colour: Binding<Color> {
        Binding(
            get: { Color(UIColor(hex: hex) ?? UIColor(hex: defaultHex) ?? .systemBackground) },
            set: { hex = UIColor($0).hexString ?? defaultHex }
        )
    }
}

/// A tiny app in the chosen colours (design `b2-colors`): a wooden plate, a meal card with its macro
/// bars, and the accent's Log button, over “Light” or “Dark”. Decorative. It follows the Wood and
/// Accent picks (the swatch face, and the accent's light or dark face) as they are made.
private struct AppColorsPreview: View {
    let dark: Bool
    @Environment(\.worldAppColors) private var appColors

    var body: some View {
        VStack(spacing: 4) {
            VStack(spacing: 0) {
                Text("Food")
                    .font(.custom(FernletFontName.frauncesSemiBold, size: 13, relativeTo: .caption))
                    .foregroundStyle(appColors.wood == .walnut ? WorldPalette.gameCream : WorldPalette.rgb(0x3A2414))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(appColors.wood.swatch)
                    .overlay(alignment: .bottom) { WorldPalette.rgb(0x4A2E1C).frame(height: 2) }
                VStack(spacing: 6) {
                    mealCard
                    Text("Log")
                        .font(.fernlet(.labelSmall).weight(.bold))
                        .foregroundStyle(appColors.accent.tones.onAccent)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(appColors.accent.tones.accent, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
                }
                .padding(8)
            }
            .background(WorldPalette.rgb(dark ? 0x1C1E1B : 0xF5EFDF))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 2))
            (dark ? Text("Dark") : Text("Light"))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(WorldPalette.dim)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    private var mealCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Breakfast")
                .font(.fernlet(.labelSmall).weight(.semibold))
                .foregroundStyle(WorldPalette.rgb(dark ? 0xFFF1CF : 0x3A2414))
            HStack(spacing: 3) {
                bar(0x5E844D).frame(maxWidth: .infinity).layoutPriority(3)
                bar(0xD2973B).frame(maxWidth: .infinity).layoutPriority(2)
                bar(0xB8543D).frame(maxWidth: .infinity)
            }
        }
        .padding(6)
        .background(WorldPalette.rgb(dark ? 0x3A2E22 : 0xFFF6E2), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
    }

    private func bar(_ hex: UInt32) -> some View {
        Rectangle().fill(WorldPalette.rgb(hex)).frame(height: 5)
    }
}
