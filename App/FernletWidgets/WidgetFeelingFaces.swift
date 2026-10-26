// WidgetFeelingFaces.swift
// FernletWidgets
//
// The feeling faces on the Home Screen widgets (owner's Q37, round 6b: "bring back the feeling faces"):
// happy, sad, hungry and thirsty, drawn on the pixel companion over the state's face, each with its motif
// as the app's companion has one — a twinkle for happy, a tear for sad, a thought bubble with an apple for
// hungry and with a drop of water for thirsty. Widget-only: the map's companion draws the state face, and
// the painter between the twin markers (WidgetPixelCompanion.swift) stays the map's word for word, so this
// runs after it. The Lock Screen still draws the state face only (`FernletWidgetEmotionPolicy`).

import SwiftUI

/// Swaps the state's face for a feeling's on a painted companion (owner's Q37).
///
/// Only cells of bare body are touched: the state's face is erased back to the body's own colour (the
/// painter's per-pixel rule), and the feeling's cells are drawn only where the body is bare, so glasses,
/// the scarf, the cap and a drawn Creation Studio piece stay on top, whatever the shape. With glasses on,
/// the eyes stay inside the lenses. Every drawn cell is part of the face, so a one-colour rendering cuts
/// the feeling out of the silhouette, as it cuts the state's face.
enum WidgetFeelingFace {
    /// The feelings drawn on the face; the others (tired, sleepy, asleep) keep the state's face or the
    /// night's, as before.
    static let drawn: Set<WidgetCompanionEmotion> = [.happy, .sad, .hungry, .thirsty]

    /// The tear's two blues (Home's water drop).
    static let tear: (top: UInt32, bottom: UInt32) = (0xD8F2FF, 0x5FB8D9)

    /// `emotion` when it is one of the ``drawn`` feelings, else nil.
    static func face(for emotion: WidgetCompanionEmotion?) -> WidgetCompanionEmotion? {
        guard let emotion, drawn.contains(emotion) else { return nil }
        return emotion
    }

    /// Draws `emotion`'s face on `grid`, painted for `state`, `look` and `pose`, in place of the state's.
    static func apply(_ emotion: WidgetCompanionEmotion, to grid: inout WidgetCompanionGrid, state: WidgetCompanionMood,
                      look: WidgetPixelLook, pose: WidgetCompanionPose, increasedContrast: Bool) {
        guard drawn.contains(emotion), !pose.asleep else { return }
        let body = WidgetCompanionBody(state: state, shape: look.shape, color: look.body, pose: pose,
                                       increasedContrast: increasedContrast)
        let eye = Int((body.cy - 1).rounded()), mouth = Int((body.cy + 2).rounded()) - (state == .sick ? 1 : 0)
        for (x, y) in stateFaceCells(state: state, pose: pose, body: body) {
            guard let bare = bodyColour(x, y, body: body, sick: state == .sick),
                  grid.isFace(frameX: x + WidgetCompanionGrid.frameX, y: y + WidgetCompanionGrid.frameY)
                    || grid.color(x: x, y: y) == body.dark else { continue }
            grid.put(x, y, bare)
        }
        for cell in cells(for: emotion, eye: eye, mouth: mouth) {
            guard let bare = bodyColour(cell.x, cell.y, body: body, sick: state == .sick),
                  grid.color(x: cell.x, y: cell.y) == bare else { continue }
            grid.put(cell.x, cell.y, cell.hex, face: true)
        }
    }

    /// One drawn cell: where, and its colour.
    struct Cell: Equatable {
        let x: Int
        let y: Int
        let hex: UInt32
    }

    /// `emotion`'s face, its eyes on row `eye` and its mouth on row `mouth`, at body coordinates.
    static func cells(for emotion: WidgetCompanionEmotion, eye: Int, mouth: Int) -> [Cell] {
        let ink = WidgetCompanionPainter.ink
        let inked = { (points: [(Int, Int)]) in points.map { Cell(x: $0.0, y: $0.1, hex: ink) } }
        switch emotion {
        case .happy:
            // Eyes bowed up like "^", a wide smile, a blush.
            let eyes = [7, 12].flatMap { x in [(x - 1, eye + 1), (x, eye), (x + 1, eye + 1)] }
            let smile = [(7, mouth), (8, mouth + 1), (9, mouth + 1), (10, mouth + 1), (11, mouth + 1), (12, mouth)]
            return inked(eyes + smile) + [Cell(x: 5, y: mouth - 1, hex: WidgetCompanionPainter.blush),
                                          Cell(x: 14, y: mouth - 1, hex: WidgetCompanionPainter.blush)]
        case .sad:
            // Brows lifted at the inner ends (sad with the person, never disappointed), a soft frown and a tear.
            let eyes = [7, 12].flatMap { x in [(x, eye), (x, eye + 1)] }
            let brows = [(6, eye - 1), (7, eye - 2), (13, eye - 1), (12, eye - 2)]
            let frown = [(8, mouth + 1), (9, mouth), (10, mouth), (11, mouth + 1)]
            return inked(eyes + brows + frown) + [Cell(x: 5, y: eye + 2, hex: tear.top), Cell(x: 5, y: eye + 3, hex: tear.bottom)]
        case .hungry, .thirsty:
            // Eyes raised toward the thought bubble; an open "o" (a smaller one when thirsty).
            let eyes = [7, 12].flatMap { x in [(x, eye - 1), (x, eye)] }
            let open = emotion == .hungry ? [(9, mouth), (10, mouth), (9, mouth + 1), (10, mouth + 1)] : [(9, mouth), (10, mouth)]
            return inked(eyes + open)
        case .tired, .sleepy, .asleep:
            return []
        }
    }

    /// The cells the painter's state face covers (the twin's `paintFace`, for the widget's poses): the eyes,
    /// open or closed, the band's mouth and a thriving day's blush.
    static func stateFaceCells(state: WidgetCompanionMood, pose: WidgetCompanionPose, body: WidgetCompanionBody) -> [(Int, Int)] {
        let eye = Int((body.cy - 1).rounded()), mouthRow = Int((body.cy + 2).rounded())
        let eyes = WidgetCompanionPainter.closesEyes(state: state, pose: pose)
            ? [(6, eye + 1), (7, eye + 1), (12, eye + 1), (13, eye + 1)]
            : [(7, eye), (7, eye + 1), (12, eye), (12, eye + 1)]
        let face = pose.drowsy && state != .sick ? WidgetCompanionMood.resting : state
        let row = state == .sick ? mouthRow - 1 : mouthRow
        let mouth = WidgetCompanionPainter.mouth(for: face).map { ($0.0, row + $0.1) }
        let blush = face == .thriving ? [(5, mouthRow - 1), (14, mouthRow - 1)] : []
        return eyes + mouth + blush
    }

    /// The body's own colour at (`x`, `y`) as the painter fills it (outline, highlight, lower shade, a
    /// sick day's blanket), or nil outside the body — the twin's `paintBody` rule for one pixel.
    static func bodyColour(_ x: Int, _ y: Int, body: WidgetCompanionBody, sick: Bool) -> UInt32? {
        guard body.contains(x, y) else { return nil }
        let edge = !body.contains(x - 1, y) || !body.contains(x + 1, y) || !body.contains(x, y - 1) || !body.contains(x, y + 1)
        let hy = Double(y) - (body.cy - 3.5)
        let inHighlight = Double((x - 7) * (x - 7)) + hy * hy <= 2.3
        if sick && !edge && Double(y) >= (body.cy + 1.5).rounded() { return x % 3 == 0 ? 0xD9A57E : 0xF3E6CB }
        return edge ? body.dark : (inHighlight ? body.light : (Double(y) >= body.cy + body.ry - 2.2 ? body.low : body.base))
    }
}

/// The small picture a feeling adds beside the companion's head (owner's Q37), as the app's companion
/// has one: a twinkle when happy, a thought bubble with an apple when hungry and with a drop when
/// thirsty. Sad's tear is on the face itself.
enum WidgetFeelingMotif: Equatable {
    case twinkle
    case apple
    case drop

    /// The motif for a drawn feeling, if it has one.
    init?(feeling: WidgetCompanionEmotion?) {
        switch feeling {
        case .happy: self = .twinkle
        case .hungry: self = .apple
        case .thirsty: self = .drop
        default: return nil
        }
    }

    /// Its pixel picture (no app twin: the map's companion draws no feeling).
    var sprite: WidgetSprite {
        switch self {
        case .twinkle: WidgetFeelingSprites.twinkle
        case .apple: WidgetFeelingSprites.appleBubble
        case .drop: WidgetFeelingSprites.dropBubble
        }
    }
}

/// The feelings' motifs in pixels (no app twin: the map's companion draws no feeling): ink, the bubble's
/// light paper, Home's heart red and drop blues, and the gold heart's yellows. In one colour the paper
/// drops out and the rest takes the tint (`WidgetSpritePaint.clearingPaper`).
enum WidgetFeelingSprites {
    /// The happy twinkle: a four-point star in the gold heart's yellows.
    static let twinkle = WidgetSprite(rows: ["...y...", "...y...", "..yhy..", "yyhhhyy", "..yhy..", "...y...", "...y..."],
                                      palette: ["y": 0xF2C14E, "h": 0xFFF0A8])
    /// Hungry: a thought bubble with an apple in it, its tail down toward the companion.
    static let appleBubble = WidgetSprite(rows: [".kkkkkkk.", "kwwwwgwwk", "kwwwgwwwk", "kwwrrrwwk", "kwrrhrrwk", "kwrrrrrwk",
                                                 "kwrrrrrwk", "kwwrrrwwk", ".kkkkkkk.", ".k.......", "k........"],
                                          palette: ["k": 0x4A2E1C, "w": 0xFFFBEF, "r": 0xD9532F, "h": 0xFFB27A, "g": 0x5E844D])
    /// Thirsty: a thought bubble with a drop of water in it.
    static let dropBubble = WidgetSprite(rows: [".kkkkkkk.", "kwwwbwwwk", "kwwbbbwwk", "kwwbbbwwk", "kwbbhbbwk", "kwbbbbbwk",
                                                "kwbbbbbwk", "kwwbbbwwk", ".kkkkkkk.", ".k.......", "k........"],
                                         palette: ["k": 0x4A2E1C, "w": 0xFFFBEF, "b": 0x5FB8D9, "h": 0xD8F2FF])
}
