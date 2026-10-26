import Foundation

/// The shell's pixel art, copied from the design page's `SPR` table so every icon matches the sketch.
nonisolated enum PixelSprites {
    private static let k: UInt32 = 0x4A2E1C

    // MARK: Status bar

    static let heart = PixelSprite(rows: [".kk.kk.", "khRkRRk", "kRRRRRk", ".kRRRk.", "..kRk..", "...k..."],
                                   palette: ["k": 0x4A2412, "R": 0xE5532F, "h": 0xFFB27A])
    static let emptyHeart = heart.recoloured(["R": 0x8E5E4A, "h": 0x8E5E4A])
    /// The left half full, the right half empty: one of HealthBar's twelve segments short of a heart.
    static let halfHeart = heart.remapped { letter, x in (x > 3 && (letter == "R" || letter == "h")) ? "e" : letter }
        .recoloured(["e": 0x8E5E4A])
    static let goldHeart = heart.recoloured(["R": 0xF2C14E, "h": 0xFFF0A8])
    static let drop = PixelSprite(rows: ["..k..", ".kBk.", ".kBk.", "kBhBk", "kBBBk", "kBBBk", ".kkk."],
                                  palette: ["k": 0x24506A, "B": 0x5FB8D9, "h": 0xD8F2FF])
    static let emptyDrop = drop.recoloured(["B": 0xA9BCC2, "h": 0xA9BCC2])
    static let coin = PixelSprite(rows: [".kkkk.", "kYYhYk", "kYyYYk", "kYyYYk", "kYYYYk", ".kkkk."],
                                  palette: ["k": 0x7A4A12, "Y": 0xF2C14E, "y": 0xC8902A, "h": 0xFFF2B0])
    static let sun = PixelSprite(rows: ["...y...", ".y...y.", "..yyy..", "yyyyyyy", "..yyy..", ".y...y.", "...y..."],
                                 palette: ["y": 0xF7C843])
    static let moon = PixelSprite(rows: ["..mmm.", ".mm...", "mm....", "mm....", "mm....", ".mm...", "..mmm."],
                                  palette: ["m": 0xF4ECC8])
    static let cloud = PixelSprite(rows: ["..cc....", ".cccc.c.", "cccccccc", ".ssssss."],
                                   palette: ["c": 0xFFFFFF, "s": 0xD7E6EF])

    // MARK: Item bar and quick log

    static let onigiri = PixelSprite(rows: [".....kk.....", "....kwwk....", "...kwwwwk...", "..kwwwwwwk..", "..kwwwwwwk..",
                                            ".kwwwwwwwwk.", ".kwwnnnnwwk.", "kwwnnnnnnwwk", "kwwnnnnnnwwk", "kwwnnnnnnwwk",
                                            ".kkkkkkkkkk."], palette: ["k": k, "w": 0xFFF8E8, "n": 0x2F4A3A])
    static let shoe = PixelSprite(rows: ["..kkkk......", ".kGGGGk.....", ".kGwGwGk....", ".kGGGGGGkkk.", "kGGGGGGGGGGk",
                                         "kGGGGGGGGGGk", "kwwwwwwwwwwk", "kkkkkkkkkkkk"], palette: ["k": k, "G": 0x5E844D, "w": 0xFFF1D6])
    static let basket = PixelSprite(rows: ["....kkkkkk....", "...k......k...", "..k..rr.gg.k..", "..krrrrggggk..", "kkkkkkkkkkkkkk",
                                           "kbBbBbBbBbBbBk", "kBbBbBbBbBbBbk", ".kbBbBbBbBbBk.", ".kBbBbBbBbBbk.", "..kbBbBbBbBk..",
                                           "..kkkkkkkkkk.."], palette: ["k": k, "b": 0xC98A4A, "B": 0xA86A34, "r": 0xD9532F, "g": 0x8DB050])
    static let face = PixelSprite(rows: ["...kkkkkk...", "..kHHHHHHk..", ".kHHHHHHHHk.", ".kHssssssHk.", ".kskssssksk.", ".kssssssssk.",
                                         ".kssskksssk.", "..kssssssk..", "...kkkkkk...", "..kCCCCCCk..", ".kCCCCCCCCk.", ".kkkkkkkkkk."],
                                  palette: ["k": k, "H": 0x6E4A2E, "s": 0xF2C9A0, "C": 0x6F8FA8])
    static let diary = PixelSprite(rows: [".kkkkkkkkk.", "kPPPPPPPPwk", "kPPPPPPPPwk", "kPPPPPPPPwk", "kPPggggPPwk", "kPPgkkgPPwk",
                                          "kPPggggPPwk", "kPPPPPPPPwk", "kPPPPPPPPwk", "kPPPPPPPPwk", "kkkkkkkkkkk"],
                                   palette: ["k": k, "P": 0xB67073, "w": 0xFFF1D6, "g": 0xE8B83A])
    static let gear = PixelSprite(rows: ["....kkk....", ".kk.kgk.kk.", ".kgkkgkkgk.", "..kggkggk..", "kkggk.kggkk", "kgggk.kgggk",
                                         "kkggk.kggkk", "..kggkggk..", ".kgkkgkkgk.", ".kk.kgk.kk.", "....kkk...."],
                                  palette: ["k": k, "g": 0x9C9A92])
    static let moonDark = moon.recoloured(["m": 0x6F8FA8])
    static let happy = PixelSprite(rows: [".yyyyy.", "yykykyy", "yyyyyyy", "ykyyyky", "yykkkyy", ".yyyyy."],
                                   palette: ["y": 0xF2C14E, "k": k])

    // MARK: Blue button (white glyphs on teal)

    static let boot = PixelSprite(rows: [".www....", ".www....", ".www....", ".wwww...", ".wwwwww.", "wwwwwwww", "wwwwwwww"],
                                  palette: ["w": 0xFFFFFF])
    static let dumbbell = PixelSprite(rows: [".ww.....ww.", "www.....www", "wwwwwwwwwww", "www.....www", ".ww.....ww."],
                                      palette: ["w": 0xFFFFFF])
    static let tree = PixelSprite(rows: ["...w...", "..www..", ".wwwww.", "..www..", ".wwwww.", "wwwwwww", "...w...", "...w..."],
                                  palette: ["w": 0xFFFFFF])
    static let bowl = PixelSprite(rows: [".......ww", ".....ww..", "wwwwwwwww", ".wwwwwww.", "..wwwww..", "...www..."],
                                  palette: ["w": 0xFFFFFF])
    static let crosshair = PixelSprite(rows: ["...w...", "..www..", ".w.w.w.", "wwwwwww", ".w.w.w.", "..www..", "...w..."],
                                       palette: ["w": 0xFFFFFF])

    // MARK: Map marks, banners

    static let flag = PixelSprite(rows: ["kk.......", "kTTTTTT..", "kTTwwTTT.", "kTTTTTTT.", "kTTTTT...", "k........", "k........",
                                         "k........", "k........", "kk......."], palette: ["k": k, "T": 0x5FB8C9, "w": 0xFFFFFF])
    static let star = PixelSprite(rows: ["....k....", "...kyk...", "kkkyyykkk", "kyyyyyyyk", ".kyyyyyk.", "..kyyyk..", ".kyykyyk.",
                                         ".kk...kk."], palette: ["k": k, "y": 0xF2C14E])
    static let cookie = PixelSprite(rows: ["..kkkk..", ".kccdck.", "kcccccck", "kcdcccck", "kccccdck", "kcdcccck", ".kcccck.",
                                           "..kkkk.."], palette: ["k": k, "c": 0xD9A05B, "d": 0x5A3A22])
    static let photo = PixelSprite(rows: ["kkkkkkkk", "kwwwwwwk", "kwccccwk", "kwccccwk", "kwccccwk", "kwwwwwwk", "kwwwwwwk",
                                          "kkkkkkkk"], palette: ["k": k, "w": 0xFFFDF8, "c": 0xE2C08E])
    static let photoGreen = photo.recoloured(["c": 0x8DB879])
    static let car = PixelSprite(rows: ["...kkkkk....", "..kwwwwwk...", ".kRRRRRRRRk.", "kRRRRRRRRRRk", "kRRRRRRRRRRk", ".kkk....kkk.",
                                        ".kgk....kgk.", "..k......k.."], palette: ["k": k, "w": 0xCFE7F0, "R": 0xC8553D, "g": 0x9C9A92])
    static let bike = PixelSprite(rows: ["..kkk....kkk..", ".k...k..k...k.", "k..T..kk..T..k", "k...TTTTTT...k", ".k...k..k...k.",
                                         "..kkk....kkk.."], palette: ["k": k, "T": 0x5FB8C9])
}
