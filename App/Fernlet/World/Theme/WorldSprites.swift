import SwiftUI

/// One piece of pixel art: rows of palette keys (`.` is clear), drawn one point square per key at a
/// whole-number scale so it stays crisp.
///
/// The World build's art is the approved pixel world (owner, 2026-10-23; design language `b1-language`,
/// World Review Batch 1): every icon is pixel art, inside panels too. These sprites are copied key for
/// key from that page's own table, so the app draws what the owner approved.
nonisolated struct WorldSprite: Equatable, Sendable {
    /// The rows, top to bottom; every row has the same width.
    let rows: [String]
    /// The colour of each key, as `0xRRGGBB`.
    let palette: [Character: UInt32]

    /// Width in sprite pixels.
    var width: Int { rows.first?.count ?? 0 }
    /// Height in sprite pixels.
    var height: Int { rows.count }
}

/// The approved sprites (World Review Batch 1, draft 3). Each is the design page's `SPR` entry.
nonisolated enum WorldSprites {
    static let heart = WorldSprite(rows: [".kk.kk.", "khRkRRk", "kRRRRRk", ".kRRRk.", "..kRk..", "...k..."],
                                  palette: ["R": 0xE5532F, "h": 0xFFB27A, "k": 0x4A2412])
    static let drop = WorldSprite(rows: ["..k..", ".kBk.", ".kBk.", "kBhBk", "kBBBk", "kBBBk", ".kkk."],
                                  palette: ["B": 0x5FB8D9, "h": 0xD8F2FF, "k": 0x24506A])
    static let coin = WorldSprite(rows: [".kkkk.", "kYYhYk", "kYyYYk", "kYyYYk", "kYYYYk", ".kkkk."],
                                  palette: ["Y": 0xF2C14E, "h": 0xFFF2B0, "k": 0x7A4A12, "y": 0xC8902A])
    static let sun = WorldSprite(rows: ["...y...", ".y...y.", "..yyy..", "yyyyyyy", "..yyy..", ".y...y.", "...y..."],
                                  palette: ["y": 0xF7C843])
    static let moon = WorldSprite(rows: ["..mmm.", ".mm...", "mm....", "mm....", "mm....", ".mm...", "..mmm."],
                                  palette: ["m": 0xF4ECC8])
    static let cloud = WorldSprite(rows: ["..cc....", ".cccc.c.", "cccccccc", ".ssssss."],
                                  palette: ["c": 0xFFFFFF, "s": 0xD7E6EF])
    static let rain = WorldSprite(rows: ["..cc....", ".cccc.c.", "cccccccc", ".ssssss.", "b..b..b.", ".b..b..b"],
                                  palette: ["b": 0x5FB8D9, "c": 0xE6EEF2, "s": 0xB9C9D3])
    static let onigiri = WorldSprite(rows: [".....kk.....", "....kwwk....", "...kwwwwk...", "..kwwwwwwk..", "..kwwwwwwk..", ".kwwwwwwwwk.", ".kwwnnnnwwk.", "kwwnnnnnnwwk", "kwwnnnnnnwwk", "kwwnnnnnnwwk", ".kkkkkkkkkk."],
                                  palette: ["k": 0x4A2E1C, "n": 0x2F4A3A, "w": 0xFFF8E8])
    static let shoe = WorldSprite(rows: ["..kkkk......", ".kGGGGk.....", ".kGwGwGk....", ".kGGGGGGkkk.", "kGGGGGGGGGGk", "kGGGGGGGGGGk", "kwwwwwwwwwwk", "kkkkkkkkkkkk"],
                                  palette: ["G": 0x5E844D, "k": 0x4A2E1C, "w": 0xFFF1D6])
    static let basket = WorldSprite(rows: ["....kkkkkk....", "...k......k...", "..k..rr.gg.k..", "..krrrrggggk..", "kkkkkkkkkkkkkk", "kbBbBbBbBbBbBk", "kBbBbBbBbBbBbk", ".kbBbBbBbBbBk.", ".kBbBbBbBbBbk.", "..kbBbBbBbBk..", "..kkkkkkkkkk.."],
                                  palette: ["B": 0xA86A34, "b": 0xC98A4A, "g": 0x8DB050, "k": 0x4A2E1C, "r": 0xD9532F])
    static let face = WorldSprite(rows: ["...kkkkkk...", "..kHHHHHHk..", ".kHHHHHHHHk.", ".kHssssssHk.", ".kskssssksk.", ".kssssssssk.", ".kssskksssk.", "..kssssssk..", "...kkkkkk...", "..kCCCCCCk..", ".kCCCCCCCCk.", ".kkkkkkkkkk."],
                                  palette: ["C": 0x6F8FA8, "H": 0x6E4A2E, "k": 0x4A2E1C, "s": 0xF2C9A0])
    static let diary = WorldSprite(rows: [".kkkkkkkkk.", "kPPPPPPPPwk", "kPPPPPPPPwk", "kPPPPPPPPwk", "kPPggggPPwk", "kPPgkkgPPwk", "kPPggggPPwk", "kPPPPPPPPwk", "kPPPPPPPPwk", "kPPPPPPPPwk", "kkkkkkkkkkk"],
                                  palette: ["P": 0xB67073, "g": 0xE8B83A, "k": 0x4A2E1C, "w": 0xFFF1D6])
    static let gear = WorldSprite(rows: ["....kkk....", ".kk.kgk.kk.", ".kgkkgkkgk.", "..kggkggk..", "kkggk.kggkk", "kgggk.kgggk", "kkggk.kggkk", "..kggkggk..", ".kgkkgkkgk.", ".kk.kgk.kk.", "....kkk...."],
                                  palette: ["g": 0x9C9A92, "k": 0x4A2E1C])
    static let boot = WorldSprite(rows: [".www....", ".www....", ".www....", ".wwww...", ".wwwwww.", "wwwwwwww", "wwwwwwww"],
                                  palette: ["w": 0xFFFFFF])
    static let dumbbell = WorldSprite(rows: [".ww.....ww.", "www.....www", "wwwwwwwwwww", "www.....www", ".ww.....ww."],
                                  palette: ["w": 0xFFFFFF])
    static let tree = WorldSprite(rows: ["...w...", "..www..", ".wwwww.", "..www..", ".wwwww.", "wwwwwww", "...w...", "...w..."],
                                  palette: ["w": 0xFFFFFF])
    static let bowl = WorldSprite(rows: [".......ww", ".....ww..", "wwwwwwwww", ".wwwwwww.", "..wwwww..", "...www..."],
                                  palette: ["w": 0xFFFFFF])
    static let runner = WorldSprite(rows: ["....ww..", "....ww..", "..www...", ".w.www..", "...w..w.", "..w.w...", ".w...w..", "w....w.."],
                                  palette: ["w": 0xFFFFFF])
    static let pair = WorldSprite(rows: [".ww...ww.", ".ww...ww.", "wwww.wwww", "wwww.wwww", ".ww...ww.", ".w.w.w.w."],
                                  palette: ["w": 0xFFFFFF])
    static let rest = WorldSprite(rows: ["...wwww", "....ww.", "...ww..", "..wwww.", "www....", ".w.....", "www...."],
                                  palette: ["w": 0xFFFFFF])
    static let leaf = WorldSprite(rows: ["....ggg", "..ggggg", ".gggdgg", ".ggdggg", "gdggg..", "d......"],
                                  palette: ["d": 0x4E7A48, "g": 0x72A364])
    static let star = WorldSprite(rows: ["....k....", "...kyk...", "kkkyyykkk", "kyyyyyyyk", ".kyyyyyk.", "..kyyyk..", ".kyykyyk.", ".kk...kk."],
                                  palette: ["k": 0x4A2E1C, "y": 0xF2C14E])
    static let flag = WorldSprite(rows: ["kk.......", "kTTTTTT..", "kTTwwTTT.", "kTTTTTTT.", "kTTTTT...", "k........", "k........", "k........", "k........", "kk......."],
                                  palette: ["T": 0x5FB8C9, "k": 0x4A2E1C, "w": 0xFFFFFF])
    static let cookie = WorldSprite(rows: ["..kkkk..", ".kccdck.", "kcccccck", "kcdcccck", "kccccdck", "kcdcccck", ".kcccck.", "..kkkk.."],
                                  palette: ["c": 0xD9A05B, "d": 0x5A3A22, "k": 0x4A2E1C])
    static let photo = WorldSprite(rows: ["kkkkkkkk", "kwwwwwwk", "kwccccwk", "kwccccwk", "kwccccwk", "kwwwwwwk", "kwwwwwwk", "kkkkkkkk"],
                                  palette: ["c": 0xE2C08E, "k": 0x4A2E1C, "w": 0xFFFDF8])
    static let heartSm = WorldSprite(rows: [".kk.kk.", "kRRkRRk", "kRRRRRk", ".kRRRk.", "..kRk..", "...k..."],
                                  palette: ["R": 0xE5532F, "k": 0x4A2E1C])
    static let pin = WorldSprite(rows: [".kkkk.", "kTTTTk", "kTwwTk", "kTwwTk", "kTTTTk", ".kTTk.", "..kk.."],
                                  palette: ["T": 0x5FB8C9, "k": 0x4A2E1C, "w": 0xFFFFFF])
    static let stampMed = WorldSprite(rows: ["..kkkk..", ".kyyyyk.", "kyyKKyyk", "kyKyyKyk", "kyKyyKyk", "kyyKKyyk", ".kyyyyk.", "..kkkk.."],
                                  palette: ["K": 0xB5762A, "k": 0x4A2E1C, "y": 0xF2C14E])
    static let lock = WorldSprite(rows: ["..kkkk..", ".k....k.", ".k....k.", "kkkkkkkk", "kGGGGGGk", "kGGkkGGk", "kGGGGGGk", "kkkkkkkk"],
                                  palette: ["G": 0xB67073, "k": 0x4A2E1C])
    static let chevR = WorldSprite(rows: ["k...", "kk..", ".kk.", "..kk", ".kk.", "kk..", "k..."],
                                  palette: ["k": 0x4A2E1C])
    static let chevL = WorldSprite(rows: ["...k", "..kk", ".kk.", "kk..", ".kk.", "..kk", "...k"],
                                  palette: ["k": 0x4A2E1C])
    static let xx = WorldSprite(rows: ["kk...kk", ".kk.kk.", "..kkk..", "..kkk..", ".kk.kk.", "kk...kk"],
                                  palette: ["k": 0x4A2E1C])
    static let plus = WorldSprite(rows: ["..kk..", "..kk..", "kkkkkk", "kkkkkk", "..kk..", "..kk.."],
                                  palette: ["k": 0x4A2E1C])
    static let search = WorldSprite(rows: [".kkkk...", "k....k..", "k....k..", "k....k..", "k....k..", ".kkkk...", ".....kk.", "......kk"],
                                  palette: ["k": 0x4A2E1C])
    static let chart = WorldSprite(rows: [".....kkkk", "........k", "k.....k.k", ".k...k...", "..k.k....", "...k.....", "kkkkkkkkk"],
                                  palette: ["k": 0x4A2E1C])
    static let breathe = WorldSprite(rows: ["kkkkkk...", "......k..", "kkkkkkk..", ".........", "kkkkkkkk.", "........k", "kkkkkkkk."],
                                  palette: ["k": 0x4A2E1C])
    static let target = WorldSprite(rows: ["...k...", ".kkkkk.", ".k.k.k.", "kkkkkkk", ".k.k.k.", ".kkkkk.", "...k..."],
                                  palette: ["k": 0x4A2E1C])
    static let box = WorldSprite(rows: ["kkkkkkkkk", "kwwwwwwwk", "kkkkkkkkk", ".kwwwwwk.", ".kwkkkwk.", ".kwwwwwk.", ".kkkkkkk."],
                                  palette: ["k": 0x4A2E1C, "w": 0xFFF6E2])
    static let pen = WorldSprite(rows: ["......kk", ".....kgk", "....kgk.", "...kgk..", "..kgk...", ".kgk....", "kkk.....", "kk......"],
                                  palette: ["g": 0xD2973B, "k": 0x4A2E1C])
    static let bandage = WorldSprite(rows: [".kkkkkkk.", "kpppppppk", "kpwpkpwpk", "kpppppppk", ".kkkkkkk."],
                                  palette: ["k": 0x4A2E1C, "p": 0xE8A3A0, "w": 0xFFF6E2])
    static let grip = WorldSprite(rows: ["kkkkkkk", ".......", "kkkkkkk", ".......", "kkkkkkk"],
                                  palette: ["k": 0x4A2E1C])
    static let check = WorldSprite(rows: ["......k", ".....kk", "k...kk.", "kk.kk..", ".kkk...", "..k...."],
                                  palette: ["k": 0x4A2E1C])
    static let aid = WorldSprite(rows: [".kk.kk.", "kmmkmmk", "kmmmmmk", ".kmmmk.", "..kmk..", "...k..."],
                                  palette: ["k": 0x4A2E1C, "m": 0x5E844D])
    static let tub = WorldSprite(rows: ["k........", "k........", "kkkkkkkkk", "kbbbbbbbk", ".kbbbbbk.", "..kkkkk..", "..k...k.."],
                                  palette: ["b": 0x6F98B6, "k": 0x4A2E1C])
}
