// WidgetPixelArt.swift
// FernletWidgets
//
// The World's pixel icons inside the widgets (World Review Batch 4, approved 2026-10-24): Home's six
// hearts and its water drops, the bottle, the plus on the moss button, the asleep "z", and the empty
// ring of a stamp still to come. The extension links nothing of the app's, so each sprite is a
// hand-copied twin of the app's `WorldSprite` table (App/Fernlet/World/Theme/WorldSprites.swift);
// `WidgetWorldTwinTests` pins every copied row and colour against the app's.

import SwiftUI

/// A pixel sprite: rows of keys (`.` is clear) and each key's colour as `0xRRGGBB` — the widget twin of
/// the app's `WorldSprite`.
struct WidgetSprite: Equatable {
    /// The rows, top to bottom; every row has the same width.
    let rows: [String]
    /// The colour of each key.
    let palette: [Character: UInt32]

    /// Width in sprite pixels.
    var width: Int { rows.first?.count ?? 0 }
    /// Height in sprite pixels.
    var height: Int { rows.count }

    /// The design's ink, the one colour of a one-colour icon.
    static let ink: UInt32 = 0x4A2E1C

    /// Whether every key is the design's ink: such an icon takes the ink token, so it stays visible on
    /// dark paper (the app's `WorldSprite.isMonoInk`).
    var isMonoInk: Bool { palette == ["k": Self.ink] }
}

/// The sprites the widgets draw. Rows and colours are the app's, key for key.
enum WidgetSprites {
    /// Home's heart (`WorldSprites.heart`): one of the six on the status plate.
    static let heart = WidgetSprite(rows: [".kk.kk.", "khRkRRk", "kRRRRRk", ".kRRRk.", "..kRk..", "...k..."],
                                    palette: ["R": 0xE5532F, "h": 0xFFB27A, "k": 0x4A2412])
    /// Home's water drop (`WorldSprites.drop`): one per bottle of the target.
    static let drop = WidgetSprite(rows: ["..k..", ".kBk.", ".kBk.", "kBhBk", "kBBBk", "kBBBk", ".kkk."],
                                   palette: ["B": 0x5FB8D9, "h": 0xD8F2FF, "k": 0x24506A])
    /// The water bottle beside "Water" (`WorldSprites.bottle`, from `b3-water`).
    static let bottle = WidgetSprite(rows: [".kkk.", "..k..", ".kbk.", "kbbbk", "kbbbk", "kbbbk", "kbbbk", "kbbbk", ".kkk."],
                                     palette: ["k": 0x24506A, "b": 0x5FB8D9])
    /// The plus on the moss button and the Lock Screen's water circle (`WorldSprites.plus`).
    static let plus = WidgetSprite(rows: ["..kk..", "..kk..", "kkkkkk", "kkkkkk", "..kk..", "..kk.."],
                                   palette: ["k": 0x4A2E1C])
    /// The asleep companion's "z" (the Batch 4 page's `zee`; no app twin — the map draws no z).
    static let zee = WidgetSprite(rows: ["kkkkk", "...k.", "..k..", ".k...", "kkkkk"],
                                  palette: ["k": 0x4A2E1C])
    /// The empty ring on a stamp still to come (the Batch 4 page's unearned badge).
    static let ring = WidgetSprite(rows: ["..kk..", ".k..k.", "k....k", "k....k", ".k..k.", "..kk.."],
                                   palette: ["k": 0x4A2E1C])
}

/// How full one heart is: the twin of the app's `WorldHeartFill`.
enum WidgetHeartFill: Equatable {
    case full, half, empty, gold
}

/// How a sprite's keys are painted for one use. The full-colour cases are the app's
/// `WorldSpriteVariant`; the one-colour cases are the Batch 4 page's rendering for the Lock Screen and
/// the tinted and clear Home Screens, where iOS recolours everything one tint and only shape carries
/// meaning: an empty heart or drop is its outline, a friend's gold heart has a checked fill.
enum WidgetSpritePaint: Equatable {
    /// As drawn (a one-colour ink icon takes the ink token).
    case plain
    /// A heart of the six, or a friend's gold heart.
    case heart(WidgetHeartFill)
    /// A water drop: full, or its outline alone.
    case drop(full: Bool)
    /// Every key one colour (the white plus on the moss button, the placeholder's ghost).
    case solid(UInt32)
    /// The ink outline (`k`) alone, in one colour: a stamp's art in the one-colour renderings.
    case outline(UInt32)
    /// A heart in one colour: outline, filled or half filled, gold checked.
    case monoHeart(WidgetHeartFill)
    /// A drop in one colour: filled, or its outline alone.
    case monoDrop(full: Bool)

    /// White: what iOS tints in the one-colour renderings.
    static let white: UInt32 = 0xFFFFFF
    /// An empty heart's fill and a half heart's right side (the app's `WorldSpriteVariant`).
    static let emptyHeart: UInt32 = 0x8E5E4A
    /// An empty drop's outline on dark paper (Batch 4 page): the dark blue would vanish there.
    static let darkDropOutline: UInt32 = 0x9FC3D6
    /// The ink token's dark-paper colour, for one-colour ink icons.
    static let darkInk: UInt32 = 0xFFF1CF

    /// The colour key `key` at column `x`, row `y` paints in, or nil to leave it clear.
    func colour(key: Character, x: Int, y: Int, base: UInt32, monoInk: Bool, dark: Bool) -> UInt32? {
        switch self {
        case .plain:
            return monoInk && dark ? Self.darkInk : base
        case .solid(let hex):
            return hex
        case .outline(let hex):
            return key == "k" ? hex : nil
        case .heart(let fill):
            return Self.heartColour(fill, key: key, x: x, base: base)
        case .drop(let full):
            if full { return base }
            guard key == "k" else { return nil }
            return dark ? Self.darkDropOutline : base
        case .monoHeart(let fill):
            return Self.monoHeartColour(fill, key: key, x: x, y: y)
        case .monoDrop(let full):
            return full || key == "k" ? Self.white : nil
        }
    }

    /// A full-colour heart: the app's `WorldSpriteVariant.heart`, key for key.
    private static func heartColour(_ fill: WidgetHeartFill, key: Character, x: Int, base: UInt32) -> UInt32 {
        guard key == "R" || key == "h" else { return base }
        switch fill {
        case .gold: return key == "R" ? 0xF2C14E : 0xFFF0A8
        case .empty: return emptyHeart
        case .half: return x > 3 ? emptyHeart : base
        case .full: return base
        }
    }

    /// A one-colour heart: the outline always; the fill when full (or the left half when half); a
    /// gold heart's fill checked, so it still reads as different in one tint.
    private static func monoHeartColour(_ fill: WidgetHeartFill, key: Character, x: Int, y: Int) -> UInt32? {
        guard key == "R" || key == "h" else { return white }
        switch fill {
        case .full: return white
        case .half: return x <= 3 ? white : nil
        case .empty: return nil
        case .gold: return (x + y) % 2 == 1 ? white : nil
        }
    }
}

/// Draws a ``WidgetSprite`` crisply — each key one `scale`-point square, no smoothing — the widget twin
/// of the app's `WorldSpriteView`. Decoration to VoiceOver: the element around it says what it means.
struct WidgetSpriteView: View {
    let sprite: WidgetSprite
    /// Points per sprite pixel.
    var scale: CGFloat = 3
    var paint: WidgetSpritePaint = .plain
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let monoInk = sprite.isMonoInk
        Canvas { context, _ in
            for (y, row) in sprite.rows.enumerated() {
                for (x, key) in row.enumerated() where key != "." {
                    guard let base = sprite.palette[key],
                          let hex = paint.colour(key: key, x: x, y: y, base: base, monoInk: monoInk, dark: dark) else { continue }
                    let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)
                    context.fill(Path(rect), with: .color(Color(widgetRGB: hex)))
                }
            }
        }
        .frame(width: CGFloat(sprite.width) * scale, height: CGFloat(sprite.height) * scale)
        .accessibilityHidden(true)
    }
}

extension Color {
    /// An opaque sRGB colour from a `0xRRGGBB` literal.
    init(widgetRGB hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
