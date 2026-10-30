import Foundation
import WorldMapStore

/// Each terrain set's and season's colours over the approved nature fog's (the mockup's `BIO[set].pal`, then
/// `SEASON[season].pal` for the temperate sets, as `palFor` lays them): light values, before Dark Mode's mix.
/// The meadow and forest in summer override nothing, so they are exactly the approved palette.
nonisolated enum TerrainPalettes {
    /// The light colours `look` paints over the approved ones.
    static func overrides(_ look: TerrainLook) -> [NaturePaint: UInt32] {
        var values = set(look.set)
        if look.set.hasSeasons {
            for (paint, value) in season(look.season) { values[paint] = value }
        }
        return values
    }

    /// The set's own ground, edge, seam and speck colours, and its blades and rocks where they differ.
    static func set(_ set: TerrainSet) -> [NaturePaint: UInt32] {
        switch set {
        case .meadow, .forest: [:]
        case .tropical:
            ground(0x6FAE57, 0x62A34C, 0x79B862, edge: 0x93C77C, woods: 0x5A9A47, long: 0x4F8F3E, seam: 0x5C9A49, speck: 0x5E9B4A)
                .merging(blades(0x2F6B2E, 0x46913F, 0x6BB35A, 0x8FCB71)) { $1 }
                .merging([.petalPink: 0xF26B8A, .petalYellow: 0xF7B731, .petalWhite: 0xFFFFFF, .petalLilac: 0xE25B3F]) { $1 }
        case .boreal:
            ground(0x7FA36A, 0x74985F, 0x89AD73, edge: 0xA4C08E, woods: 0x6E9259, long: 0x6E9259, seam: 0x6A8E56, speck: 0x6A8E56)
        case .desert:
            ground(0xE3C98F, 0xDDBF82, 0xE8D09B, edge: 0xEEDDB0, woods: 0xDDBF82, long: 0xD8BC7C, seam: 0xCBAE70, speck: 0xC9A866)
                .merging(blades(0x8E7B42, 0xA8954F, 0xC2AE67, 0xD6C584)) { $1 }
                .merging([.rockDark: 0x7A6248, .rock: 0xB08E6A, .rockLight: 0xCFB08A, .rockHighlight: 0xE6CFAA]) { $1 }
        case .mountain:
            ground(0xA8A39A, 0x9E998F, 0xB2ADA3, edge: 0xC7C2B8, woods: 0x9E998F, long: 0x9AA083, seam: 0x8F8A80, speck: 0x8A857C)
                .merging([.bladeDark: 0x5E7A45, .bladeMid: 0x738F55, .bladeLight: 0x8FA86A]) { $1 }
        case .crops:
            ground(0xB7C77A, 0xC9CC86, 0xAFC173, edge: 0xD3DB9F, woods: 0xAFC173, long: 0xAFC173, seam: 0x9EAF68, speck: 0x9EAF68)
        case .urban:
            ground(0xBDB6A8, 0xB4AD9F, 0xC6C0B2, edge: 0xD5D0C4, woods: 0xB4AD9F, long: 0x9DB07A, seam: 0xA39D90, speck: 0xA39D90)
        case .tundra:
            ground(0xB3B58F, 0xA9AC85, 0xBDBF99, edge: 0xCDCFAE, woods: 0xA9AC85, long: 0x9A9D6A, seam: 0x9C9E7A, speck: 0x9C9E7A)
                .merging(blades(0x6E7146, 0x878A57, 0xA2A56E, 0xB9BC86)) { $1 }
        case .ice:
            ground(0xE8F1F5, 0xDDEAF0, 0xF2F7F9, edge: 0xF7FBFC, woods: 0xDDEAF0, long: 0xDDEAF0, seam: 0xBCD3DD, speck: 0xC9DCE4)
        case .water:
            ground(0x6FA8D0, 0x67A0C9, 0x78AFD5, edge: 0x8DBCDC, woods: 0x67A0C9, long: 0x67A0C9, seam: 0x5E95BE, speck: 0x5E95BE)
                .merging([.shore: 0xE3D3A1]) { $1 }
        }
    }

    /// The season's colours for grassland, temperate forest and cropland (summer is the approved one).
    static func season(_ season: AtlasSeason) -> [NaturePaint: UInt32] {
        switch season {
        case .summer: [:]
        case .spring: [.petalPink: 0xF4A6BF, .petalYellow: 0xFFFFFF, .petalWhite: 0xF7D86B, .petalLilac: 0xC9B3F0]
        case .autumn:
            [.grassA: 0xB4B77B, .grassB: 0xAAAE70, .grassC: 0xBDBF86, .woods: 0xA3A46A, .long: 0x9EA266, .speck: 0xC68A3E,
             .leafDark: 0x8E3F1C, .leafMid: 0xC0612A, .leafLight: 0xE0923A, .leafHighlight: 0xF2C14E]
                .merging(blades(0x7E7A3A, 0x9B9449, 0xB9AE5E, 0xD3C47A)) { $1 }
        case .winter:
            ground(0xEEF2F2, 0xE6ECEC, 0xF5F8F8, edge: 0xF8FAFA, woods: 0xE1E8E8, long: 0xD9E2E2, seam: 0xC7D3D3, speck: 0x9FB1A8)
                .merging(blades(0xB8C6C2, 0xCDD8D5, 0xE4ECEA, 0xF5F8F8)) { $1 }
        }
    }

    /// A ground: three greens (`base`), the edge, the woods and long-grass grounds, the seam and the speck.
    private static func ground(_ a: UInt32, _ b: UInt32, _ c: UInt32, edge: UInt32, woods: UInt32, long: UInt32,
                               seam: UInt32, speck: UInt32) -> [NaturePaint: UInt32] {
        [.grassA: a, .grassB: b, .grassC: c, .edge: edge, .woods: woods, .long: long, .seam: seam, .speck: speck]
    }

    /// The four blade tones (`bd`, `bm`, `bl`, `bt`).
    private static func blades(_ dark: UInt32, _ mid: UInt32, _ light: UInt32, _ tip: UInt32) -> [NaturePaint: UInt32] {
        [.bladeDark: dark, .bladeMid: mid, .bladeLight: light, .bladeTip: tip]
    }
}

/// A colour a terrain piece is painted in: one of the palette's roles, or one of the mockup's fixed pixel-art
/// colours (the palm, cactus, peak, roof and bare tree, the sand ripples, scree, lichen, cracks and snow), which
/// Dark Mode mixes 30 % toward the night ground as the mockup's `drawHex` does, or a pair the mockup gives for
/// light and dark (the wave marks).
nonisolated enum NatureInk: Hashable {
    case paint(NaturePaint)
    case fixed(UInt32)
    case pair(light: UInt32, dark: UInt32)

    /// How far Dark Mode mixes a fixed colour toward the night ground.
    static let fixedDarkShare = 0.3
}
