// WidgetStampArt.swift
// FernletWidgets
//
// The nineteen silly-stat stamps for the stamp widget (World Review Batch 4, `b4-new-stamp`): each
// stamp's frozen token, its name and its pixel art. Hand-copied twins of the app's `SillyStatKind`
// tokens, `SillyStampCopy.name(for:)` and `WorldStampArt` (the extension links nothing of the app's);
// `WidgetWorldTwinTests` pins the tokens, the names and every row of art against the app's.

import Foundation

/// A silly-stat stamp the widget knows: the twin of the app's `SillyStatKind`.
///
/// The raw values are the app's FROZEN tokens — what the snapshot's `StampMoment.kindRaw` carries.
/// They are never shown or spoken; ``displayName`` is the display fork. An unknown token (a stat a
/// newer app added) has no case here, so the widget skips it rather than draw a nameless stamp.
enum WidgetStampKind: String, CaseIterable {
    case cookiesPerDay
    case bananasForScale
    case eggonomics
    case pizzaPieChart
    case bathtubIndex
    case coffeeTower
    case signatureDish
    case totalTonnage
    case moonwalk
    case stairwayToSomewhere
    case grandTours
    case shakespeareSteps
    case koalaDays
    case dreamCinema
    case flossRope
    case brushMarathon
    case showerConcerts
    case patsGiven
    case gastrotrichLifetimes

    /// The stamp's name — the app's own wording, keyed by the English name as the app's catalog is.
    var displayName: String {
        switch self {
        case .cookiesPerDay: String(localized: "Crumb Goblin", comment: "Silly stats stamp name, earned when Cookies Per Day first appears")
        case .bananasForScale: String(localized: "Top Banana", comment: "Silly stats stamp name, earned when Bananas for Scale first appears")
        case .eggonomics: String(localized: "Sunny Side Up", comment: "Silly stats stamp name, earned when Egg-onomics first appears")
        case .pizzaPieChart: String(localized: "Slice of Life", comment: "Silly stats stamp name, earned when Pizza Pie Chart first appears")
        case .bathtubIndex: String(localized: "Rubber Duck", comment: "Silly stats stamp name, earned when Bathtub Index (water drunk) first appears")
        case .coffeeTower: String(localized: "Bean Counter", comment: "Silly stats stamp name, earned when Coffee Tower first appears")
        case .signatureDish: String(localized: "House Special", comment: "Silly stats stamp name, earned when a homemade recipe becomes the Signature Dish")
        case .totalTonnage: String(localized: "Piano Mover", comment: "Silly stats stamp name, earned when Total Tonnage (weight lifted) first appears")
        case .moonwalk: String(localized: "Small Step", comment: "Silly stats stamp name, earned when the walk to the Moon first appears")
        case .stairwayToSomewhere: String(localized: "Up and Up", comment: "Silly stats stamp name, earned when Stairway to Somewhere first appears")
        case .grandTours: String(localized: "Wheels and Waves", comment: "Silly stats stamp name, earned when Grand Tours (swims and rides) first appears")
        case .shakespeareSteps: String(localized: "To Step or Not to Step", comment: "Silly stats stamp name, earned when steps reach one Hamlet; a play on Hamlet's famous line")
        case .koalaDays: String(localized: "Eucalyptus Dreams", comment: "Silly stats stamp name, earned when Koala Days (sleep) first appears")
        case .dreamCinema: String(localized: "Opening Night", comment: "Silly stats stamp name, earned when Dream Cinema (dream sleep) first appears")
        case .flossRope: String(localized: "Floss Boss", comment: "Silly stats stamp name, earned when Floss Rope first appears")
        case .brushMarathon: String(localized: "Starting Line", comment: "Silly stats stamp name, earned when Brush Marathon first appears")
        case .showerConcerts: String(localized: "Encore", comment: "Silly stats stamp name, earned when Shower Concerts first appears")
        case .patsGiven: String(localized: "Good Bean", comment: "Silly stats stamp name, earned the first time the companion is petted; 'good bean' is an affectionate nickname")
        case .gastrotrichLifetimes: String(localized: "Outlived a Gastrotrich", comment: "Silly stats stamp name, earned after three days together; a gastrotrich is a tiny creature that lives about three days")
        }
    }

    /// The stamp's pixel art: the app's `WorldStampArt.sprite(for:)`, case for case.
    var sprite: WidgetSprite {
        switch self {
        case .cookiesPerDay: WidgetStampArt.cookie
        case .bananasForScale: WidgetStampArt.banana
        case .eggonomics: WidgetStampArt.egg
        case .pizzaPieChart: WidgetStampArt.pizza
        case .bathtubIndex: WidgetStampArt.duck
        case .coffeeTower: WidgetStampArt.cup
        case .signatureDish: WidgetStampArt.bowl
        case .totalTonnage: WidgetStampArt.weight
        case .moonwalk: WidgetStampArt.moon
        case .stairwayToSomewhere: WidgetStampArt.stairs
        case .grandTours: WidgetStampArt.wheel
        case .shakespeareSteps: WidgetStampArt.skull
        case .koalaDays: WidgetStampArt.leaf
        case .dreamCinema: WidgetStampArt.film
        case .flossRope: WidgetStampArt.floss
        case .brushMarathon: WidgetStampArt.tooth
        case .showerConcerts: WidgetStampArt.note
        case .patsGiven: WidgetStampArt.heartSm
        case .gastrotrichLifetimes: WidgetStampArt.bug
        }
    }
}

/// The stamps' pixel art: the twins of the app's `WorldStampArt` (and the three World sprites it
/// borrows: the cookie, the leaf and the small heart).
enum WidgetStampArt {
    static let cup = WidgetSprite(rows: [".s.s....", "s.s.....", "kkkkkk..", "kwwwwkkk", "kwwwwk.k", "kwwwwkkk", ".kkkk..."],
                                  palette: ["k": 0x4A2E1C, "s": 0x9FB6C4, "w": 0xFFF1D6])
    static let pizza = WidgetSprite(rows: ["kkkkkkkk", "kyryyyrk", ".kyyryk.", ".kyyyyk.", "..kryk..", "..kyyk..", "...kk..."],
                                    palette: ["k": 0x4A2E1C, "r": 0xC8553D, "y": 0xF2C14E])
    static let note = WidgetSprite(rows: ["...kkkk", "...kkkk", "...k..k", "...k..k", ".kkk.kk", "kkkkkkk", ".kk.kk."],
                                   palette: ["k": 0x4A2E1C])
    static let duck = WidgetSprite(rows: ["....kkk...", "...kyyyk..", "..kyykyok.", ".kkyyyyook", "kykyyyykk.", "kyyyyyyyk.", ".kyyyyyyk.", "..kbbbbb.."],
                                   palette: ["b": 0x5FB8D9, "k": 0x4A2E1C, "o": 0xE5822F, "y": 0xF2C14E])
    static let tooth = WidgetSprite(rows: ["..kkkk..", ".kwwwwk.", "kwwwwwwk", "kwwwwwwk", "kwwkkwwk", "kwk..kwk", "kwk..kwk", ".k....k."],
                                    palette: ["k": 0x4A2E1C, "w": 0xFFFDF8])
    static let moon = WidgetSprite(rows: ["...kkk..", "..kmmmk.", ".kmmkk..", "kmmk....", "kmmk....", "kmmk....", ".kmmkk..", "..kmmmk.", "...kkk.."],
                                   palette: ["k": 0x4A2E1C, "m": 0x8E9BB0])
    static let egg = WidgetSprite(rows: [".kkkkk..", "kwwwwwk.", "kwwyywwk", "kwyyyywk", "kwwyywwk", ".kwwwwwk", "..kkkkk."],
                                  palette: ["k": 0x4A2E1C, "w": 0xFFFDF8, "y": 0xF2C14E])
    static let bowl = WidgetSprite(rows: ["..s.s.s.", ".s.s.s..", "kkkkkkkk", "kffgfffk", ".kbbbbk.", "..kkkk.."],
                                   palette: ["b": 0xC8553D, "f": 0xE6B566, "g": 0x7FA545, "k": 0x4A2E1C, "s": 0x9FB6C4])
    static let weight = WidgetSprite(rows: ["..kkkk..", ".k....k.", ".k....k.", "kkkkkkkk", "kmmmmmmk", "kmhmmmmk", "kmmmmmmk", ".kkkkkk."],
                                     palette: ["h": 0xA9B6C0, "k": 0x4A2E1C, "m": 0x71808C])
    static let stairs = WidgetSprite(rows: [".....kkk", ".....kwk", "...kkkwk", "...kwwwk", ".kkkwwwk", ".kwwwwwk", "kkkkkkkk"],
                                     palette: ["k": 0x4A2E1C, "w": 0xD9A56E])
    static let film = WidgetSprite(rows: ["kkkkkkkk", "kwkwkwkk", "kkkkkkkk", "kddddddk", "kdwwwwdk", "kddddddk", "kkkkkkkk"],
                                   palette: ["d": 0x5A5550, "k": 0x4A2E1C, "w": 0xFFFDF8])
    static let bug = WidgetSprite(rows: [".k.k.k.k.", "kkkkkkkkk", "kgkgggggk", "kgggggggk", "kkkkkkkkk", ".k.k.k.k."],
                                  palette: ["g": 0x9FC58D, "k": 0x4A2E1C])
    static let banana = WidgetSprite(rows: ["......kk", ".....kyk", "....kyyk", "k..kyyk.", "kkkyyyk.", ".kyyyk..", "..kkk..."],
                                     palette: ["k": 0x4A2E1C, "y": 0xF2C14E])
    static let wheel = WidgetSprite(rows: ["..kkkk..", ".k.kk.k.", "k..kk..k", "kkkkkkkk", "k..kk..k", ".k.kk.k.", "..kkkk..", "b.bb.bb."],
                                    palette: ["b": 0x5FB8D9, "k": 0x4A2E1C])
    static let skull = WidgetSprite(rows: [".kkkkkk.", "kwwwwwwk", "kwkwwkwk", "kwkwwkwk", "kwwwwwwk", ".kkwwkk.", "..kwwk..", "..kkkk.."],
                                    palette: ["k": 0x4A2E1C, "w": 0xFFFDF8])
    static let floss = WidgetSprite(rows: ["..kkkkk.", ".kmmmmmk", ".kmwwwmk", ".kmmmmmk", ".kkkkkkk", "...k....", "....k...", ".....k.."],
                                    palette: ["k": 0x4A2E1C, "m": 0x9FC58D, "w": 0xFFFDF8])
    /// The World's cookie (`WorldSprites.cookie`), the Crumb Goblin's stamp.
    static let cookie = WidgetSprite(rows: ["..kkkk..", ".kccdck.", "kcccccck", "kcdcccck", "kccccdck", "kcdcccck", ".kcccck.", "..kkkk.."],
                                     palette: ["c": 0xD9A05B, "d": 0x5A3A22, "k": 0x4A2E1C])
    /// The World's leaf (`WorldSprites.leaf`), Eucalyptus Dreams' stamp.
    static let leaf = WidgetSprite(rows: ["....ggg", "..ggggg", ".gggdgg", ".ggdggg", "gdggg..", "d......"],
                                   palette: ["d": 0x4E7A48, "g": 0x72A364])
    /// The World's small heart (`WorldSprites.heartSm`), Good Bean's stamp.
    static let heartSm = WidgetSprite(rows: [".kk.kk.", "kRRkRRk", "kRRRRRk", ".kRRRk.", "..kRk..", "...k..."],
                                      palette: ["R": 0xE5532F, "k": 0x4A2E1C])
}
