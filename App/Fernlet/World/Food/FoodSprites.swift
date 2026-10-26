import SwiftUI

/// The pixel icons the Food screens draw that the World's shared table (`WorldSprites`) doesn't hold:
/// the capture camera, Recent's clock, Import's link, the ⓘ, the macro tiles' drumstick, wheat and drop,
/// the label document, the camera-off sign, share, the open-page globe and the flash bolt.
///
/// Copied key for key from the approved kit's sprite table (World Review Batch 3, `kit.js` `SPR`), so the
/// app draws what the owner approved. One-colour icons use the design's ink alone, so `WorldSpriteView`
/// draws them in the ink token and they stay visible on dark paper.
nonisolated enum FoodSprites {
    /// A one-colour icon's palette: the design's ink alone (`WorldSprite.isMonoInk`).
    private static let ink: [Character: UInt32] = ["k": WorldSprite.ink]

    /// A one-colour ink icon.
    private static func mono(_ rows: [String]) -> WorldSprite {
        WorldSprite(rows: rows, palette: ink)
    }

    /// The capture camera on the moss button (`SPR.camera`): paper body, blue lens.
    static let camera = WorldSprite(
        rows: ["..kkk.....", "kkkkkkkkkk", "kwwwwwwwwk", "kwwkkkwwwk", "kwkbbbkwwk", "kwwkkkwwwk", "kwwwwwwwwk", "kkkkkkkkkk"],
        palette: ["k": WorldSprite.ink, "w": 0xFFF6E2, "b": 0x6F98B6])
    static let clock = mono([".kkkkk.", "k..k..k", "k..k..k", "k..kk.k", "k.....k", "k.....k", ".kkkkk."])
    static let link = mono(["....kkk", "...k..k", "..k.k.k", ".k.k.k.", "k.k.k..", "k..k...", "kkk...."])
    static let info = mono([".kkkkk.", "k..k..k", "k.....k", "k..k..k", "k..k..k", "k..k..k", ".kkkkk."])
    static let doc = mono(["kkkkk..", "k...kk.", "k.....k", "k.kkk.k", "k.....k", "k.kkk.k", "k.....k", "kkkkkkk"])
    static let cameraOff = mono(["..kkk...k", "kkkkkk.k.", "k....kk.k", "k...kk..k", "k..kk...k", "k.kk....k", "kkk.....k", "kkkkkkkkk"])
    static let share = mono(["....k....", "...kkk...", "..k.k.k..", "....k....", "....k....", "kk..k..kk", "k.......k", "k.......k", "kkkkkkkkk"])
    static let globe = mono([".kkkkk.", "k..k..k", "kkkkkkk", "k..k..k", "kkkkkkk", "k..k..k", ".kkkkk."])
    static let bolt = mono(["..kk.", ".kk..", "kkkkk", "..kk.", ".kk..", "kk...", "k...."])
    static let barcode = mono(["k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk", "k.kk.k.kk"])
    /// The macro tiles' protein (`SPR.drumstick`).
    static let drumstick = WorldSprite(
        rows: ["....kkk..", "...krrrk.", "..krrrrrk", "..krrrrk.", ".kkrrrk..", "kwk.kk...", "kwwk.....", ".kk......"],
        palette: ["k": WorldSprite.ink, "r": 0xB8543D, "w": 0xFFF6E2])
    /// The macro tiles' carbs (`SPR.wheat`).
    static let wheat = WorldSprite(
        rows: ["...k...", "..kgk..", ".kgkgk.", "..kgk..", ".kgkgk.", "..kgk..", "...k...", "...k...", "...k..."],
        palette: ["k": WorldSprite.ink, "g": 0xD2973B])
    /// The macro tiles' fat (`SPR.fatdrop`).
    static let fatDrop = WorldSprite(
        rows: ["...k...", "..kyk..", ".kyyyk.", "kyyhyyk", "kyyyyyk", "kyyyyyk", ".kyyyk.", "..kkk.."],
        palette: ["k": WorldSprite.ink, "y": 0xE8C35A, "h": 0xFFF2B0])
    /// The photo library (`SPR.photo2`): a framed picture with a green hill.
    static let library = WorldSprite(
        rows: ["kkkkkkkk", "kwwwwwwk", "kwccccwk", "kwccccwk", "kwccccwk", "kwwwwwwk", "kwwwwwwk", "kkkkkkkk"],
        palette: ["k": WorldSprite.ink, "w": 0xFFFDF8, "c": 0x8DB879])
}
