//
//  FernletMessagesPanelSprites.swift
//  FernletMessagesExtension
//
//  The panel's own pixel icons (World Review Batch 4, `b4-msg-*`). The card's three sprites — the
//  fern, the bowl and the dumbbell — are in `FernletMessagesCard.swift`, which the app compiles too.
//

import UIKit

/// The one-colour icons only the iMessage app's panel draws, copied key for key from the app's World
/// sprites (`RecipeWorldArt.share`, `WorldSprites.search`, `WorldSprites.check`, `MoveSprites.info`),
/// with digits for keys. Each is drawn as a template and inked by its image view's tint.
extension FernletMessagesSprite {
    /// The tray and arrow of Share.
    static let share = FernletMessagesSprite(
        rows: ["....1....", "...111...", "..1.1.1..", "....1....", "....1....", "11..1..11", "1.......1",
               "1.......1", "111111111"],
        palette: ["1": 0x4A2E1C])
    /// The magnifier in the search field.
    static let search = FernletMessagesSprite(
        rows: [".1111...", "1....1..", "1....1..", "1....1..", "1....1..", ".1111...", ".....11.", "......11"],
        palette: ["1": 0x4A2E1C])
    /// The tick on the picked card.
    static let check = FernletMessagesSprite(
        rows: ["......1", ".....11", "1...11.", "11.11..", ".111...", "..1...."],
        palette: ["1": 0x4A2E1C])
    /// An "i" in a frame: the card that can't be opened.
    static let info = FernletMessagesSprite(
        rows: ["1111111", "1..1..1", "1.....1", "1.11..1", "1..1..1", "1.111.1", "1111111"],
        palette: ["1": 0x4A2E1C])
}
