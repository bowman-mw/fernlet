import Foundation

/// The silly-stat stamps as pixel art, for the World's stamp banner (designs `b1-stamp-banner` and
/// `b2-stamp-art`, approved 2026-10-23 and 2026-10-24). All nineteen are drawn. The duck, the tooth and
/// the moon gained ink outlines in `b2-stamp-art` so they read on the banner's gold disc; the cookie, the
/// leaf and the heart are the World's own sprites.
enum WorldStampArt {
    static let cup = WorldSprite(rows: [".s.s....", "s.s.....", "kkkkkk..", "kwwwwkkk", "kwwwwk.k", "kwwwwkkk", ".kkkk..."],
                                 palette: ["k": 0x4A2E1C, "s": 0x9FB6C4, "w": 0xFFF1D6])
    static let pizza = WorldSprite(rows: ["kkkkkkkk", "kyryyyrk", ".kyyryk.", ".kyyyyk.", "..kryk..", "..kyyk..", "...kk..."],
                                   palette: ["k": 0x4A2E1C, "r": 0xC8553D, "y": 0xF2C14E])
    static let note = WorldSprite(rows: ["...kkkk", "...kkkk", "...k..k", "...k..k", ".kkk.kk", "kkkkkkk", ".kk.kk."],
                                  palette: ["k": 0x4A2E1C])
    static let duck = WorldSprite(rows: ["....kkk...", "...kyyyk..", "..kyykyok.", ".kkyyyyook", "kykyyyykk.", "kyyyyyyyk.", ".kyyyyyyk.", "..kbbbbb.."],
                                  palette: ["b": 0x5FB8D9, "k": 0x4A2E1C, "o": 0xE5822F, "y": 0xF2C14E])
    static let tooth = WorldSprite(rows: ["..kkkk..", ".kwwwwk.", "kwwwwwwk", "kwwwwwwk", "kwwkkwwk", "kwk..kwk", "kwk..kwk", ".k....k."],
                                   palette: ["k": 0x4A2E1C, "w": 0xFFFDF8])
    static let moon = WorldSprite(rows: ["...kkk..", "..kmmmk.", ".kmmkk..", "kmmk....", "kmmk....", "kmmk....", ".kmmkk..", "..kmmmk.", "...kkk.."],
                                  palette: ["k": 0x4A2E1C, "m": 0x8E9BB0])
    static let egg = WorldSprite(rows: [".kkkkk..", "kwwwwwk.", "kwwyywwk", "kwyyyywk", "kwwyywwk", ".kwwwwwk", "..kkkkk."],
                                 palette: ["k": 0x4A2E1C, "w": 0xFFFDF8, "y": 0xF2C14E])
    static let bowl = WorldSprite(rows: ["..s.s.s.", ".s.s.s..", "kkkkkkkk", "kffgfffk", ".kbbbbk.", "..kkkk.."],
                                  palette: ["b": 0xC8553D, "f": 0xE6B566, "g": 0x7FA545, "k": 0x4A2E1C, "s": 0x9FB6C4])
    static let weight = WorldSprite(rows: ["..kkkk..", ".k....k.", ".k....k.", "kkkkkkkk", "kmmmmmmk", "kmhmmmmk", "kmmmmmmk", ".kkkkkk."],
                                    palette: ["h": 0xA9B6C0, "k": 0x4A2E1C, "m": 0x71808C])
    static let stairs = WorldSprite(rows: [".....kkk", ".....kwk", "...kkkwk", "...kwwwk", ".kkkwwwk", ".kwwwwwk", "kkkkkkkk"],
                                    palette: ["k": 0x4A2E1C, "w": 0xD9A56E])
    static let film = WorldSprite(rows: ["kkkkkkkk", "kwkwkwkk", "kkkkkkkk", "kddddddk", "kdwwwwdk", "kddddddk", "kkkkkkkk"],
                                  palette: ["d": 0x5A5550, "k": 0x4A2E1C, "w": 0xFFFDF8])
    static let bug = WorldSprite(rows: [".k.k.k.k.", "kkkkkkkkk", "kgkgggggk", "kgggggggk", "kkkkkkkkk", ".k.k.k.k."],
                                 palette: ["g": 0x9FC58D, "k": 0x4A2E1C])
    static let banana = WorldSprite(rows: ["......kk", ".....kyk", "....kyyk", "k..kyyk.", "kkkyyyk.", ".kyyyk..", "..kkk..."],
                                    palette: ["k": 0x4A2E1C, "y": 0xF2C14E])
    static let wheel = WorldSprite(rows: ["..kkkk..", ".k.kk.k.", "k..kk..k", "kkkkkkkk", "k..kk..k", ".k.kk.k.", "..kkkk..", "b.bb.bb."],
                                   palette: ["b": 0x5FB8D9, "k": 0x4A2E1C])
    static let skull = WorldSprite(rows: [".kkkkkk.", "kwwwwwwk", "kwkwwkwk", "kwkwwkwk", "kwwwwwwk", ".kkwwkk.", "..kwwk..", "..kkkk.."],
                                   palette: ["k": 0x4A2E1C, "w": 0xFFFDF8])
    static let floss = WorldSprite(rows: ["..kkkkk.", ".kmmmmmk", ".kmwwwmk", ".kmmmmmk", ".kkkkkkk", "...k....", "....k...", ".....k.."],
                                   palette: ["k": 0x4A2E1C, "m": 0x9FC58D, "w": 0xFFFDF8])

    /// The stamp's pixel art.
    static func sprite(for kind: SillyStatKind) -> WorldSprite {
        switch kind {
        case .cookiesPerDay: WorldSprites.cookie
        case .bananasForScale: banana
        case .eggonomics: egg
        case .pizzaPieChart: pizza
        case .bathtubIndex: duck
        case .coffeeTower: cup
        case .signatureDish: bowl
        case .totalTonnage: weight
        case .moonwalk: moon
        case .stairwayToSomewhere: stairs
        case .grandTours: wheel
        case .shakespeareSteps: skull
        case .koalaDays: WorldSprites.leaf
        case .dreamCinema: film
        case .flossRope: floss
        case .brushMarathon: tooth
        case .showerConcerts: note
        case .patsGiven: WorldSprites.heartSm
        case .gastrotrichLifetimes: bug
        }
    }
}
