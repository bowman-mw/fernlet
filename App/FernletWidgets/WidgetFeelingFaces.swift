// WidgetFeelingFaces.swift
// FernletWidgets
//
// The feeling faces on the Home Screen widgets (owner's Q37, round 6b: "bring back the feeling faces"):
// happy, sad, hungry and thirsty, drawn on the pixel companion over the state's face, each with its motif
// as the app's companion has one — a twinkle for happy, a tear for sad, a thought bubble with an apple for
// hungry and with a drop of water for thirsty. Widget-only: the map's companion draws the state face, and
// the painter between the twin markers (WidgetPixelCompanion.swift) stays the map's word for word, so this
// runs after it. The Lock Screen still draws the state face only (`FernletWidgetEmotionPolicy`).
//
// Where each face goes is the twin's rule (group 17, approved 2026-10-26): `WidgetCompanionFaceLayout`
// fits the state's face and the feeling's to the body's shape, and `WidgetCompanionBody.pixelColor` is the
// body's own colour, so both painters place and erase a face the same way.

import SwiftUI

/// Swaps the state's face for a feeling's on a painted companion (owner's Q37).
///
/// Only cells of bare body are touched: the state's face is erased back to the body's own colour (the
/// twin's ``WidgetCompanionBody/pixelColor(_:_:sick:)``), and the feeling's cells are drawn only where
/// the body is bare, so glasses, the scarf, the cap and a drawn Creation Studio piece stay on top,
/// whatever the shape. With glasses on, the eyes stay inside the lenses. Both faces sit where the twin's
/// ``WidgetCompanionFaceLayout`` puts them on the body's shape (group 17): a row lower on Pear, a row
/// higher on Puddle, clear of the outline, with the cheeks and the tear stepping inward. A sick day's
/// feeling keeps its mouth a row up, clear of the blanket. Every drawn cell is part of the face, so a
/// one-colour rendering cuts the feeling out of the silhouette, as it cuts the state's face.
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

    /// The twin's face for a drawn feeling, which the shared layout places; nil for the others.
    static func layoutFace(for emotion: WidgetCompanionEmotion) -> WidgetCompanionFace? {
        switch emotion {
        case .happy: .happy
        case .sad: .sad
        case .hungry: .hungry
        case .thirsty: .thirsty
        case .tired, .sleepy, .asleep: nil
        }
    }

    /// Draws `emotion`'s face on `grid`, painted for `state`, `look` and `pose`, in place of the state's.
    static func apply(_ emotion: WidgetCompanionEmotion, to grid: inout WidgetCompanionGrid, state: WidgetCompanionMood,
                      look: WidgetPixelLook, pose: WidgetCompanionPose, increasedContrast: Bool) {
        guard drawn.contains(emotion), !pose.asleep, let face = layoutFace(for: emotion) else { return }
        let body = WidgetCompanionBody(state: state, shape: look.shape, color: look.body, pose: pose,
                                       increasedContrast: increasedContrast)
        let sick = state == .sick
        for (x, y) in stateFaceCells(state: state, pose: pose, body: body) {
            guard let bare = body.pixelColor(x, y, sick: sick),
                  grid.isFace(frameX: x + WidgetCompanionGrid.frameX, y: y + WidgetCompanionGrid.frameY)
                    || grid.color(x: x, y: y) == body.dark else { continue }
            grid.put(x, y, bare)
        }
        let layout = WidgetCompanionFaceLayout(body: body, face: face)
        for cell in cells(for: emotion, layout: layout, mouth: layout.mouth - (sick ? 1 : 0)) {
            guard let bare = body.pixelColor(cell.x, cell.y, sick: sick),
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

    /// `emotion`'s face at `layout`, its mouth on row `mouth` (the layout's, or a row up on a sick day), at
    /// body coordinates: the twin's ink cells, then a happy face's blush where the layout found room, and a
    /// sad face's tear in the layout's column.
    static func cells(for emotion: WidgetCompanionEmotion, layout: WidgetCompanionFaceLayout, mouth: Int) -> [Cell] {
        guard let face = layoutFace(for: emotion) else { return [] }
        let ink = face.cells(eye: layout.eye, mouth: mouth, lowered: layout.lowered)
            .map { Cell(x: $0.0, y: $0.1, hex: WidgetCompanionPainter.ink) }
        switch face {
        case .happy:
            // Eyes bowed up like "^", a wide smile, a blush.
            guard let cheeks = layout.cheeks else { return ink }
            return ink + [Cell(x: cheeks.left, y: mouth + cheeks.rowOffset, hex: WidgetCompanionPainter.blush),
                          Cell(x: cheeks.right, y: mouth + cheeks.rowOffset, hex: WidgetCompanionPainter.blush)]
        case .sad:
            // Brows lifted at the inner ends (sad with the person, never disappointed), a soft frown and a tear.
            return ink + [Cell(x: layout.tear, y: layout.eye + 2, hex: tear.top), Cell(x: layout.tear, y: layout.eye + 3, hex: tear.bottom)]
        case .hungry, .thirsty, .thriving, .okay, .tired, .resting, .sick:
            // Eyes raised toward the thought bubble (level where there's no room); an open "o".
            return ink
        }
    }

    /// The cells the painter's state face covers (the twin's `paintFace`, for the widget's poses): the eyes,
    /// open or closed, the band's mouth and a thriving day's blush, on the twin's layout for the state's face.
    /// Awake poses only, as ``apply(_:to:state:look:pose:increasedContrast:)`` draws no feeling asleep (the
    /// painter's asleep face keeps the band's mouth under closed eyes).
    static func stateFaceCells(state: WidgetCompanionMood, pose: WidgetCompanionPose, body: WidgetCompanionBody) -> [(Int, Int)] {
        let face = WidgetCompanionFace.state(state, pose: pose)
        let layout = WidgetCompanionFaceLayout(body: body, face: face)
        guard face == .thriving, let cheeks = layout.cheeks else { return layout.cells(for: face) }
        let row = layout.mouth + cheeks.rowOffset
        return layout.cells(for: face) + [(cheeks.left, row), (cheeks.right, row)]
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
