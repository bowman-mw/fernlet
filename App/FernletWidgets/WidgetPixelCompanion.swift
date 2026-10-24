// WidgetPixelCompanion.swift
// FernletWidgets
//
// The pixel companion every widget draws (World Review Batch 4, approved 2026-10-24: "the companion is
// the pixel companion in its state colour"). A hand-copied twin of the map's painter
// (App/Fernlet/World/Companion/WorldCompanionPainter.swift): the same 20 × 22 grid, body ellipse,
// highlight, shade, sick blanket, faces, sprout, glasses and scarf, held still on its first breath.
// `WidgetWorldTwinTests` pins the painter's tables and constants line for line against the app's.

import SwiftUI

/// One frame of the companion: a 20 × 22 grid of opaque colours (nil is clear). The twin of the app's
/// `WorldCompanionGrid`.
struct WidgetCompanionGrid: Equatable {
    static let width = 20
    static let height = 22
    private(set) var cells = [UInt32?](repeating: nil, count: width * height)

    /// The colour at (x, y), or nil when clear or out of range.
    func color(x: Int, y: Int) -> UInt32? {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return nil }
        return cells[y * Self.width + x]
    }

    /// Paints one pixel; out-of-range pixels are ignored.
    mutating func put(_ x: Int, _ y: Int, _ hex: UInt32) {
        guard x >= 0, x < Self.width, y >= 0, y < Self.height else { return }
        cells[y * Self.width + x] = hex
    }
}

/// What the companion wears and its colours, from the snapshot's ``WidgetCompanionLook`` — the twin of
/// the app's `WorldCompanionLook`. Only the wardrobe with approved pixel art is drawn: the sprout, the
/// round glasses and the scarf; the flower and the other body shapes stay in the app, as on the map.
struct WidgetPixelLook: Equatable {
    /// What sits on the head.
    enum Topper: Equatable { case none, sprout, glasses }

    var body: UInt32
    var topper: Topper
    var topperColor: UInt32?
    var scarf: UInt32?

    /// The design's leaf and the app's fern.
    static let leaf: UInt32 = 0x72A364
    /// The night's neutral body colour, worn asleep and before today has a state.
    static let nightBody: UInt32 = 0xB8A892

    /// The look for `look` on a day in `state` (nil: no state yet today); asleep and a day with no
    /// state wear the night's body colour where the body follows the state.
    init(look: WidgetCompanionLook, state: WidgetCompanionState?, asleep: Bool) {
        let fixedBody = Self.value(look.bodyColorHex)
        body = fixedBody ?? (asleep || state == nil ? Self.nightBody : Self.stateHex(state))
        switch look.accessoryRaw {
        case "sprout": topper = .sprout
        case "glasses": topper = .glasses
        default: topper = .none
        }
        topperColor = Self.value(look.accessoryColorHex)
        scarf = Self.value(look.scarfColorHex)
    }

    /// The body colour of each state, as the app's `WorldCompanionLook.stateHex`.
    static func stateHex(_ state: WidgetCompanionState?) -> UInt32 {
        switch state {
        case .thriving: 0x5E844D
        case .okay: 0xD2973B
        case .tired: 0xB67073
        case .resting: 0x5C6B78
        case .sick: 0xB9543D
        case nil: nightBody
        }
    }

    /// `#RRGGBB` as a number; nil for nil or anything malformed.
    static func value(_ hex: String?) -> UInt32? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7 else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }
}

/// Paints the companion as the approved pixel art — the twin of the app's `WorldCompanionPainter`,
/// still on its first breath (a widget cannot breathe). A day with no state draws the thriving face on
/// the night body, as today's widget does.
enum WidgetCompanionPainter {
    static let ink: UInt32 = 0x2A1A10
    static let blush: UInt32 = 0xE8A3A0

    /// The whole frame.
    static func paint(state: WidgetCompanionState?, look: WidgetPixelLook, asleep: Bool) -> WidgetCompanionGrid {
        let face = state ?? .thriving
        var grid = WidgetCompanionGrid()
        let body = WidgetCompanionBody(state: face, color: look.body)
        paintBody(&grid, body: body, sick: face == .sick)
        let top = Int((body.cy - body.ry).rounded(.up))
        if look.topper == .sprout { paintSprout(&grid, top: top, leaf: look.topperColor) }
        paintFace(&grid, body: body, state: face, asleep: asleep)
        let eyeRow = Int((body.cy - 1).rounded())
        if look.topper == .glasses && !closesEyes(state: face, asleep: asleep) { paintGlasses(&grid, eyeRow: eyeRow) }
        if let scarf = look.scarf { paintScarf(&grid, body: body, color: scarf) }
        return grid
    }

    /// Whether the eyes are closed lines: resting, sick or asleep.
    static func closesEyes(state: WidgetCompanionState, asleep: Bool) -> Bool {
        asleep || state == .resting || state == .sick
    }

    /// Whether a cell is part of the face (eyes, mouth, glasses, blush) — what the one-colour
    /// rendering cuts out of the body so the expression survives one tint.
    static func isFace(_ hex: UInt32) -> Bool {
        hex == ink || hex == blush
    }

    /// Fills the ellipse with its outline, highlight, lower shade and (when sick) the blanket.
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
        let stem = mix(leafColor, 0x1E1008, 0.3)
        grid.put(10, top - 1, stem)
        grid.put(10, top - 2, stem)
        for (x, y) in [(11, top - 3), (12, top - 3), (12, top - 4), (9, top - 3), (8, top - 3)] { grid.put(x, y, leafColor) }
    }

    /// Eyes, mouth and blush, by the state (the design's table).
    private static func paintFace(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody,
                                  state: WidgetCompanionState, asleep: Bool) {
        let eyeRow = Int((body.cy - 1).rounded()), mouthRow = Int((body.cy + 2).rounded())
        if closesEyes(state: state, asleep: asleep) {
            for x in [6, 7, 12, 13] { grid.put(x, eyeRow + 1, ink) }
        } else {
            for x in [7, 12] {
                grid.put(x, eyeRow, state == .tired ? body.dark : ink)
                grid.put(x, eyeRow + 1, ink)
            }
        }
        let row = state == .sick ? mouthRow - 1 : mouthRow
        for (x, dy) in mouth(for: state) { grid.put(x, row + dy, ink) }
        if state == .thriving {
            grid.put(5, mouthRow - 1, blush)
            grid.put(14, mouthRow - 1, blush)
        }
    }

    /// The state's mouth, as (column, row offset) pixels.
    static func mouth(for state: WidgetCompanionState) -> [(Int, Int)] {
        switch state {
        case .thriving: [(8, 0), (9, 1), (10, 1), (11, 0)]
        case .okay, .resting: [(9, 0), (10, 0)]
        case .tired: [(9, 1), (10, 1)]
        case .sick: [(8, 0), (9, -1), (10, 0), (11, -1)]
        }
    }

    /// Round glasses over both eyes, joined by a bridge.
    private static func paintGlasses(_ grid: inout WidgetCompanionGrid, eyeRow: Int) {
        for ex in [7, 12] {
            for gx in (ex - 1)...(ex + 1) { grid.put(gx, eyeRow - 1, ink); grid.put(gx, eyeRow + 2, ink) }
            for gy in [eyeRow, eyeRow + 1] { grid.put(ex - 1, gy, ink); grid.put(ex + 1, gy, ink) }
        }
        grid.put(9, eyeRow, ink)
        grid.put(10, eyeRow, ink)
    }

    /// A scarf wrapped low on the body, with a tail.
    private static func paintScarf(_ grid: inout WidgetCompanionGrid, body: WidgetCompanionBody, color: UInt32) {
        let row = Int((body.cy + 3.5).rounded())
        for x in 4...15 where body.contains(x, row) { grid.put(x, row, color) }
        grid.put(13, row + 1, color)
        grid.put(13, row + 2, mix(color, 0x1E1008, 0.25))
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

/// The body ellipse with its colours — the twin of the app's `WorldCompanionBody` on the first breath
/// (`breathIn` false, not settled): a resting day sits it lower.
struct WidgetCompanionBody {
    let cx: Double
    let cy: Double
    let rx: Double
    let ry: Double
    let base: UInt32
    let dark: UInt32
    let light: UInt32
    let low: UInt32

    init(state: WidgetCompanionState, color: UInt32) {
        let sink = state == .resting ? 0.6 : 0
        (cx, cy, rx, ry) = (10, 13.2 + sink, 7.4, 6.9)
        base = color
        dark = WidgetCompanionPainter.mix(color, 0x1E1008, 0.55)
        light = WidgetCompanionPainter.mix(color, 0xFFFFFF, 0.38)
        low = WidgetCompanionPainter.mix(color, 0x1E1008, 0.18)
    }

    /// Whether pixel (px, py)'s centre lies inside the ellipse.
    func contains(_ px: Int, _ py: Int) -> Bool {
        let dx = (Double(px) + 0.5 - cx) / rx, dy = (Double(py) + 0.5 - cy) / ry
        return dx * dx + dy * dy <= 1
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

/// The companion as a pixel sprite, with the asleep "z" beside it — what every widget family draws.
///
/// One `Canvas`, hidden from VoiceOver: each family labels the element around it.
struct WidgetCompanionSprite: View {
    let grid: WidgetCompanionGrid
    /// Points per sprite pixel.
    var scale: CGFloat = 3
    var ink: WidgetCompanionInk = .color
    /// Draws the pixel "z" at the top right (asleep).
    var showsZee = false

    /// The sprite's size at `scale`.
    static func size(scale: CGFloat) -> CGSize {
        CGSize(width: CGFloat(WidgetCompanionGrid.width) * scale, height: CGFloat(WidgetCompanionGrid.height) * scale)
    }

    var body: some View {
        canvas
            .frame(width: Self.size(scale: scale).width, height: Self.size(scale: scale).height)
            .overlay(alignment: .topTrailing) {
                if showsZee {
                    WidgetSpriteView(sprite: WidgetSprites.zee, scale: scale, paint: zeePaint)
                        .offset(x: scale * 4.5, y: 0)
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
            if ink == .color {
                context.fill(Path(CGRect(x: 5 * scale, y: 21 * scale, width: 10 * scale, height: scale)),
                             with: .color(Color(.sRGB, red: 40 / 255, green: 22 / 255, blue: 8 / 255, opacity: 0.28)))
            }
            for y in 0..<WidgetCompanionGrid.height {
                for x in 0..<WidgetCompanionGrid.width {
                    guard let hex = paintedColour(grid.color(x: x, y: y)) else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: scale, height: scale)),
                                 with: .color(Color(widgetRGB: hex)))
                }
            }
        }
    }

    /// A cell's colour on this surface: its own, or the silhouette's with the face cut out.
    private func paintedColour(_ cell: UInt32?) -> UInt32? {
        guard let cell else { return nil }
        switch ink {
        case .color: return cell
        case .silhouette(let hex): return WidgetCompanionPainter.isFace(cell) ? nil : hex
        }
    }
}
