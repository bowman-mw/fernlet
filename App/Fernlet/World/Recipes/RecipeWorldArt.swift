import Foundation

/// The pixel art the recipe, cooking, planner and recipe-sharing screens draw (World Review Batches 2
/// and 3, approved 2026-10-23/24), copied key for key from the design page's `SPR` table (`kit.js`) as
/// the foundation's own sprites are. One-colour icons use the design's ink alone, so
/// ``WorldSpriteView`` draws them in the ink token and they stay visible on dark paper.
nonisolated extension WorldSprites {
    /// The ink every sprite is outlined in.
    private static let k: UInt32 = 0x4A2E1C

    static let oats = WorldSprite(
        rows: ["...kkkk...", "..kwwwwk..", "...kkkk...", "..kSSSSk..", ".kSSSSSSk.", "kSSSOSSSSk", "kSSOOOSSSk",
               "kSSSOSSSSk", ".kSSSSSSk.", "..kkkkkk.."],
        palette: ["k": k, "w": 0xFFF6E2, "S": 0xD9B77E, "O": 0xF3E2B3])
    static let yogurt = WorldSprite(
        rows: [".kkkkkkk.", "kwwwwwwwk", "kkkkkkkkk", ".kbbbbbk.", ".kwwwwwk.", ".kwwwwwk.", "..kwwwk..", "..kkkkk.."],
        palette: ["k": k, "w": 0xFFFFFF, "b": 0x6F98B6])
    static let berries = WorldSprite(
        rows: ["..g..g..", "...gg...", ".kk..kk.", "kbbkkbbk", "kbhbkhbk", ".kkbbkk.", "..kbhk..", "...kk..."],
        palette: ["k": k, "g": 0x5E844D, "b": 0x4F5FA8, "h": 0x9AA8E0])
    static let wheat = WorldSprite(
        rows: ["...k...", "..kgk..", ".kgkgk.", "..kgk..", ".kgkgk.", "..kgk..", "...k...", "...k...", "...k..."],
        palette: ["k": k, "g": 0xD2973B])
    static let drumstick = WorldSprite(
        rows: ["....kkk..", "...krrrk.", "..krrrrrk", "..krrrrk.", ".kkrrrk..", "kwk.kk...", "kwwk.....", ".kk......"],
        palette: ["k": k, "r": 0xB8543D, "w": 0xFFF6E2])
    static let fatDrop = WorldSprite(
        rows: ["...k...", "..kyk..", ".kyyyk.", "kyyhyyk", "kyyyyyk", "kyyyyyk", ".kyyyk.", "..kkk.."],
        palette: ["k": k, "y": 0xE8C35A, "h": 0xFFF2B0])
    static let onion = WorldSprite(
        rows: ["...k...", "..kpk..", ".kpppk.", "kpwpppk", "kpppppk", ".kpppk.", "..kkk.."],
        palette: ["k": k, "p": 0xC9A0C8, "w": 0xF3E6F2])
    static let garlic = WorldSprite(
        rows: ["...k...", "..kwk..", ".kwwwk.", "kwwkwwk", "kwwkwwk", ".kkkkk."],
        palette: ["k": k, "w": 0xF7F1E3])
    static let egg = WorldSprite(
        rows: [".kkkkk..", "kwwwwwk.", "kwwyywwk", "kwyyyywk", "kwwyywwk", ".kwwwwwk", "..kkkkk."],
        palette: ["k": k, "w": 0xFFFDF8, "y": 0xF2C14E])
    /// The cooking bowl on the wooden Start cooking button.
    static let bowlInk = WorldSprite(
        rows: ["......kk.", ".....k...", "kkkkkkkkk", "kwwwwwwwk", ".kwwwwwk.", "..kkkkk.."],
        palette: ["k": k, "w": 0xF3E2B3])
    static let camera = WorldSprite(
        rows: ["..kkk.....", "kkkkkkkkkk", "kwwwwwwwwk", "kwwkkkwwwk", "kwkbbbkwwk", "kwwkkkwwwk", "kwwwwwwwwk", "kkkkkkkkkk"],
        palette: ["k": k, "w": 0xFFF6E2, "b": 0x6F98B6])
    /// The tray and arrow of Share (owner's draft-1 note on the recipe book: "a different share icon").
    static let share = WorldSprite(
        rows: ["....k....", "...kkk...", "..k.k.k..", "....k....", "....k....", "kk..k..kk", "k.......k", "k.......k", "kkkkkkkkk"],
        palette: ["k": k])
    static let swap = WorldSprite(
        rows: ["......k..", "kkkkkkkk.", "......k..", ".........", "..k......", ".kkkkkkkk", "..k......"],
        palette: ["k": k])
    static let clock = WorldSprite(
        rows: [".kkkkk.", "k..k..k", "k..k..k", "k..kk.k", "k.....k", "k.....k", ".kkkkk."],
        palette: ["k": k])
    static let doc = WorldSprite(
        rows: ["kkkkk..", "k...kk.", "k.....k", "k.kkk.k", "k.....k", "k.kkk.k", "k.....k", "kkkkkkk"],
        palette: ["k": k])
    static let globe = WorldSprite(
        rows: [".kkkkk.", "k..k..k", "kkkkkkk", "k..k..k", "kkkkkkk", "k..k..k", ".kkkkk."],
        palette: ["k": k])
    static let waves = WorldSprite(
        rows: ["kkk....", "...k...", "kk..k..", "..k..k.", "k..k.k.", ".k.k.k.", "k.k.k.k"],
        palette: ["k": k])
    static let plane = WorldSprite(
        rows: ["......k", "....kkk", "..kkkk.", "kkkkkk.", "..kkk..", "...kk..", "....k.."],
        palette: ["k": k])
    static let trash = WorldSprite(
        rows: ["..kkk..", "kkkkkkk", ".k...k.", ".k.k.k.", ".k.k.k.", ".k...k.", "..kkk.."],
        palette: ["k": k])
    static let barcode = WorldSprite(
        rows: ["k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk"],
        palette: ["k": k])
    static let chevU = WorldSprite(
        rows: ["...k...", "..kkk..", ".kk.kk.", "kk...kk"],
        palette: ["k": k])
    static let bubble = WorldSprite(
        rows: [".kkkkkk.", "k......k", "k.k.k..k", "k......k", ".kkkkkk.", ".kk.....", "k......."],
        palette: ["k": k])

    /// A small round dot in `colour` with a soft highlight (the design's stand-in for an ingredient with
    /// no art of its own yet, `b2-recipe-long`).
    static func dot(_ colour: UInt32) -> WorldSprite {
        WorldSprite(rows: [".kkkk.", "kcccck", "kcwcck", "kcccck", ".kkkk."],
                    palette: ["k": k, "c": colour, "w": RecipeIngredientArt.highlight(colour)])
    }
}

/// Which pixel icon an ingredient row shows (owner's draft-2 note on the recipe page: icons small
/// enough for a 30-ingredient recipe). Ingredients with art of their own show it; the rest show a small
/// dot in a colour that suits them, chosen the same way every time for the same name.
///
/// Matching reads the food's name in lower case, word by word, for a few English and Spanish word
/// starts ("oat" matches "oats", never "goat"). It is display only: nothing is stored, and a name with
/// no match still gets a dot.
nonisolated enum RecipeIngredientArt {
    /// One rule: a word of the name starting with any of `starts` draws `sprite`. Earlier rules win.
    private struct Rule {
        let starts: [String]
        let sprite: WorldSprite
    }

    /// The rules, the near-misses first (an eggplant is not an egg, butternut is not butter).
    private static let rules: [Rule] = [
        Rule(starts: ["eggplant", "aubergine", "berenjena"], sprite: WorldSprites.dot(0x6E4A78)),
        Rule(starts: ["butternut", "squash", "pumpkin", "calabaza"], sprite: WorldSprites.dot(0xE5A93A)),
        Rule(starts: ["oat", "avena", "granola", "muesli"], sprite: WorldSprites.oats),
        Rule(starts: ["yogurt", "yoghurt", "yogur", "skyr", "kefir"], sprite: WorldSprites.yogurt),
        Rule(starts: ["berr", "blueberr", "strawberr", "raspberr", "blackberr", "cranberr", "arándano",
                      "arandano", "fresa", "frambuesa"], sprite: WorldSprites.berries),
        Rule(starts: ["chicken", "turkey", "beef", "pork", "steak", "lamb", "meat", "sausage", "bacon", "ham",
                      "pollo", "pavo", "carne", "cerdo", "cordero", "salchicha"], sprite: WorldSprites.drumstick),
        Rule(starts: ["egg", "huevo"], sprite: WorldSprites.egg),
        Rule(starts: ["garlic", "ajo"], sprite: WorldSprites.garlic),
        Rule(starts: ["onion", "shallot", "leek", "scallion", "cebolla", "chalota", "puerro"], sprite: WorldSprites.onion),
        Rule(starts: ["spinach", "lettuce", "kale", "cilantro", "basil", "parsley", "herb", "greens", "chard",
                      "espinaca", "lechuga", "albahaca", "perejil", "acelga"], sprite: WorldSprites.leaf),
        Rule(starts: ["rice", "flour", "wheat", "bread", "pasta", "noodle", "quinoa", "barley", "couscous",
                      "tortilla", "arroz", "harina", "trigo", "pan", "fideo", "cebada"], sprite: WorldSprites.wheat),
        Rule(starts: ["oil", "butter", "ghee", "lard", "aceite", "mantequilla", "manteca"], sprite: WorldSprites.fatDrop),
    ]

    /// The dot colours, warm food tones from the design's 16-ingredient comparison.
    static let dotColours: [UInt32] = [0xD9B27A, 0xD2973B, 0x8A5A32, 0xE5A93A, 0xC8553D, 0xE6CFA0, 0x9FC58D,
                                       0xB8543D, 0x7FA545, 0xC9A0C8]

    /// The art for an ingredient named `name` (nil while its food is unresolved, which draws a dot).
    static func sprite(forIngredientNamed name: String?) -> WorldSprite {
        let lowered = (name ?? "").lowercased()
        return rule(for: lowered)?.sprite ?? WorldSprites.dot(dotColour(for: lowered))
    }

    /// Whether `name` has art of its own or a near-miss's own dot (not the hashed stand-in).
    static func hasArt(forIngredientNamed name: String) -> Bool {
        rule(for: name.lowercased()) != nil
    }

    /// The first rule one of the name's words starts with. Bounded: a name's first 32 words.
    private static func rule(for lowered: String) -> Rule? {
        let words = lowered.split { !$0.isLetter }.prefix(32)
        return rules.first { rule in
            words.contains { word in rule.starts.contains { word.hasPrefix($0) } }
        }
    }

    /// A stable colour for a name: the same food draws the same dot on every launch (a sum of its
    /// Unicode scalars, not `hashValue`, which changes per launch).
    static func dotColour(for name: String) -> UInt32 {
        let sum = name.unicodeScalars.prefix(64).reduce(0) { $0 &+ Int($1.value) }
        return dotColours[sum % dotColours.count]
    }

    /// `colour` blended 55 % toward white: the dot's highlight.
    static func highlight(_ colour: UInt32) -> UInt32 {
        let channel = { (shift: UInt32) -> UInt32 in
            let value = Double((colour >> shift) & 0xFF)
            return UInt32((value + (255 - value) * 0.55).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }
}
