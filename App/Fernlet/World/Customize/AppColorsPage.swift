import SwiftUI
import UIKit
import FernletUI

/// App colors (design `b2-colors`, approved 2026-10-24): a small light and dark preview, then Paper,
/// today's Backgrounds as framed swatches (four presets each for light and dark, plus Custom, today's
/// colour picker) with the hex, the contrast line and Reset; then Wood and Accent (``AppWoodCard``,
/// ``AppAccentCard``), stored through ``WorldAppColors``.
///
/// Opens from Settings › Appearance (``AppColorsSettingsRow``, the approved path) and from Customize.
/// It writes today's two stored backgrounds (``FernletThemeDefaults``), which Appearance's pickers
/// used to.
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
        // Today's Appearance warning, kept when the backgrounds moved here: the meaning accents (moss,
        // terracotta) cannot be fitted to a custom paper, so the line says when they drop under 3:1.
        guard !AppPaperContrast.accentsFallBelowFloor(on: background) else {
            return String(localized: "Contrast \(ratio):1 · accents may be hard to see",
                          comment: "App colors (and formerly Appearance): the worst text contrast the chosen paper gives, when the meaning accents fall under 3:1 on it")
        }
        return String(localized: "appColors.contrast", defaultValue: "Contrast \(ratio):1",
                      comment: "App colors: the worst text contrast the chosen paper gives, after its hex ('Contrast 12.7:1')")
    }
}

/// The accent check today's Appearance page ran beside a custom background, moved here with the
/// backgrounds (`b2-colors`).
nonisolated enum AppPaperContrast {
    /// Whether either of the two accents that carry *meaning* on a background — moss (the app's
    /// affirmative tint, 179 foreground sites) and terracotta (destructive) — falls under the 3:1
    /// WCAG non-text floor on either surface the chosen colour produces.
    ///
    /// Accents are fixed hues with no dependence on the background, so unlike the inks they cannot
    /// be fitted; the honest move is to warn rather than to silently recolour the whole design
    /// system out from under the user's choice. This is the one risk the T2-7 guardrail does not
    /// remove, which is exactly why the line says so.
    ///
    /// Deliberately takes no contrast argument, unlike the ratio beside it: the two colours it
    /// measures against are the background itself and `palette.box`, and `boxColor(from:…)` is a
    /// fixed 0.97/0.17 brightness pin with no contrast axis at all. Only the *inks* move with
    /// Increase Contrast, so threading it here would imply a dependence that does not exist.
    static func accentsFallBelowFloor(on background: UIColor) -> Bool {
        let palette = FernletThemePalette.fitted(background: background)
        let isDark = background.relativeLuminance < FernletThemePalette.inkFamilyCrossover
        let moss = isDark
            ? UIColor(red: 0.498, green: 0.690, blue: 0.412, alpha: 1)
            : UIColor(red: 0.369, green: 0.518, blue: 0.302, alpha: 1)
        let terracotta = isDark
            ? UIColor(red: 0.839, green: 0.459, blue: 0.345, alpha: 1)
            : UIColor(red: 0.724, green: 0.329, blue: 0.239, alpha: 1)
        let worst = [moss, terracotta]
            .flatMap { [$0.contrastRatio(to: background), $0.contrastRatio(to: palette.box)] }
            .min() ?? 21
        return worst < 3.0
    }
}

/// Settings › Appearance's one Colors row (`b2-settings-appearance`, redrawn with `b2-colors`): "App
/// colors" with its line, and four small swatches of what is chosen now (light paper, dark paper,
/// wood, accent). It pushes ``AppColorsPage``.
struct AppColorsSettingsRow: View {
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var lightHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var darkHex = FernletThemeDefaults.darkBackgroundHex
    @Environment(\.worldAppColors) private var appColors
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The words take the room and wrap; the swatches keep their size beside them, and step aside at
    /// accessibility sizes so the words keep the row.
    var body: some View {
        HStack(spacing: 10) {
            label.frame(maxWidth: .infinity, alignment: .leading)
            if !dynamicTypeSize.isAccessibilitySize {
                swatches.fixedSize()
            }
        }
    }

    private var label: some View {
        FernletRowLabel(title: Text("App colors"),
                        detail: Text("Paper, wood and accent, for light and dark mode.",
                                     comment: "Settings › Appearance: the App colors row's second line"))
    }

    /// The four chosen colours, decorative (the page they open names them).
    private var swatches: some View {
        HStack(spacing: 4) {
            AppColorSwatchChip(colour: Color(UIColor(hex: lightHex) ?? .systemBackground), size: 18)
            AppColorSwatchChip(colour: Color(UIColor(hex: darkHex) ?? .black), size: 18)
            AppColorSwatchChip(colour: appColors.wood.tones.wood, size: 18)
            AppColorSwatchChip(colour: appColors.accent.tones.accent, size: 18)
        }
        .accessibilityHidden(true)
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
