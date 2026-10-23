import Foundation

/// The silly-stat stamps as pixel art, for the World's stamp banner (designs `b1-stamp-banner` and
/// `b1-stamp-book`, approved 2026-10-23). The design draws nine of the nineteen stamps; the other ten
/// wear its plain ring until their pixel art is drawn and approved, so a new stamp never shows a blank.
enum WorldStampArt {
    static let cup = WorldSprite(rows: [".s.s....", "s.s.....", "kkkkkk..", "kwwwwkkk", "kwwwwk.k", "kwwwwkkk", ".kkkk..."],
                                 palette: ["k": 0x4A2E1C, "s": 0x9FB6C4, "w": 0xFFF1D6])
    static let pizza = WorldSprite(rows: ["kkkkkkkk", "kyryyyrk", ".kyyryk.", ".kyyyyk.", "..kryk..", "..kyyk..", "...kk..."],
                                   palette: ["k": 0x4A2E1C, "r": 0xC8553D, "y": 0xF2C14E])
    static let duck = WorldSprite(rows: ["...yyy..", "..yykyo.", "..yyyyoo", "y.yyyy..", "yyyyyyy.", ".yyyyyy.", "..bbbbb."],
                                  palette: ["b": 0x5FB8D9, "k": 0x4A2E1C, "o": 0xE5822F, "y": 0xF2C14E])
    static let moon = WorldSprite(rows: ["..mmm.", ".mm...", "mm....", "mm....", "mm....", ".mm...", "..mmm."],
                                  palette: ["m": 0x8E9BB0])
    static let tooth = WorldSprite(rows: [".wwww.", "wwwwww", "wwwwww", "ww..ww", "w....w", "w....w"],
                                   palette: ["w": 0xFFFDF8])
    static let note = WorldSprite(rows: ["...kkkk", "...kkkk", "...k..k", "...k..k", ".kkk.kk", "kkkkkkk", ".kk.kk."],
                                  palette: ["k": 0x4A2E1C])
    /// The design's plain ring, for a stamp whose own art is not drawn yet.
    static let ring = WorldSprite(rows: ["..kk..", ".k..k.", "k....k", "k....k", ".k..k.", "..kk.."],
                                  palette: ["k": 0x4A2E1C])

    /// The stamp's pixel art, or the ring when the design has not drawn it yet.
    static func sprite(for kind: SillyStatKind) -> WorldSprite {
        switch kind {
        case .cookiesPerDay: WorldSprites.cookie
        case .pizzaPieChart: pizza
        case .coffeeTower: cup
        case .bathtubIndex: duck
        case .moonwalk: moon
        case .koalaDays: WorldSprites.leaf
        case .brushMarathon: tooth
        case .showerConcerts: note
        case .patsGiven: WorldSprites.heartSm
        case .bananasForScale, .eggonomics, .signatureDish, .totalTonnage, .stairwayToSomewhere, .grandTours,
             .shakespeareSteps, .dreamCinema, .flossRope, .gastrotrichLifetimes:
            ring
        }
    }
}
