import Foundation

/// How the companion is getting about: on foot, pedalling, or riding along in a car or bus.
nonisolated enum CompanionRide: String, CaseIterable, Identifiable, Sendable {
    case onFoot, bike, car

    var id: String { rawValue }

    /// The fixture control's label.
    var label: String {
        switch self {
        case .onFoot: "On foot"
        case .bike: "On a bike"
        case .car: "In a car or bus"
        }
    }
}

/// The built-in wardrobe items that have a hand-drawn pixel version (design page, answer 27).
nonisolated enum Outfit: String, CaseIterable, Identifiable, Sendable {
    case none, glasses, beanie, scarf

    var id: String { rawValue }

    /// The wardrobe button's label.
    var label: String {
        switch self {
        case .none: "Just Fernlet"
        case .glasses: "Round glasses"
        case .beanie: "Beanie"
        case .scarf: "Scarf"
        }
    }
}

/// One frame of the companion sprite: a 20 × 22 grid of opaque colours (nil is clear).
nonisolated struct PixelGrid: Sendable {
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

    /// Paints a filled rectangle of pixels.
    mutating func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ hex: UInt32) {
        for dy in 0..<max(0, h) { for dx in 0..<max(0, w) { put(x + dx, y + dy, hex) } }
    }
}

/// The companion's pose for one frame.
nonisolated struct CompanionPose: Sendable {
    /// The in-breath frame: a touch taller and wider, as `CompanionView`'s breath scale.
    var breathIn = false
    /// Walking: feet alternate and the body bobs.
    var walking = false
    /// Step counter while walking or riding; its parity picks the frame.
    var step = 0
    /// The pet-cooldown "settled" slump: happy-arc eyes (closed on a low-energy day) and a blush.
    var settled = false
}

/// Paints the companion as pixel art: the standard appearance (circle body, fern sprout) in the
/// state's colour, the state's face, and the hand-drawn wardrobe items.
///
/// The body, highlight, sprout and outfits follow the design page's `drawBlob`; the face follows
/// the shipping `CompanionExpression.stateFace`: round eyes, half-lids on a low-energy day, and the
/// soft white mouth bar whose height is set by the band (`CompanionState.mouthHeight`).
nonisolated enum PixelCompanionPainter {
    static let ink: UInt32 = 0x2A1A10

    /// The whole frame for a state, ride, outfit and pose.
    static func paint(state: ShellCompanionState, ride: CompanionRide, outfit: Outfit, pose: CompanionPose) -> PixelGrid {
        switch ride {
        case .car: return PixelRides.car(state: state, step: pose.step)
        case .bike: return PixelRides.bike(state: state, step: pose.step)
        case .onFoot: return blob(state: state, outfit: outfit, pose: pose)
        }
    }

    /// The companion on foot.
    private static func blob(state: ShellCompanionState, outfit: Outfit, pose: CompanionPose) -> PixelGrid {
        var grid = PixelGrid()
        let body = BodyShape(state: state, pose: pose)
        paintBody(&grid, body: body, state: state)
        let top = Int((body.cy - body.ry).rounded(.up))
        if outfit == .beanie { paintBeanie(&grid, top: top) } else { paintSprout(&grid, top: top) }
        paintFace(&grid, body: body, state: state, pose: pose)
        if outfit == .glasses && !state.isLowEnergy { paintGlasses(&grid, eyeRow: Int((body.cy - 1).rounded())) }
        if outfit == .scarf { paintScarf(&grid, body: body) }
        if pose.walking {
            let odd = pose.step % 2 == 1
            grid.put(odd ? 7 : 8, 21, body.dark)
            grid.put(odd ? 12 : 11, 21, body.dark)
        }
        return grid
    }

    /// Fills the ellipse with its outline, highlight, lower shade and (when sick) the blanket.
    private static func paintBody(_ grid: inout PixelGrid, body: BodyShape, state: ShellCompanionState) {
        for py in 0..<PixelGrid.height {
            for px in 0..<PixelGrid.width where body.contains(px, py) {
                let edge = !body.contains(px - 1, py) || !body.contains(px + 1, py)
                    || !body.contains(px, py - 1) || !body.contains(px, py + 1)
                let hy = Double(py) - (body.cy - 3.5)
                let inHighlight = Double((px - 7) * (px - 7)) + hy * hy <= 2.3
                var hex = edge ? body.dark : (inHighlight ? body.light : (Double(py) >= body.cy + body.ry - 2.2 ? body.low : body.base))
                if state == .sick && !edge && Double(py) >= (body.cy + 1.5).rounded() {
                    hex = px % 3 == 0 ? 0xD9A57E : 0xF3E6CB
                }
                grid.put(px, py, hex)
            }
        }
    }

    /// The standard appearance's sprout, in fern with a darker stem.
    private static func paintSprout(_ grid: inout PixelGrid, top: Int) {
        grid.put(10, top - 1, 0x4E7A48)
        grid.put(10, top - 2, 0x4E7A48)
        for (x, y) in [(11, top - 3), (12, top - 3), (12, top - 4), (9, top - 3), (8, top - 3)] { grid.put(x, y, 0x72A364) }
    }

    /// The hand-drawn beanie, which sits where the sprout would be.
    private static func paintBeanie(_ grid: inout PixelGrid, top: Int) {
        for x in 5...14 { grid.put(x, top, 0x5FB8C9); grid.put(x, top + 1, 0x3F95A8) }
        for x in 6...13 { grid.put(x, top - 1, 0x5FB8C9) }
        grid.put(9, top - 2, 0xFFFFFF)
        grid.put(10, top - 2, 0xFFFFFF)
    }

    /// Eyes and mouth, by the state face (or the settled face) and the band's mouth height.
    private static func paintFace(_ grid: inout PixelGrid, body: BodyShape, state: ShellCompanionState, pose: CompanionPose) {
        let eyeRow = Int((body.cy - 1).rounded())
        let mouthRow = Int((body.cy + 2).rounded())
        let mouth = mix(body.base, 0xFFFFFF, 0.72)
        if pose.settled {
            paintSettledFace(&grid, eyeRow: eyeRow, mouthRow: mouthRow, mouth: mouth, closed: state.isLowEnergy)
            return
        }
        for x in [7, 12] {
            grid.put(x, eyeRow, state.isLowEnergy ? body.dark : ink)
            grid.put(x, eyeRow + 1, ink)
        }
        switch state {
        case .thriving:
            for x in 8...11 { grid.put(x, mouthRow, mouth) }
            for x in 9...10 { grid.put(x, mouthRow + 1, mouth) }
        case .okay:
            for x in 8...11 { grid.put(x, mouthRow, mouth) }
        case .tired, .resting, .sick:
            for x in 9...10 { grid.put(x, mouthRow, mouth) }
        }
    }

    /// The settled pose: happy-arc eyes (closed lids on a low-energy day), a wide lens and a blush.
    private static func paintSettledFace(_ grid: inout PixelGrid, eyeRow: Int, mouthRow: Int, mouth: UInt32, closed: Bool) {
        for x in [7, 12] {
            if closed {
                grid.put(x - 1, eyeRow + 1, ink); grid.put(x, eyeRow + 1, ink)
            } else {
                grid.put(x - 1, eyeRow + 1, ink); grid.put(x, eyeRow, ink); grid.put(x + 1, eyeRow + 1, ink)
            }
        }
        for x in 8...11 { grid.put(x, mouthRow, mouth) }
        for x in 9...10 { grid.put(x, mouthRow + 1, mouth) }
        grid.put(5, mouthRow - 1, 0xE8A3A0)
        grid.put(14, mouthRow - 1, 0xE8A3A0)
    }

    /// Round glasses over both eyes, joined by a bridge.
    private static func paintGlasses(_ grid: inout PixelGrid, eyeRow: Int) {
        for ex in [7, 12] {
            for gx in (ex - 1)...(ex + 1) { grid.put(gx, eyeRow - 1, ink); grid.put(gx, eyeRow + 2, ink) }
            for gy in [eyeRow, eyeRow + 1] { grid.put(ex - 1, gy, ink); grid.put(ex + 1, gy, ink) }
        }
        grid.put(9, eyeRow, ink)
        grid.put(10, eyeRow, ink)
    }

    /// A red scarf wrapped low on the body, with a tail.
    private static func paintScarf(_ grid: inout PixelGrid, body: BodyShape) {
        let row = Int((body.cy + 3.5).rounded())
        for x in 4...15 where body.contains(x, row) { grid.put(x, row, 0xD9532F) }
        grid.put(13, row + 1, 0xD9532F)
        grid.put(13, row + 2, 0xB03C24)
    }

    /// Blends `hex` toward `target` by `fraction` (0 keeps `hex`).
    static func mix(_ hex: UInt32, _ target: UInt32, _ fraction: Double) -> UInt32 {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) }
        func blend(_ shift: UInt32) -> UInt32 {
            UInt32((channel(hex, shift) + (channel(target, shift) - channel(hex, shift)) * fraction).rounded()) << shift
        }
        return blend(16) | blend(8) | blend(0)
    }
}

/// The body ellipse for one frame, with its colours: the breath grows it a little, the settled
/// pose slumps it wider than tall, and a resting day sits it lower (`CompanionBaseLayers`' offsets).
nonisolated struct BodyShape: Sendable {
    let cx: Double
    let cy: Double
    let rx: Double
    let ry: Double
    let base: UInt32
    let dark: UInt32
    let light: UInt32
    let low: UInt32

    init(state: ShellCompanionState, pose: CompanionPose) {
        let bob = pose.walking && pose.step % 2 == 1 ? 1.0 : 0
        let sink = state == .resting ? 0.6 : 0
        if pose.settled {
            (cx, cy, rx, ry) = (10, 13.7 + sink, 7.9, 6.5)
        } else {
            (cx, cy, rx, ry) = (10, (pose.breathIn ? 12.8 : 13.2) - bob + sink, pose.breathIn ? 7.6 : 7.4, pose.breathIn ? 7.3 : 6.9)
        }
        base = state.colorHex
        dark = PixelCompanionPainter.mix(base, 0x1E1008, 0.55)
        light = PixelCompanionPainter.mix(base, 0xFFFFFF, 0.38)
        low = PixelCompanionPainter.mix(base, 0x1E1008, 0.18)
    }

    /// Whether pixel (px, py)'s centre lies inside the ellipse.
    func contains(_ px: Int, _ py: Int) -> Bool {
        let dx = (Double(px) + 0.5 - cx) / rx, dy = (Double(py) + 0.5 - cy) / ry
        return dx * dx + dy * dy <= 1
    }
}
