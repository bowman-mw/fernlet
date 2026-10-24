import SwiftUI

/// The pixel art the Private lane's screens draw that the shared sprite table doesn't carry yet (World
/// Review Batch 3: `b3-water`'s bottles, `b3-hygiene`'s tooth and floss, `b3-grounding`'s five senses,
/// `b3-journal-editor`'s bin). Keyed and coloured the way the approved pages draw them (`kit.js` `SPR`),
/// and drawn through ``WorldSpriteView`` like every other World icon, so the one-colour ones take the
/// ink token in dark mode.
extension WorldSprites {
    /// A water bottle (`b3-water`): cap, neck and a blue body.
    static let bottle = WorldSprite(rows: [".kkk.", "..k..", ".kbk.", "kbbbk", "kbbbk", "kbbbk", "kbbbk", "kbbbk", ".kkk."],
                                    palette: ["k": 0x24506A, "b": 0x5FB8D9])
    /// The same bottle, empty: the ink outline alone (one colour, so it takes the ink token in dark mode).
    static let bottleEmpty = WorldSprite(rows: [".kkk.", "..k..", ".k.k.", "k...k", "k...k", "k...k", "k...k", "k...k", ".kkk."],
                                         palette: ["k": WorldSprite.ink])
    /// A tooth (`b3-hygiene`: brushing).
    static let tooth = WorldSprite(rows: [".kkkkk.", "kwwwwwk", "kwwwwwk", "kwwkwwk", ".kwk.kw", ".kk..kk"],
                                   palette: ["k": WorldSprite.ink, "w": 0xFFFDF8])
    /// A floss case (`b3-hygiene`).
    static let floss = WorldSprite(rows: ["..kkkkk.", ".kmmmmmk", ".kmwwwmk", ".kmmmmmk", ".kkkkkkk", "...k....", "....k...", ".....k.."],
                                   palette: ["k": WorldSprite.ink, "m": 0x9FC58D, "w": 0xFFFDF8])
    /// An eye (`b3-grounding`: five things you can see).
    static let eye = WorldSprite(rows: ["..kkkkk..", ".k..k..k.", "k..kkk..k", ".k..k..k.", "..kkkkk.."],
                                 palette: ["k": WorldSprite.ink])
    /// An open hand (`b3-grounding`: four things you can touch).
    static let hand = WorldSprite(rows: [".k.k.k.", ".k.k.k.", ".k.k.kk", "kkkkkkk", "kkkkkk.", ".kkkkk.", "..kkk.."],
                                  palette: ["k": WorldSprite.ink])
    /// An ear (`b3-grounding`: three things you can hear).
    static let ear = WorldSprite(rows: [".kkkk.", "k....k", "k.kk.k", "k.k..k", "...k.k", "..k.k.", "..kk.."],
                                 palette: ["k": WorldSprite.ink])
    /// A nose in profile (`b3-grounding`: two things you can smell).
    static let nose = WorldSprite(rows: ["..k...", "..k...", ".k....", ".k....", "k.....", "k..k..", ".kk.k."],
                                  palette: ["k": WorldSprite.ink])
    /// A mouth (`b3-grounding`: one thing you can taste).
    static let mouth = WorldSprite(rows: [".kkkkk.", "k.....k", "kkkkkkk", "k.....k", ".kkkkk."],
                                   palette: ["k": WorldSprite.ink])
    /// A bin (`b3-journal-editor`: Delete journal entry).
    static let bin = WorldSprite(rows: ["..kkk..", "kkkkkkk", ".k.k.k.", ".k.k.k.", ".k.k.k.", ".k.k.k.", ".kkkkk."],
                                 palette: ["k": WorldSprite.ink])
}
