// LiveActivityPixelArt.swift
// FernletWidgets
//
// The pixel icons the Live Activities draw (World Review Batch 4): the dumbbell, the runner, the
// flame, the pause bars, the check, the skip arrows, the chevron and the small heart. The rows are
// copied key for key from the approved pages' sprite table, the same table the app's `WorldSprites`
// copies; the extension cannot see the app's files, so the few it needs live here.

import SwiftUI

/// One piece of pixel art: rows of palette keys (`.` is clear), drawn one point square per key at a
/// whole-number scale so it stays crisp.
struct LiveActivitySprite: Equatable, Sendable {
    /// The rows, top to bottom; every row has the same width.
    let rows: [String]
    /// The colour of each key, as `0xRRGGBB`. A one-colour icon has a single key and is always drawn
    /// in its caller's tint.
    let palette: [Character: UInt32]

    /// Width in sprite pixels.
    var width: Int { rows.first?.count ?? 0 }
    /// Height in sprite pixels.
    var height: Int { rows.count }
}

/// The approved sprites the Live Activities use (World Review Batch 1 table, plus Batch 4's flame,
/// pause and skip arrows).
enum LiveActivitySprites {
    /// The ink of the design's multi-colour sprites' outlines.
    private static let ink: UInt32 = 0x4A2E1C

    /// A workout: the header, the compact island.
    static let dumbbell = LiveActivitySprite(
        rows: [".ww.....ww.", "www.....www", "wwwwwwwwwww", "www.....www", ".ww.....ww."], palette: ["w": 0xFFFFFF])
    /// A cardio part, and a single-step move in the compact island.
    static let runner = LiveActivitySprite(
        rows: ["....ww..", "....ww..", "..www...", ".w.www..", "...w..w.", "..w.w...", ".w...w..", "w....w.."],
        palette: ["w": 0xFFFFFF])
    /// Cooking.
    static let flame = LiveActivitySprite(
        rows: ["...r...", "..rr...", "..rgr..", ".rggr.r", ".rgygrr", "rgyyygr", "rgyyygr", ".rgyyr.", "..rrr.."],
        palette: ["r": 0xB8543D, "g": 0xD2973B, "y": 0xF2C14E])
    /// Paused: Fernlet was closed mid-run.
    static let pause = LiveActivitySprite(
        rows: ["kk.kk", "kk.kk", "kk.kk", "kk.kk", "kk.kk", "kk.kk"], palette: ["k": ink])
    /// Done set, Finish.
    static let check = LiveActivitySprite(
        rows: ["......k", ".....kk", "k...kk.", "kk.kk..", ".kkk...", "..k...."], palette: ["k": ink])
    /// Skip rest.
    static let forward = LiveActivitySprite(
        rows: ["k..k...", "kk.kk..", "kkkkkk.", "kk.kk..", "k..k..."], palette: ["k": ink])
    /// Next step.
    static let chevronRight = LiveActivitySprite(
        rows: ["k...", "kk..", ".kk.", "..kk", ".kk.", "kk..", "k..."], palette: ["k": ink])
    /// The heart-rate line.
    static let heart = LiveActivitySprite(
        rows: [".kk.kk.", "kRRkRRk", "kRRRRRk", ".kRRRk.", "..kRk..", "...k..."], palette: ["k": ink, "R": 0xE5532F])
}

/// Draws a ``LiveActivitySprite`` crisply: each key one `scale`-point square, no smoothing.
///
/// A one-colour sprite takes `tint` (ink on paper, leaf green on the island's black, the button's word
/// on a button); a multi-colour one keeps its own colours. Decoration to VoiceOver unless it is given a
/// `label`: in the island's compact and minimal slots the icon is the only thing saying which activity
/// is running, so there it speaks ("Workout", "Cooking", "Paused").
struct LiveActivitySpriteView: View {
    let sprite: LiveActivitySprite
    /// Points per sprite pixel (whole numbers keep the art crisp).
    var scale: CGFloat = 2
    /// The colour of a one-colour sprite; ignored by a multi-colour one.
    var tint: Color = .primary
    /// What VoiceOver says for the icon; nil hides it.
    var label: Text? = nil

    var body: some View {
        if let label {
            art.accessibilityElement().accessibilityLabel(label)
        } else {
            art.accessibilityHidden(true)
        }
    }

    private var art: some View {
        let mono = sprite.palette.count == 1
        return Canvas { context, _ in
            for (y, row) in sprite.rows.enumerated() {
                for (x, key) in row.enumerated() where key != "." {
                    guard let base = sprite.palette[key] else { continue }
                    let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)
                    context.fill(Path(rect), with: .color(mono ? tint : Color(laHex: base)))
                }
            }
        }
        .frame(width: CGFloat(sprite.width) * scale, height: CGFloat(sprite.height) * scale)
    }
}
