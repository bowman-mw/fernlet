// WidgetPixelCompanion.swift
// FernletWidgets
//
// The pixel companion every widget draws (World Review Batch 4, approved 2026-10-24: "the companion is
// the pixel companion in its state colour"), with the built-in wardrobe in pixels, glasses in their
// colour and Creation Studio pieces in the 24 × 24 item frame (phone test W-02, W-03 and W-07, approved
// 2026-10-25). The painter between the twin markers is the map's
// (App/Fernlet/World/Companion/WorldCompanionPainter.swift) word for word, with `WorldCompanionLook`
// spelled `WidgetPixelLook`, every other `WorldCompanion` spelled `WidgetCompanion` and no
// `nonisolated`: `WidgetWorldTests` holds the two copies equal, so the app's pixel tests cover this one.
// A widget cannot breathe: it draws the first breath, awake or asleep.

import SwiftUI

/// The painter's name for the companion's band: the snapshot's mirror of the app's `CompanionState`.
typealias WidgetCompanionMood = WidgetCompanionState

// MARK: - Twin: begin

/// One frame of the companion: the 24 × 24 item frame round the 20 × 22 body, each cell an opaque
/// colour or clear (nil). Paint at body coordinates; the frame keeps the body at (2, 1).
struct WidgetCompanionGrid: Equatable, Sendable {
    /// The body's columns: every built-in piece stays inside them.
    static let width = 20
    /// The body's rows.
    static let height = 22
    /// The item frame's columns: two more on each side, so items can reach past the body.
    static let frameWidth = 24
    /// The item frame's rows: one more above and below.
    static let frameHeight = 24
    /// Where the body's left column sits in the frame.
    static let frameX = 2
    /// Where the body's top row sits in the frame.
    static let frameY = 1
    private(set) var cells = [UInt32?](repeating: nil, count: frameWidth * frameHeight)
    /// The face's cells (eyes, mouth, blush, glasses), which a one-colour rendering cuts out.
    private(set) var faceCells = [Bool](repeating: false, count: frameWidth * frameHeight)

    /// The colour at body coordinates (x, y), or nil when clear or outside the frame.
    func color(x: Int, y: Int) -> UInt32? {
        frameColor(x: x + Self.frameX, y: y + Self.frameY)
    }

    /// The colour at frame coordinates (x, y), or nil when clear or out of range.
    func frameColor(x: Int, y: Int) -> UInt32? {
        guard x >= 0, x < Self.frameWidth, y >= 0, y < Self.frameHeight else { return nil }
        return cells[y * Self.frameWidth + x]
    }

    /// Whether the cell at frame coordinates (x, y) is part of the face.
    func isFace(frameX x: Int, y: Int) -> Bool {
        guard x >= 0, x < Self.frameWidth, y >= 0, y < Self.frameHeight else { return false }
        return faceCells[y * Self.frameWidth + x]
    }

    /// Paints one pixel at body coordinates; anything outside the frame is ignored. `face` marks it
    /// as part of the face; a later paint over it clears the mark.
    mutating func put(_ x: Int, _ y: Int, _ hex: UInt32, face: Bool = false) {
        let fx = x + Self.frameX, fy = y + Self.frameY
        guard fx >= 0, fx < Self.frameWidth, fy >= 0, fy < Self.frameHeight else { return }
        cells[fy * Self.frameWidth + fx] = hex
        faceCells[fy * Self.frameWidth + fx] = face
    }
}

/// The companion's body shapes (W-02): the approved circle, and three more.
enum WidgetCompanionShape: Equatable, Sendable {
    /// The approved round body; the only one that breathes and slumps.
    case circle
    /// Squarer, with soft corners: a superellipse.
    case soft
    /// Narrow on top, wide at the base.
    case pear
    /// Low and spread out, with a flat bottom.
    case puddle
}

/// What sits on the head.
enum WidgetCompanionTopper: Equatable, Sendable {
    /// Nothing.
    case none
    /// The sprout: a stem and two leaves.
    case sprout
    /// The flower: a 3 × 3 bloom on a stem with a leaf.
    case flower
    /// The round glasses (on the face; off while the eyes are closed).
    case glasses
}

/// The built-in side item, held against the body's right edge.
enum WidgetCompanionSide: Equatable, Sendable {
    /// Nothing held.
    case none
    /// The water bottle.
    case bottle
    /// The mug, steaming while the companion is awake.
    case mug
    /// The book.
    case book
    /// The dumbbell.
    case dumbbell
}

/// One drawn piece in its place on the frame (a Creation Studio item, already sized to its box):
/// the top-left cell at body coordinates and its colours, row by row.
struct WidgetCompanionItemArt: Equatable, Sendable {
    /// The left column, at body coordinates.
    var x: Int
    /// The top row, at body coordinates.
    var y: Int
    /// Its columns.
    var width: Int
    /// Its rows.
    var height: Int
    /// Row-major colours (`width × height`); nil is clear.
    var cells: [UInt32?]
    /// Whether it sits on the head (a hat), so the sprout and the flower step aside.
    var coversHead: Bool

    /// The colour of its cell (x, y), or nil when clear or out of range.
    func color(x: Int, y: Int) -> UInt32? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        let index = y * width + x
        guard index < cells.count else { return nil }
        return cells[index]
    }
}

/// What the companion wears and how it is coloured, as plain values the painter reads.
struct WidgetPixelLook: Equatable, Sendable {
    /// The body's shape.
    var shape: WidgetCompanionShape
    /// The body's colour.
    var body: UInt32
    /// What sits on the head.
    var topper: WidgetCompanionTopper
    /// The topper's colour; nil when the slot is left on Fern (the sprout's fern, the flower's soft
    /// rose, the glasses' ink).
    var topperColor: UInt32?
    /// The scarf's colour, when it wears the scarf.
    var scarf: UInt32?
    /// The sleep cap's colour, when it wears the cap (the clothing slot, like the scarf).
    var cap: UInt32?
    /// The built-in side item.
    var side: WidgetCompanionSide
    /// The side item's colour.
    var sideColor: UInt32
    /// Creation Studio pieces, in paint order (outfit, held item, face, hat).
    var items: [WidgetCompanionItemArt]

    /// The design's leaf and the app's fern, which the sprout keeps when its slot is left on Fern.
    static let leaf: UInt32 = 0x72A364
    /// The night's neutral body colour (`Color.softTaupe` in light mode), worn asleep.
    static let nightBody: UInt32 = 0xB8A892
    /// The design's scarf red, when the scarf follows the state.
    static let scarfRed: UInt32 = 0xD9532F
    /// The sleep cap's night blue, when the cap follows the state.
    static let capBlue: UInt32 = 0x6E86B0
    /// The side items' bark, when the side item follows the state.
    static let bark: UInt32 = 0x3A2414

    /// A look built from plain values.
    init(body: UInt32, shape: WidgetCompanionShape = .circle, topper: WidgetCompanionTopper = .sprout,
         topperColor: UInt32? = nil, scarf: UInt32? = nil, cap: UInt32? = nil, side: WidgetCompanionSide = .none,
         sideColor: UInt32 = WidgetPixelLook.bark, items: [WidgetCompanionItemArt] = []) {
        self.shape = shape
        self.body = body
        self.topper = topper
        self.topperColor = topperColor
        self.scarf = scarf
        self.cap = cap
        self.side = side
        self.sideColor = sideColor
        self.items = items
    }

    /// The body colour of each band, as `CompanionState.color` resolves in light mode.
    static func stateHex(_ state: WidgetCompanionMood) -> UInt32 {
        switch state {
        case .thriving: 0x5E844D
        case .okay: 0xD2973B
        case .tired: 0xB67073
        case .resting: 0x5C6B78
        case .sick: 0xB9543D
        }
    }

    /// `#RRGGBB` as a number; nil for nil or anything malformed.
    static func value(_ hex: String?) -> UInt32? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }
}

/// The companion's pose for one frame.
struct WidgetCompanionPose: Equatable, Sendable {
    /// The in-breath frame: a touch taller and wider, as Home's breathing scale (the circle only).
    var breathIn = false
    /// The pet-cooldown "settled" slump: happy-arc eyes and a blush (closed lids on a low-energy day).
    var settled = false
    /// Asleep at night: closed eyes, whatever the band; the mug stops steaming.
    var asleep = false
    /// Winding down (`b1-home-night`): the map's night, or the companion's own bedtime before it falls
    /// asleep. The sleepy face (closed eyes, the resting mouth, no blush) in the band's own colour;
    /// asleep adds the night's body colour.
    var drowsy = false
}

/// The body for one frame, with its colours: the shape's centre and radii (the circle grows on the
/// in-breath and slumps when settled), a resting day sitting it lower, and the outline darker with
/// Increase Contrast.
struct WidgetCompanionBody: Sendable {
    let shape: WidgetCompanionShape
    let cx: Double
    let cy: Double
    let rx: Double
    let ry: Double
    let base: UInt32
    let dark: UInt32
    let light: UInt32
    let low: UInt32

    init(state: WidgetCompanionMood, shape: WidgetCompanionShape, color: UInt32, pose: WidgetCompanionPose,
         increasedContrast: Bool) {
        let sink = state == .resting ? 0.6 : 0
        self.shape = shape
        switch shape {
        case .soft: (cx, cy, rx, ry) = (10, 13.4 + sink, 7.3, 6.7)
        case .pear: (cx, cy, rx, ry) = (10, 13.2 + sink, 8.2, 6.9)
        case .puddle: (cx, cy, rx, ry) = (10, 15.3 + sink * 0.5, 8.7, 5.0)
        case .circle where pose.settled: (cx, cy, rx, ry) = (10, 13.7 + sink, 7.9, 6.5)
        case .circle:
            (cx, cy, rx, ry) = (10, (pose.breathIn ? 12.8 : 13.2) + sink, pose.breathIn ? 7.6 : 7.4, pose.breathIn ? 7.3 : 6.9)
        }
        base = color
        dark = WidgetCompanionPainter.mix(color, WidgetCompanionPainter.shade, increasedContrast ? 0.75 : 0.55)
        light = WidgetCompanionPainter.mix(color, 0xFFFFFF, 0.38)
        low = WidgetCompanionPainter.mix(color, WidgetCompanionPainter.shade, 0.18)
    }

    /// The head's top row, where the sprout grows and the cap sits.
    var top: Int { Int((cy - ry).rounded(.up)) }

    /// Whether pixel (px, py)'s centre lies inside the shape.
    func contains(_ px: Int, _ py: Int) -> Bool {
        let dy = (Double(py) + 0.5 - cy) / ry
        switch shape {
        case .soft:
            let dx = (Double(px) + 0.5 - cx) / rx
            return pow(abs(dx), 2.6) + pow(abs(dy), 2.6) <= 1
        case .pear:
            guard abs(dy) <= 1 else { return false }
            let dx = (Double(px) + 0.5 - cx) / (4.5 + 4.0 * ((dy + 1) / 2))
            return dx * dx + dy * dy <= 1
        case .puddle where dy > 0:
            let dx = (Double(px) + 0.5 - cx) / rx
            return pow(abs(dx), 4) + pow(abs(dy), 4) <= 1
        case .circle, .puddle:
            let dx = (Double(px) + 0.5 - cx) / rx
            return dx * dx + dy * dy <= 1
        }
    }
}

/// Paints the companion as the approved pixel art: the body with its outline, highlight and lower
/// shade, the sick day's blanket, the band's face in ink (round eyes, half-lidded when tired, closed
/// when resting, sick, winding down or asleep; the band's mouth; a blush on a thriving day), the
/// built-in wardrobe and the Creation Studio pieces.
enum WidgetCompanionPainter {
    static let ink: UInt32 = 0x2A1A10
    static let blush: UInt32 = 0xE8A3A0
    /// What the darker tones (outline, stem, lower body) mix toward.
    static let shade: UInt32 = 0x1E1008
    /// The cap's brim and pompom, the bottle's cap and the book's pages.
    static let cream: UInt32 = 0xF3E6CB
    /// The flower's centre.
    static let sun: UInt32 = 0xEBB551
    /// The rose the flower's petals soften from when its slot is left on Fern.
    static let rose: UInt32 = 0xB67073

    /// The whole frame.
    static func paint(state: WidgetCompanionMood, look: WidgetPixelLook, pose: WidgetCompanionPose,
                      increasedContrast: Bool = false) -> WidgetCompanionGrid {
        var grid = WidgetCompanionGrid()
        let body = WidgetCompanionBody(state: state, shape: look.shape, color: look.body, pose: pose,
                                      increasedContrast: increasedContrast)
        paintBody(&grid, body: body, sick: state == .sick)
        // The cap and a drawn hat cover the head, so the sprout and the flower step aside.
        if look.cap == nil && !look.items.contains(where: \.coversHead) {
            if look.topper == .sprout { paintSprout(&grid, top: body.top, leaf: look.topperColor) }
            if look.topper == .flower { paintFlower(&grid, top: body.top, petal: look.topperColor) }
        }
        paintFace(&grid, body: body, state: state, pose: pose)
        let eyeRow = Int((body.cy - 1).rounded())
        if look.topper == .glasses && !closesEyes(state: state, pose: pose) {
            paintGlasses(&grid, eyeRow: eyeRow, color: glassesColor(look.topperColor))
        }
        if let scarf = look.scarf { paintScarf(&grid, body: body, color: scarf) }
        if let cap = look.cap { paintCap(&grid, body: body, color: cap) }
        for item in look.items { paintItem(&grid, item) }
        if look.side != .none { paintSide(&grid, body: body, item: look.side, color: look.sideColor, asleep: pose.asleep) }
        return grid
    }

    /// Whether the eyes are closed lines: resting, sick, winding down or asleep (and settled on a
    /// low-energy day).
    static func closesEyes(state: WidgetCompanionMood, pose: WidgetCompanionPose) -> Bool {
        pose.asleep || pose.drowsy || state == .resting || state == .sick
    }

    /// Fills the shape with its outline, highlight, lower shade and (when sick) the blanket.
    private static func paintBody(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody, sick: Bool) {
        for py in 0..<WidgetCompanionGrid.height {
            for px in 0..<WidgetCompanionGrid.width where body.contains(px, py) {
                let edge = !body.contains(px - 1, py) || !body.contains(px + 1, py)
                    || !body.contains(px, py - 1) || !body.contains(px, py + 1)
                let hy = Double(py) - (body.cy - 3.5)
                let inHighlight = Double((px - 7) * (px - 7)) + hy * hy <= 2.3
                var hex = edge ? body.dark : (inHighlight ? body.light : (Double(py) >= body.cy + body.ry - 2.2 ? body.low : body.base))
                if sick && !edge && Double(py) >= (body.cy + 1.5).rounded() {
                    hex = px % 3 == 0 ? 0xD9A57E : 0xF3E6CB
                }
                grid.put(px, py, hex)
            }
        }
    }

    /// The sprout: a darker stem and two leaves, in fern unless the person picked another colour.
    private static func paintSprout(_ grid: inout WidgetCompanionGrid, top: Int, leaf: UInt32?) {
        let leafColor = leaf ?? WidgetPixelLook.leaf
        let stem = mix(leafColor, shade, 0.3)
        grid.put(10, top - 1, stem)
        grid.put(10, top - 2, stem)
        for (x, y) in [(11, top - 3), (12, top - 3), (12, top - 4), (9, top - 3), (8, top - 3)] { grid.put(x, y, leafColor) }
    }

    /// The flower: a fern stem and leaf where the sprout grows, petals in the accessory colour (a soft
    /// rose when the slot is left on Fern) with darker corners, and a sun centre.
    private static func paintFlower(_ grid: inout WidgetCompanionGrid, top: Int, petal: UInt32?) {
        let petals = petal ?? mix(rose, 0xFFFFFF, 0.3)
        let corners = mix(petals, shade, 0.25), stem = mix(WidgetPixelLook.leaf, shade, 0.3)
        grid.put(10, top - 1, stem)
        grid.put(10, top - 2, stem)
        grid.put(11, top - 2, WidgetPixelLook.leaf)
        grid.put(12, top - 3, WidgetPixelLook.leaf)
        for (x, y) in [(10, top - 5), (9, top - 4), (11, top - 4), (10, top - 3)] { grid.put(x, y, petals) }
        for (x, y) in [(9, top - 5), (11, top - 5), (9, top - 3), (11, top - 3)] { grid.put(x, y, corners) }
        grid.put(10, top - 4, sun)
    }

    /// Eyes, mouth and blush, by the band (the design's table) or the settled pose.
    private static func paintFace(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody, state: WidgetCompanionMood,
                                  pose: WidgetCompanionPose) {
        let eyeRow = Int((body.cy - 1).rounded()), mouthRow = Int((body.cy + 2).rounded())
        if pose.settled {
            paintSettledFace(&grid, eyeRow: eyeRow, mouthRow: mouthRow, closed: closesEyes(state: state, pose: pose) || state == .tired)
            return
        }
        if closesEyes(state: state, pose: pose) {
            for x in [6, 7, 12, 13] { grid.put(x, eyeRow + 1, ink, face: true) }
        } else {
            for x in [7, 12] {
                grid.put(x, eyeRow, state == .tired ? body.dark : ink, face: state != .tired)
                grid.put(x, eyeRow + 1, ink, face: true)
            }
        }
        let row = state == .sick ? mouthRow - 1 : mouthRow
        // Winding down (`b1-home-night`) draws the sleepy face whatever the band: the resting mouth, no
        // blush. A sick day keeps its own face.
        let face = pose.drowsy && state != .sick ? WidgetCompanionMood.resting : state
        for (x, dy) in mouth(for: face) { grid.put(x, row + dy, ink, face: true) }
        if face == .thriving {
            grid.put(5, mouthRow - 1, blush, face: true)
            grid.put(14, mouthRow - 1, blush, face: true)
        }
    }

    /// The band's mouth, as (column, row offset) pixels.
    static func mouth(for state: WidgetCompanionMood) -> [(Int, Int)] {
        switch state {
        case .thriving: [(8, 0), (9, 1), (10, 1), (11, 0)]
        case .okay, .resting: [(9, 0), (10, 0)]
        case .tired: [(9, 1), (10, 1)]
        case .sick: [(8, 0), (9, -1), (10, 0), (11, -1)]
        }
    }

    /// The settled pose: happy-arc eyes (closed lids on a low-energy day), a wide smile and a blush.
    private static func paintSettledFace(_ grid: inout WidgetCompanionGrid, eyeRow: Int, mouthRow: Int, closed: Bool) {
        for x in [7, 12] {
            grid.put(x - 1, eyeRow + 1, ink, face: true)
            grid.put(x, closed ? eyeRow + 1 : eyeRow, ink, face: true)
            if !closed { grid.put(x + 1, eyeRow + 1, ink, face: true) }
        }
        for (x, dy) in [(8, 0), (9, 1), (10, 1), (11, 0)] { grid.put(x, mouthRow + dy, ink, face: true) }
        grid.put(5, mouthRow - 1, blush, face: true)
        grid.put(14, mouthRow - 1, blush, face: true)
    }

    /// The glasses' frames (W-03): ink when the slot is left on Fern, else the accessory colour mixed
    /// 30 % toward ink, or 50 % for a light colour (Sun, Cream), so they still read on a body of the
    /// same colour.
    static func glassesColor(_ accessory: UInt32?) -> UInt32 {
        guard let accessory else { return ink }
        return mix(accessory, ink, luminance(accessory) > 0.62 ? 0.5 : 0.3)
    }

    /// A colour's perceived lightness, 0 (black) to 1 (white).
    static func luminance(_ hex: UInt32) -> Double {
        let red = Double((hex >> 16) & 0xFF), green = Double((hex >> 8) & 0xFF), blue = Double(hex & 0xFF)
        return (0.299 * red + 0.587 * green + 0.114 * blue) / 255
    }

    /// Round glasses over both eyes, joined by a bridge.
    private static func paintGlasses(_ grid: inout WidgetCompanionGrid, eyeRow: Int, color: UInt32) {
        for ex in [7, 12] {
            for gx in (ex - 1)...(ex + 1) {
                grid.put(gx, eyeRow - 1, color, face: true)
                grid.put(gx, eyeRow + 2, color, face: true)
            }
            for gy in [eyeRow, eyeRow + 1] {
                grid.put(ex - 1, gy, color, face: true)
                grid.put(ex + 1, gy, color, face: true)
            }
        }
        grid.put(9, eyeRow, color, face: true)
        grid.put(10, eyeRow, color, face: true)
    }

    /// A scarf wrapped low on the body, with a tail.
    private static func paintScarf(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody, color: UInt32) {
        let row = Int((body.cy + 3.5).rounded())
        for x in 4...15 where body.contains(x, row) { grid.put(x, row, color) }
        grid.put(13, row + 1, color)
        grid.put(13, row + 2, mix(color, shade, 0.25))
    }

    /// The sleep cap: a cream brim on the head's top row + 1, a cone drooping to the right with its
    /// darker edge, and a cream 2 × 2 pompom at columns 16–17.
    private static func paintCap(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody, color: UInt32) {
        let top = body.top, edge = mix(color, shade, 0.25)
        for x in 4...15 where body.contains(x, top + 1) { grid.put(x, top + 1, cream) }
        for (row, from, to) in [(top, 6, 13), (top - 1, 7, 13), (top - 2, 8, 13), (top - 3, 10, 14), (top - 4, 12, 15)] {
            for x in from...to { grid.put(x, row, x == to ? edge : color) }
        }
        grid.put(16, top - 3, edge)
        grid.put(16, top - 2, edge)
        for (x, y) in [(16, top - 1), (17, top - 1), (16, top), (17, top)] { grid.put(x, y, cream) }
    }

    /// A side item's 6 × 8 picture, row by row: `k` ink, `c` its colour, `l` lighter, `d` darker,
    /// `w` cream, `b` water, `h` the dumbbell's grip, `s` the mug's steam.
    static func sideRows(_ item: WidgetCompanionSide) -> [String] {
        switch item {
        case .none: []
        case .bottle: ["..ww..", "..kk..", ".kcck.", ".kclk.", ".kbbk.", ".kcck.", ".kcck.", "..kk.."]
        case .mug: [".s.s..", "..s...", "......", "kkkk..", "kclkk.", "kcck.k", "kcckk.", "kkkk.."]
        case .book: ["......", "kkkkk.", "kdcck.", "kdwck.", "kdcck.", "kdcck.", "kdcck.", "kkkkk."]
        case .dumbbell: ["......", "kk..kk", "cc..cc", "cchhcc", "cc..cc", "kk..kk", "......", "......"]
        }
    }

    /// The side item at columns 14–19, from the row above the body's centre: held against its right
    /// edge. The mug's steam stops while the companion sleeps.
    private static func paintSide(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody, item: WidgetCompanionSide,
                                  color: UInt32, asleep: Bool) {
        var palette: [Character: UInt32] = ["k": ink, "c": color, "l": mix(color, 0xFFFFFF, 0.4), "d": mix(color, shade, 0.35),
                                            "w": cream, "b": 0x9CC9E4, "h": 0x9A948C]
        if !asleep { palette["s"] = 0xE9E1D0 }
        let x0 = 14, y0 = Int(body.cy.rounded()) - 1
        for (dy, row) in sideRows(item).enumerated() {
            for (dx, key) in row.enumerated() {
                guard let hex = palette[key] else { continue }
                grid.put(x0 + dx, y0 + dy, hex)
            }
        }
    }

    /// A Creation Studio piece, cell for cell in its place.
    private static func paintItem(_ grid: inout WidgetCompanionGrid, _ item: WidgetCompanionItemArt) {
        for y in 0..<max(0, item.height) {
            for x in 0..<max(0, item.width) {
                guard let hex = item.color(x: x, y: y) else { continue }
                grid.put(item.x + x, item.y + y, hex)
            }
        }
    }

    /// Blends `hex` toward `target` by `fraction` (0 keeps `hex`).
    static func mix(_ hex: UInt32, _ target: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) }
        func blend(_ shift: UInt32) -> UInt32 {
            let value = channel(hex, shift) + (channel(target, shift) - channel(hex, shift)) * fraction
            return UInt32(min(max(value.rounded(), 0), 255)) << shift
        }
        return blend(16) | blend(8) | blend(0)
    }
}

// MARK: - Twin: end

extension WidgetPixelLook {
    /// The look for the snapshot's `look` on a day in `state` (nil: no state yet today). Asleep, and a
    /// day with no state, wear the night's body colour where the body follows the state. The tokens are
    /// the app's FROZEN raw values; an unknown one (a newer app's cosmetic) draws nothing in its place.
    init(look: WidgetCompanionLook, state: WidgetCompanionState?, asleep: Bool) {
        let fixedBody = Self.value(look.bodyColorHex)
        let stateBody = state.map { Self.stateHex($0) } ?? Self.nightBody
        let accessory = Self.value(look.accessoryColorHex)
        self.init(body: fixedBody ?? (asleep ? Self.nightBody : stateBody),
                  shape: Self.shape(look.bodyStyleRaw),
                  topper: Self.topper(look.accessoryRaw),
                  topperColor: accessory == Self.leaf ? nil : accessory,
                  scarf: Self.value(look.scarfColorHex),
                  cap: Self.value(look.capColorHex),
                  side: Self.side(look.sideItemRaw),
                  sideColor: Self.value(look.sideItemColorHex) ?? Self.bark,
                  items: (look.items ?? []).prefix(Self.maxItems).compactMap(Self.item(_:)))
    }

    /// The most pieces a look carries: one per Creation Studio kind.
    static let maxItems = 4

    /// The app's `CompanionBodyStyle` token as a shape.
    static func shape(_ token: String) -> WidgetCompanionShape {
        switch token {
        case "softBlob": .soft
        case "pear": .pear
        case "puddle": .puddle
        default: .circle
        }
    }

    /// The app's `CompanionAccessory` token as a topper.
    static func topper(_ token: String) -> WidgetCompanionTopper {
        switch token {
        case "sprout": .sprout
        case "flower": .flower
        case "glasses": .glasses
        default: .none
        }
    }

    /// The app's `CompanionSideItem` token as a side item; nil or unknown holds nothing.
    static func side(_ token: String?) -> WidgetCompanionSide {
        switch token {
        case "waterBottle": .bottle
        case "mug": .mug
        case "book": .book
        case "dumbbell": .dumbbell
        default: .none
        }
    }

    /// A published piece as art, kept inside the item frame; nil when malformed.
    static func item(_ art: WidgetCompanionLook.ItemArt) -> WidgetCompanionItemArt? {
        let frame = WidgetCompanionGrid.self
        guard art.width > 0, art.height > 0, art.width <= frame.frameWidth, art.height <= frame.frameHeight,
              art.pixels.count == art.width * art.height,
              art.x >= -frame.frameX, art.y >= -frame.frameY,
              art.x + art.width <= frame.frameWidth - frame.frameX,
              art.y + art.height <= frame.frameHeight - frame.frameY else { return nil }
        let colours = art.palette.prefix(maxPalette).map { Self.value($0) }
        let cells: [UInt32?] = art.pixels.map { $0 >= 0 && $0 < colours.count ? colours[$0] : nil }
        return WidgetCompanionItemArt(x: art.x, y: art.y, width: art.width, height: art.height, cells: cells,
                                      coversHead: art.coversHead)
    }

    /// The most colours a published piece keeps (the Studio's palette has sixteen).
    static let maxPalette = 64
}

extension WidgetCompanionPainter {
    /// The widget's frame: the first breath, asleep or awake. A day with no state draws the thriving
    /// face on the night body, as today's widget does.
    static func paint(state: WidgetCompanionState?, look: WidgetPixelLook, asleep: Bool,
                      increasedContrast: Bool = false) -> WidgetCompanionGrid {
        paint(state: state ?? .thriving, look: look, pose: WidgetCompanionPose(asleep: asleep),
              increasedContrast: increasedContrast)
    }
}

/// How the companion is painted for one surface.
enum WidgetCompanionInk: Equatable {
    /// Its own colours, over the soft ground shadow.
    case color
    /// One colour, face cut out: the Lock Screen and the tinted and clear Home Screens (white, which
    /// iOS tints), or the placeholder's pale ghost.
    case silhouette(UInt32)
}

/// The companion as a pixel sprite in its 24 × 24 item frame, with the asleep "z" beside it — what every
/// widget family draws.
///
/// One `Canvas`, hidden from VoiceOver: each family labels the element around it.
struct WidgetCompanionSprite: View {
    let grid: WidgetCompanionGrid
    /// Points per sprite pixel.
    var scale: CGFloat = 3
    var ink: WidgetCompanionInk = .color
    /// Draws the pixel "z" at the top right (asleep).
    var showsZee = false
    @Environment(\.redactionReasons) private var redaction

    /// The sprite's size at `scale`: the whole item frame, so a drawn piece never clips.
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(WidgetCompanionGrid.frameWidth) * scale, height: CGFloat(WidgetCompanionGrid.frameHeight) * scale)
    }

    var body: some View {
        // A Canvas is not redacted by iOS on its own: under the privacy reason (a locked Lock Screen,
        // StandBy) the companion gives way to a round placeholder, so its state face never shows.
        let hidden = redaction.contains(.privacy)
        Group {
            if hidden {
                Circle().fill(.tertiary).padding(scale * 4)
            } else {
                canvas
            }
        }
        .frame(width: Self.size(scale: scale).width, height: Self.size(scale: scale).height)
        .overlay(alignment: .topTrailing) {
            if showsZee && !hidden {
                // Where it sat beside the 20 × 22 body before the frame grew round it.
                WidgetSpriteView(sprite: WidgetSprites.zee, scale: scale, paint: zeePaint)
                    .offset(x: scale * 2.5, y: scale)
            }
        }
        .accessibilityHidden(true)
    }

    private var zeePaint: WidgetSpritePaint {
        if case .silhouette(let hex) = ink { return .solid(hex) }
        return .plain
    }

    private var canvas: some View {
        Canvas { context, _ in
            let originX = CGFloat(WidgetCompanionGrid.frameX), originY = CGFloat(WidgetCompanionGrid.frameY)
            if ink == .color {
                context.fill(Path(CGRect(x: (originX + 5) * scale, y: (originY + 21) * scale, width: 10 * scale, height: scale)),
                             with: .color(Color(.sRGB, red: 40 / 255, green: 22 / 255, blue: 8 / 255, opacity: 0.28)))
            }
            for y in 0..<WidgetCompanionGrid.frameHeight {
                for x in 0..<WidgetCompanionGrid.frameWidth {
                    guard let hex = paintedColour(x: x, y: y) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)),
                                 with: .color(Color(widgetRGB: hex)))
                }
            }
        }
    }

    /// A frame cell's colour on this surface: its own, or the silhouette's with the face cut out.
    private func paintedColour(x: Int, y: Int) -> UInt32? {
        guard let cell = grid.frameColor(x: x, y: y) else { return nil }
        switch ink {
        case .color: return cell
        case .silhouette(let hex): return grid.isFace(frameX: x, y: y) ? nil : hex
        }
    }
}
