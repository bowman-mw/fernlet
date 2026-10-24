import Foundation
import FernletDomainModel

/// One frame of the map companion: a 20 × 22 grid of opaque colours (nil is clear).
nonisolated struct WorldCompanionGrid: Equatable, Sendable {
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

/// What the map companion wears and how it is coloured, resolved from the person's
/// `CompanionAppearance` (the same colours Home's companion and the widget use).
///
/// Only the wardrobe with an approved pixel version is drawn (design page answer 27): the sprout,
/// the round glasses and the scarf. The flower, the sleep cap, the side items, the other body shapes
/// and the person's own Creation Studio items are left off the map sprite until their pixel art is
/// approved; they still show everywhere else the companion is drawn.
nonisolated struct WorldCompanionLook: Equatable, Sendable {
    /// What sits on the head.
    enum Topper: Equatable, Sendable { case none, sprout, glasses }

    var body: UInt32
    var topper: Topper
    var topperColor: UInt32?
    var scarf: UInt32?

    /// The design's leaf and the app's fern, which the sprout keeps when its slot is left on Fern.
    static let leaf: UInt32 = 0x72A364
    /// The night's neutral body colour (`Color.softTaupe` in light mode), as Home's sleeping companion.
    static let nightBody: UInt32 = 0xB8A892
    /// The design's scarf red, used when the scarf follows the state.
    static let scarfRed: UInt32 = 0xD9532F

    /// The look for `appearance` on a day in `state`; `asleep` wears the night's neutral body colour
    /// where the body follows the state, as Home's companion does while it sleeps. Main actor: the
    /// named colours resolve through the widget's colour mirror, which is the app's.
    @MainActor
    init(appearance: CompanionAppearance, state: CompanionState, asleep: Bool) {
        let fixedBody = Self.value(WidgetSnapshot.CompanionLook.hex(custom: appearance.bodyCustomColorHex, slot: appearance.bodyColor))
        body = fixedBody ?? (asleep ? Self.nightBody : Self.stateHex(state))
        switch appearance.accessory {
        case .sprout: topper = .sprout
        case .glasses: topper = .glasses
        case .none, .flower: topper = .none
        }
        let accessory = Self.value(WidgetSnapshot.CompanionLook.hex(custom: appearance.accessoryCustomColorHex, slot: appearance.accessoryColor))
        topperColor = appearance.accessoryColor == .fern && appearance.accessoryCustomColorHex == nil ? nil : accessory
        let clothing = Self.value(WidgetSnapshot.CompanionLook.hex(custom: appearance.clothingCustomColorHex, slot: appearance.clothingColor))
        scarf = appearance.clothing == .scarf ? (clothing ?? Self.scarfRed) : nil
    }

    /// A look built directly (tests, previews).
    init(body: UInt32, topper: Topper = .sprout, topperColor: UInt32? = nil, scarf: UInt32? = nil) {
        self.body = body
        self.topper = topper
        self.topperColor = topperColor
        self.scarf = scarf
    }

    /// The body colour of each band, as `CompanionState.color` resolves in light mode.
    static func stateHex(_ state: CompanionState) -> UInt32 {
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
nonisolated struct WorldCompanionPose: Equatable, Sendable {
    /// The in-breath frame: a touch taller and wider, as Home's breathing scale.
    var breathIn = false
    /// The pet-cooldown "settled" slump: happy-arc eyes and a blush (closed lids on a low-energy day).
    var settled = false
    /// Asleep at night: closed eyes, whatever the band.
    var asleep = false
    /// Winding down (`b1-home-night`): the map's night, or the companion's own bedtime before it falls
    /// asleep. The sleepy face (closed eyes, the resting mouth, no blush) in the band's own colour;
    /// asleep adds the night's body colour.
    var drowsy = false
}

/// Paints the map companion as the approved pixel art (design `b1-home-day`'s `pixComp`, the World
/// Shell prototype's settled pose): the body ellipse with its outline, highlight and lower shade, the
/// sick day's blanket, the band's face in ink (round eyes, half-lidded when tired, closed when resting,
/// sick or asleep; the band's mouth; a blush on a thriving day) and the approved wardrobe.
nonisolated enum WorldCompanionPainter {
    static let ink: UInt32 = 0x2A1A10
    static let blush: UInt32 = 0xE8A3A0

    /// The whole frame.
    static func paint(state: CompanionState, look: WorldCompanionLook, pose: WorldCompanionPose) -> WorldCompanionGrid {
        var grid = WorldCompanionGrid()
        let body = WorldCompanionBody(state: state, color: look.body, pose: pose)
        paintBody(&grid, body: body, sick: state == .sick)
        let top = Int((body.cy - body.ry).rounded(.up))
        if look.topper == .sprout { paintSprout(&grid, top: top, leaf: look.topperColor) }
        paintFace(&grid, body: body, state: state, pose: pose)
        let eyeRow = Int((body.cy - 1).rounded())
        if look.topper == .glasses && !closesEyes(state: state, pose: pose) { paintGlasses(&grid, eyeRow: eyeRow) }
        if let scarf = look.scarf { paintScarf(&grid, body: body, color: scarf) }
        return grid
    }

    /// Whether the eyes are closed lines: resting, sick, winding down or asleep (and settled on a
    /// low-energy day).
    static func closesEyes(state: CompanionState, pose: WorldCompanionPose) -> Bool {
        pose.asleep || pose.drowsy || state == .resting || state == .sick
    }

    /// Fills the ellipse with its outline, highlight, lower shade and (when sick) the blanket.
    private static func paintBody(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, sick: Bool) {
        for py in 0..<WorldCompanionGrid.height {
            for px in 0..<WorldCompanionGrid.width where body.contains(px, py) {
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
    private static func paintSprout(_ grid: inout WorldCompanionGrid, top: Int, leaf: UInt32?) {
        let leafColor = leaf ?? WorldCompanionLook.leaf
        let stem = mix(leafColor, 0x1E1008, 0.3)
        grid.put(10, top - 1, stem)
        grid.put(10, top - 2, stem)
        for (x, y) in [(11, top - 3), (12, top - 3), (12, top - 4), (9, top - 3), (8, top - 3)] { grid.put(x, y, leafColor) }
    }

    /// Eyes, mouth and blush, by the band (the design's table) or the settled pose.
    private static func paintFace(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, state: CompanionState, pose: WorldCompanionPose) {
        let eyeRow = Int((body.cy - 1).rounded()), mouthRow = Int((body.cy + 2).rounded())
        if pose.settled {
            paintSettledFace(&grid, eyeRow: eyeRow, mouthRow: mouthRow, closed: closesEyes(state: state, pose: pose) || state == .tired)
            return
        }
        if closesEyes(state: state, pose: pose) {
            for x in [6, 7, 12, 13] { grid.put(x, eyeRow + 1, ink) }
        } else {
            for x in [7, 12] {
                grid.put(x, eyeRow, state == .tired ? body.dark : ink)
                grid.put(x, eyeRow + 1, ink)
            }
        }
        let row = state == .sick ? mouthRow - 1 : mouthRow
        // Winding down (`b1-home-night`) draws the sleepy face whatever the band: the resting mouth, no
        // blush. A sick day keeps its own face.
        let face = pose.drowsy && state != .sick ? CompanionState.resting : state
        for (x, dy) in mouth(for: face) { grid.put(x, row + dy, ink) }
        if face == .thriving {
            grid.put(5, mouthRow - 1, blush)
            grid.put(14, mouthRow - 1, blush)
        }
    }

    /// The band's mouth, as (column, row offset) pixels.
    static func mouth(for state: CompanionState) -> [(Int, Int)] {
        switch state {
        case .thriving: [(8, 0), (9, 1), (10, 1), (11, 0)]
        case .okay, .resting: [(9, 0), (10, 0)]
        case .tired: [(9, 1), (10, 1)]
        case .sick: [(8, 0), (9, -1), (10, 0), (11, -1)]
        }
    }

    /// The settled pose: happy-arc eyes (closed lids on a low-energy day), a wide smile and a blush.
    private static func paintSettledFace(_ grid: inout WorldCompanionGrid, eyeRow: Int, mouthRow: Int, closed: Bool) {
        for x in [7, 12] {
            grid.put(x - 1, eyeRow + 1, ink)
            grid.put(x, closed ? eyeRow + 1 : eyeRow, ink)
            if !closed { grid.put(x + 1, eyeRow + 1, ink) }
        }
        for (x, dy) in [(8, 0), (9, 1), (10, 1), (11, 0)] { grid.put(x, mouthRow + dy, ink) }
        grid.put(5, mouthRow - 1, blush)
        grid.put(14, mouthRow - 1, blush)
    }

    /// Round glasses over both eyes, joined by a bridge.
    private static func paintGlasses(_ grid: inout WorldCompanionGrid, eyeRow: Int) {
        for ex in [7, 12] {
            for gx in (ex - 1)...(ex + 1) { grid.put(gx, eyeRow - 1, ink); grid.put(gx, eyeRow + 2, ink) }
            for gy in [eyeRow, eyeRow + 1] { grid.put(ex - 1, gy, ink); grid.put(ex + 1, gy, ink) }
        }
        grid.put(9, eyeRow, ink)
        grid.put(10, eyeRow, ink)
    }

    /// A scarf wrapped low on the body, with a tail.
    private static func paintScarf(_ grid: inout WorldCompanionGrid, body: WorldCompanionBody, color: UInt32) {
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

/// The body ellipse for one frame, with its colours: the breath grows it a little, the settled pose
/// slumps it wider than tall, and a resting day sits it lower.
nonisolated struct WorldCompanionBody: Sendable {
    let cx: Double
    let cy: Double
    let rx: Double
    let ry: Double
    let base: UInt32
    let dark: UInt32
    let light: UInt32
    let low: UInt32

    init(state: CompanionState, color: UInt32, pose: WorldCompanionPose) {
        let sink = state == .resting ? 0.6 : 0
        if pose.settled {
            (cx, cy, rx, ry) = (10, 13.7 + sink, 7.9, 6.5)
        } else {
            (cx, cy, rx, ry) = (10, (pose.breathIn ? 12.8 : 13.2) + sink, pose.breathIn ? 7.6 : 7.4, pose.breathIn ? 7.3 : 6.9)
        }
        base = color
        dark = WorldCompanionPainter.mix(color, 0x1E1008, 0.55)
        light = WorldCompanionPainter.mix(color, 0xFFFFFF, 0.38)
        low = WorldCompanionPainter.mix(color, 0x1E1008, 0.18)
    }

    /// Whether pixel (px, py)'s centre lies inside the ellipse.
    func contains(_ px: Int, _ py: Int) -> Bool {
        let dx = (Double(px) + 0.5 - cx) / rx, dy = (Double(py) + 0.5 - cy) / ry
        return dx * dx + dy * dy <= 1
    }
}
