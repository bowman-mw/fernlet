import Foundation
import WorldMapStore

/// The pixel art inside the passport's stamps (World-Exploration-Spec §3, the mockup's `OCEAN`, `SEAWAVES` and
/// `SPECIAL` tables): each ocean's hand-drawn sign, the seas' waves, the two full-colour specials, and each
/// continent's silhouette, rasterised from the bundled atlas as the mockup's `silhouette()` rasterises its outlines.
/// Rows are top first; `true` is ink.
nonisolated enum PassportStampArt {
    /// `rows` of `k` (ink) and `.` (clear) as ink flags.
    static func pixels(_ rows: [String]) -> [[Bool]] {
        rows.map { row in row.map { $0 == "k" } }
    }

    /// The ocean's sign, 12 × 12: a whale's tail, a sailboat, a turtle, an iceberg, the north star, each over waves.
    static func oceanSign(_ ocean: AtlasOcean) -> [[Bool]] {
        switch ocean {
        case .pacific: pixels(["............", "..k......k..", ".kk......kk.", ".kkk....kkk.", "..kkk..kkk..",
                               "....kkkk....", ".....kk.....", ".....kk.....", "............", "k.kk.kk.kk.k",
                               ".k..k..k..k.", "............"])
        case .atlantic: pixels([".....k......", ".....kk.....", ".....kkk....", ".....kkkk...", ".....kkkkk..",
                                ".....k......", "..kkkkkkkk..", "...kkkkkk...", "............", "k.kk.kk.kk.k",
                                ".k..k..k..k.", "............"])
        case .indian: pixels(["............", "....kkkk....", "...k.kk.k...", "kk.kkkkkk.kk", "...k.kk.k...",
                              "....kkkk....", "..kk....kk..", "............", "............", "k.kk.kk.kk.k",
                              ".k..k..k..k.", "............"])
        case .southern: pixels(["............", ".....kk.....", "....k..k....", "...k....kk..", "..k.......k.",
                                "..kkkkkkkkk.", "............", "k.kk.kk.kk.k", ".k..k..k..k.", "...k.....k..",
                                "....kkkkk...", "............"])
        case .arctic: pixels(["......k.....", "......k.....", "....k.k.k...", ".....kkk....", "..kkkkkkkkk.",
                              ".....kkk....", "....k.k.k...", "......k.....", "............", ".kkkkkkkkkk.",
                              "k..........k", "............"])
        }
    }

    /// A sea's waves, 12 × 12 (every sea's stamp is the same hexagon; its name sits below it).
    static let seaWaves = pixels(["............", "............", "k.kk.kk.kk.k", ".k..k..k..k.", "............",
                                  "k.kk.kk.kk.k", ".k..k..k..k.", "............", "k.kk.kk.kk.k", ".k..k..k..k.",
                                  "............", "............"])

    /// The colour a not-yet-earned special is drawn in, every pixel.
    static let specialGrey: UInt32 = 0xCDBFA3

    /// One of the two specials (all seven continents, all five oceans): the only full-colour stamps, 18 × 18.
    /// Each pixel is a palette colour or nil (clear).
    static func special(allOceans: Bool) -> [[UInt32?]] {
        allOceans ? spritePixels(oceansSpecial, palette: oceansPalette)
            : spritePixels(continentsSpecial, palette: continentsPalette)
    }

    /// The continents special's rows (the mockup's `SPECIAL.continents`): a gold ring round a little globe.
    private static let continentsSpecial = [
        "......gggggg......", "....gg......gg....", "...g..bbbbbb..g...", "..g.bbllbbbbbb.g..", ".g.bbllllbbllbb.g.",
        ".g.bblllbbbllbb.g.", "g.bbbbllbbbblllb.g", "g.bbbbbbbbbbllbb.g", "g.bblllbbbbbbbbb.g", "g.bbllllbbbllbbb.g",
        ".g.bbllbbbbllbb.g.", ".g.bbbbbbbbbbbb.g.", "..g.bbbbbbbbbb.g..", "...g..bbbbbb..g...", "....gg......gg....",
        "......gggggg......", "....rr......rr....", "...rrr......rrr..."
    ]
    /// The continents special's colours.
    private static let continentsPalette: [Character: UInt32] = ["g": 0xD9A92E, "b": 0x5FA8D6, "l": 0x6FB35A,
                                                                 "r": 0xB5523B]
    /// The oceans special's rows (the mockup's `SPECIAL.oceans`): a compass rose over waves.
    private static let oceansSpecial = [
        "........y.........", "........y.........", ".......yyy........", "....gggyyyggg.....", "...g...yyy...g....",
        "..g.....y.....g...", ".g.....www.....g..", ".g....wbbbw....g..", "g....wbbbbbw....g.", "gyyyywbbbbbwyyyyg.",
        "g....wbbbbbw....g.", ".g....wbbbw....g..", ".g.....www.....g..", "..g.....y.....g...", "...g...bbb...g....",
        "....gggbbbggg.....", ".b.b.b.b.b.b.b.b..", "b.b.b.b.b.b.b.b.b."
    ]
    /// The oceans special's colours.
    private static let oceansPalette: [Character: UInt32] = ["g": 0xD9A92E, "y": 0xF2C14E, "w": 0xFFF6E2,
                                                             "b": 0x3E86C4]

    /// `rows` with each letter looked up in `palette` (anything else clear).
    private static func spritePixels(_ rows: [String], palette: [Character: UInt32]) -> [[UInt32?]] {
        rows.map { row in row.map { palette[$0] } }
    }

    // MARK: Silhouettes

    /// The most pixels across a silhouette (the stamps draw 22, Antarctica 18).
    static let maxSilhouetteWidth = 48

    /// `continent`'s silhouette, `width` pixels across, from the bundled atlas: a pixel is ink where the atlas puts
    /// that continent's land under the pixel's centre, over the continent's box (the mockup's `silhouette()`, which
    /// samples its outlines the same way). Antarctica is drawn round the South Pole, out to 60°S. Bounded: at most
    /// ``maxSilhouetteWidth`` squared samples, one atlas lookup each.
    static func silhouette(_ continent: AtlasContinent, width: Int, atlas: WorldAtlas) -> [[Bool]] {
        let width = min(max(width, 1), maxSilhouetteWidth)
        guard let box = continent.silhouetteBox else { return polarSilhouette(width: width, atlas: atlas) }
        let height = min(maxSilhouetteWidth,
                         max(6, Int((Double(width) * (box.north - box.south) / (box.east - box.west)).rounded())))
        return (0..<height).map { row in
            (0..<width).map { col in
                let longitude = box.west + (Double(col) + 0.5) / Double(width) * (box.east - box.west)
                let latitude = box.north - (Double(row) + 0.5) / Double(height) * (box.north - box.south)
                return atlas.continent(at: GeoPoint(latitude, longitude)) == continent
            }
        }
    }

    /// Antarctica round the pole: each pixel's distance from the centre is degrees from 90°S (30 at the edge), its
    /// angle the longitude, as the mockup draws it.
    private static func polarSilhouette(width: Int, atlas: WorldAtlas) -> [[Bool]] {
        let half = Double(width) / 2
        return (0..<width).map { row in
            (0..<width).map { col in
                let dx = (Double(col) + 0.5 - half) / half, dy = (Double(row) + 0.5 - half) / half
                let radius = (dx * dx + dy * dy).squareRoot() * 30
                guard radius < 30 else { return false }
                let longitude = atan2(dy, dx) * 180 / .pi
                return atlas.isLand(at: GeoPoint(-90 + radius, longitude))
            }
        }
    }
}
