import SwiftUI

/// App colors' Wood and Accent (design `b2-colors`, approved 2026-10-24): the wood the World's
/// navigation is made of (the title plates, the item bar, the sheets' grabbers) and the accent its
/// buttons, switches and selected chips wear. Paper is the other half of the page and keeps today's
/// stored backgrounds (``FernletThemeDefaults``).
///
/// **Storage.** Two device-only `UserDefaults` keys holding a case's raw value, so the raw values are
/// frozen tokens (never renamed, never localized; a value no case knows reads as the default). They
/// are appearance preferences, kept by Delete everything with the other appearance keys
/// (`Docs/PrivacyWipeCoverage.md`, "Appearance and tool preferences"). Every read and write of the two
/// keys is in this file, so the wipe wall resolves them to their literals.
///
/// **Redrawing.** ``WorldPalette``'s wood and accent tokens read the stored choice, and
/// `worldDesignLanguage()` hands it down as ``EnvironmentValues/worldAppColors`` from `@AppStorage`, so
/// a pick rebuilds the framed look at once; a view drawing wood or accent straight from
/// ``WorldPalette`` that stays on screen (a panel's plate, the item bar) reads the environment value,
/// which redraws it too.
nonisolated enum WorldAppColors {
    /// The frozen `UserDefaults` keys (tokens; never localized, never renamed).
    static let woodKey = "fernlet.world.appColors.wood"
    static let accentKey = "fernlet.world.appColors.accent"

    /// The chosen wood (Oak, today's wood, until the person picks another).
    static func wood(in defaults: UserDefaults = .standard) -> WorldWood {
        defaults.string(forKey: woodKey).flatMap(WorldWood.init(rawValue:)) ?? .oak
    }

    /// The chosen accent (Moss, today's accent, until the person picks another).
    static func accent(in defaults: UserDefaults = .standard) -> WorldAccent {
        defaults.string(forKey: accentKey).flatMap(WorldAccent.init(rawValue:)) ?? .moss
    }

    /// Both choices.
    static func current(in defaults: UserDefaults = .standard) -> WorldAppColorChoice {
        WorldAppColorChoice(wood: wood(in: defaults), accent: accent(in: defaults))
    }

    /// Stores a wood (App colors' Wood row).
    static func setWood(_ wood: WorldWood, in defaults: UserDefaults = .standard) {
        defaults.set(wood.rawValue, forKey: woodKey)
    }

    /// Stores an accent (App colors' Accent row).
    static func setAccent(_ accent: WorldAccent, in defaults: UserDefaults = .standard) {
        defaults.set(accent.rawValue, forKey: accentKey)
    }
}

/// One App colors choice: a wood and an accent.
nonisolated struct WorldAppColorChoice: Equatable, Sendable {
    var wood: WorldWood = .oak
    var accent: WorldAccent = .moss
}

/// A wood for the World's navigation (`b2-colors`, "Wood"). Every label on it clears 4.5:1: dark bark
/// on Oak, Birch and Cherry, cream on Walnut. The raw values are stored (frozen tokens).
nonisolated enum WorldWood: String, CaseIterable, Identifiable, Sendable {
    case oak, birch, cherry, walnut

    var id: String { rawValue }

    /// The wood's name under its swatch.
    var name: LocalizedStringResource {
        switch self {
        case .oak: LocalizedStringResource("appColors.wood.oak", defaultValue: "Oak", comment: "App colors: a wood for the title plates and the item bar (today's wood)")
        case .birch: LocalizedStringResource("appColors.wood.birch", defaultValue: "Birch", comment: "App colors: a pale wood for the title plates and the item bar")
        case .cherry: LocalizedStringResource("appColors.wood.cherry", defaultValue: "Cherry", comment: "App colors: a reddish wood for the title plates and the item bar")
        case .walnut: LocalizedStringResource("appColors.wood.walnut", defaultValue: "Walnut", comment: "App colors: a dark wood for the title plates and the item bar")
        }
    }

    /// The swatch the design draws for it (its light-mode face).
    var swatch: Color {
        switch self {
        case .oak: WorldPalette.rgb(0xD9A56E)
        case .birch: WorldPalette.rgb(0xE8D3A6)
        case .cherry: WorldPalette.rgb(0xD9957A)
        case .walnut: WorldPalette.rgb(0x6B4A33)
        }
    }

    /// Its colours in light and dark mode.
    var tones: WorldWoodTones {
        switch self {
        case .oak: .oak
        case .birch: .birch
        case .cherry: .cherry
        case .walnut: .walnut
        }
    }
}

/// One wood's colours: the face, its high and low edges, the item bar's selected slot, and the ink of
/// labels and one-colour icons on it. Built once per wood, so the framed look only changes when the
/// choice does.
nonisolated struct WorldWoodTones: Sendable {
    let wood: Color
    let high: Color
    let low: Color
    let selected: Color
    /// Text on this wood (5:1 or better in both modes).
    let label: Color

    /// Today's wood (the design's own values, unchanged).
    static let oak = WorldWoodTones(
        wood: WorldPalette.adaptive(light: 0xC98E54, dark: 0x6E4424, lightHC: 0xD9A56E, darkHC: 0x5A361B),
        high: WorldPalette.adaptive(light: 0xE0AE74, dark: 0x8A5A32),
        low: WorldPalette.adaptive(light: 0xA86E3C, dark: 0x4E2F17),
        selected: WorldPalette.adaptive(light: 0xDDA86C, dark: 0x8E5C34, lightHC: 0xE9C08E, darkHC: 0x7A4C28),
        label: WorldPalette.bark)
    static let birch = WorldWoodTones(
        wood: WorldPalette.adaptive(light: 0xE2CB98, dark: 0x6E5A38),
        high: WorldPalette.adaptive(light: 0xF0E0BC, dark: 0x8A7450),
        low: WorldPalette.adaptive(light: 0xC2A872, dark: 0x50402A),
        selected: WorldPalette.adaptive(light: 0xEEDCB2, dark: 0x76603E),
        label: WorldPalette.bark)
    static let cherry = WorldWoodTones(
        wood: WorldPalette.adaptive(light: 0xD48A6C, dark: 0x7A3A28),
        high: WorldPalette.adaptive(light: 0xE6A88E, dark: 0x96523C),
        low: WorldPalette.adaptive(light: 0xB26A4E, dark: 0x5A2619),
        selected: WorldPalette.adaptive(light: 0xE2A086, dark: 0x8E4A34),
        label: WorldPalette.bark)
    static let walnut = WorldWoodTones(
        wood: WorldPalette.adaptive(light: 0x6B4A33, dark: 0x4A3222),
        high: WorldPalette.adaptive(light: 0x86603F, dark: 0x634530),
        low: WorldPalette.adaptive(light: 0x4E3423, dark: 0x33221A),
        selected: WorldPalette.adaptive(light: 0x80593D, dark: 0x5E412D),
        label: WorldPalette.adaptive(light: 0xFFF1CF, dark: 0xFFF1CF, lightHC: 0xFFF8E4, darkHC: 0xFFF8E4))
}

/// An accent (`b2-colors`, "Accent") for primary buttons, switches and selected chips. Its text clears
/// 5:1 in both modes: white on the light face, a dark ink on the lighter dark-mode face. The raw values
/// are stored (frozen tokens).
nonisolated enum WorldAccent: String, CaseIterable, Identifiable, Sendable {
    case moss, sea, plum, clay, sun

    var id: String { rawValue }

    /// The accent's name under its swatch.
    var name: LocalizedStringResource {
        switch self {
        case .moss: LocalizedStringResource("appColors.accent.moss", defaultValue: "Moss", comment: "App colors: the green accent for buttons, switches and selected chips (today's accent)")
        case .sea: LocalizedStringResource("appColors.accent.sea", defaultValue: "Sea", comment: "App colors: a blue-green accent for buttons, switches and selected chips")
        case .plum: LocalizedStringResource("appColors.accent.plum", defaultValue: "Plum", comment: "App colors: a purple accent for buttons, switches and selected chips")
        case .clay: LocalizedStringResource("appColors.accent.clay", defaultValue: "Clay", comment: "App colors: a red-brown accent for buttons, switches and selected chips")
        case .sun: LocalizedStringResource("appColors.accent.sun", defaultValue: "Sun", comment: "App colors: a golden accent for buttons, switches and selected chips (the colour, not the day)")
        }
    }

    /// Its colours in light and dark mode.
    var tones: WorldAccentTones {
        switch self {
        case .moss: .moss
        case .sea: .sea
        case .plum: .plum
        case .clay: .clay
        case .sun: .sun
        }
    }
}

/// One accent's colours: the face of primary buttons and selected chips, the text on it, and the
/// switches' on colour (Moss keeps today's lighter moss for switches and section squares).
nonisolated struct WorldAccentTones: Sendable {
    let accent: Color
    let onAccent: Color
    let mark: Color

    /// Today's accent (the design's own values, unchanged).
    static let moss = WorldAccentTones(
        accent: WorldPalette.adaptive(light: 0x46683A, dark: 0x8DBB78),
        onAccent: WorldPalette.adaptive(light: 0xFFFFFF, dark: 0x10170D),
        mark: WorldPalette.moss)
    static let sea = tones(light: 0x2F6577, dark: 0x7FB6C8, darkInk: 0x0B1A20)
    static let plum = tones(light: 0x6E4A78, dark: 0xC2A2CE, darkInk: 0x1E1222)
    static let clay = tones(light: 0x9A4632, dark: 0xE39D86, darkInk: 0x2A120B)
    static let sun = tones(light: 0x7E5B10, dark: 0xE2BC62, darkInk: 0x221804)

    /// An accent whose switches wear the accent itself.
    private static func tones(light: UInt32, dark: UInt32, darkInk: UInt32) -> WorldAccentTones {
        let face = WorldPalette.adaptive(light: light, dark: dark)
        return WorldAccentTones(accent: face, onAccent: WorldPalette.adaptive(light: 0xFFFFFF, dark: darkInk), mark: face)
    }
}

extension EnvironmentValues {
    /// The App colors choice in use, set by `worldDesignLanguage()` from the stored keys. A view that
    /// draws wood or accent from ``WorldPalette`` and stays on screen reads it, so a pick redraws it.
    @Entry var worldAppColors = WorldAppColorChoice()
}

/// Reads the stored App colors choice and hands it down (``EnvironmentValues/worldAppColors``); part of
/// `worldDesignLanguage()`. `@AppStorage`, so a pick on the App colors page redraws everything below.
struct WorldAppColorsSource: ViewModifier {
    @AppStorage(WorldAppColors.woodKey) private var wood = WorldWood.oak.rawValue
    @AppStorage(WorldAppColors.accentKey) private var accent = WorldAccent.moss.rawValue

    func body(content: Content) -> some View {
        content.environment(\.worldAppColors, WorldAppColorChoice(wood: WorldWood(rawValue: wood) ?? .oak,
                                                                  accent: WorldAccent(rawValue: accent) ?? .moss))
    }
}
