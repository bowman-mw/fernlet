import Foundation
import WorldMapStore

/// The nature fog's randomness, ported exactly from the approved mockup (`World-Nature-Fog-mockup.js`, the
/// review page's `nature.js`): a 32-bit integer hash, a slow value noise over the grid, and JavaScript's
/// `Math.round`. Every choice the fog makes comes from a hex's own (col, row) through these, so the same hex
/// always grows the same thing and the wild never reshuffles.
///
/// The arithmetic follows the JavaScript bit for bit: the hash's first products are exact integers (as in
/// JavaScript's doubles for any real map cell) taken modulo 2^32, `Math.imul` is a wrapping 32-bit multiply,
/// and the noise's sums keep the mockup's evaluation order. `NatureFogDeterminismTests` pins values the
/// mockup itself printed.
nonisolated enum NatureFogNoise {
    /// The mockup's `hash(x, y)`.
    static func hash(_ x: Int, _ y: Int) -> UInt32 {
        let mixed = Int64(x) &* 374_761_393 &+ Int64(y) &* 668_265_263
        var value = UInt32(truncatingIfNeeded: mixed)
        value = (value ^ (value >> 13)) &* 1_274_126_177
        return value ^ (value >> 16)
    }

    /// The mockup's `h01(x, y, salt)`: the hash of a salted lattice point, in [0, 1).
    static func unit(_ x: Int, _ y: Int, salt: Int) -> Double {
        Double(hash(x &* 7 &+ salt &* 7_919 &+ 5_000, y &* 13 &- salt &* 104_729 &+ 5_000)) / 4_294_967_296
    }

    /// The mockup's `noise(col, row, size, salt)`: smooth value noise with lattice points `size` hexes apart,
    /// so woods and meadows come in patches.
    static func noise(_ col: Int, _ row: Int, size: Double, salt: Int) -> Double {
        guard size > 0 else { return 0 }
        let x = Double(col) / size, y = Double(row) / size
        let x0 = x.rounded(.down), y0 = y.rounded(.down)
        var fx = x - x0, fy = y - y0
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let ix = Int(x0), iy = Int(y0)
        let a = unit(ix, iy, salt: salt), b = unit(ix + 1, iy, salt: salt)
        let c = unit(ix, iy + 1, salt: salt), d = unit(ix + 1, iy + 1, salt: salt)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    /// JavaScript's `Math.round`: halves go up, also below zero (Swift's `.rounded()` would go away from zero).
    static func jsRound(_ value: Double) -> Double {
        (value + 0.5).rounded(.down)
    }

    /// `Math.round` as an `Int`, for unit counts and offsets (always small).
    static func jsRoundInt(_ value: Double) -> Int {
        guard value.isFinite, abs(value) < 1e12 else { return 0 }
        return Int(jsRound(value))
    }
}

/// The mockup's `rng(seed)`: mulberry32, one stream of numbers in [0, 1) per seed.
nonisolated struct NatureRandom {
    private var state: UInt32

    /// A stream seeded as the mockup seeds it (`seed >>> 0`).
    init(seed: UInt32) {
        state = seed
    }

    /// The next number in [0, 1).
    mutating func next() -> Double {
        state = state &+ 0x6D2B_79F5
        var t = state
        t = (t ^ (t >> 15)) &* (t | 1)
        t ^= t &+ ((t ^ (t >> 7)) &* (t | 61))
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }

    /// `Math.floor(rnd() * count)`.
    mutating func below(_ count: Int) -> Int {
        Int((next() * Double(count)).rounded(.down))
    }
}

/// What one fog hex is (spec "What each hex is"): an edge next to the uncovered map, or one of
/// the four kinds of ground cover; the terrain sets add theirs (the mockup's `kinds`: sea waves, sand ripples,
/// mountain scree, tundra lichen, ice cracks and snow drifts, crop rows and roofs).
nonisolated enum NatureHexKind: Hashable {
    case edge, short, long, flowers, boulder
    case waves, ripples, scree, lichen, crack, snow, crops, roof
}

/// A tree the mockup's `treeAt` stands on a hex: a pine or a round tree, big or small, with its shape variant.
nonisolated struct NatureTreeChoice: Equatable {
    /// A pine rather than a round tree.
    let pine: Bool
    /// The big size.
    let big: Bool
    /// The hash that decides between neighbouring candidates (the larger one wins).
    let key: UInt32
    /// One of 4 shape variants, `(hash >>> 20) % 4`.
    let variant: Int
}

/// The mockup's rules for what grows where, from a hex's odd-r offset (col, row) alone.
///
/// The fog's cells are axial (`HexCell`, pointy-top, rows growing south); the mockup works in odd-r offset
/// coordinates, `col = q + (r - (r & 1)) / 2`, the same hexes with odd rows shoved half a hex right.
nonisolated enum NatureFogRules {
    /// The offset neighbours of a hex on an odd row, side by side with its sides SE, SW, W, NW, NE, E.
    static let oddRowSides = [(1, 1), (0, 1), (-1, 0), (0, -1), (1, -1), (1, 0)]
    /// The same for an even row.
    static let evenRowSides = [(0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, 0)]

    /// `cell`'s odd-r offset coordinates.
    static func offset(of cell: HexCell) -> (col: Int, row: Int) {
        (cell.q + (cell.r - (cell.r & 1)) / 2, cell.r)
    }

    /// The cell at odd-r offset (`col`, `row`).
    static func cell(col: Int, row: Int) -> HexCell {
        HexCell(q: col - (row - (row & 1)) / 2, r: row)
    }

    /// The six neighbours of `cell`, in the order of its sides (SE, SW, W, NW, NE, E).
    static func sides(of hex: HexCell) -> [HexCell] {
        let at = offset(of: hex)
        let deltas = at.row & 1 == 1 ? oddRowSides : evenRowSides
        return deltas.map { Self.cell(col: at.col + $0.0, row: at.row + $0.1) }
    }

    /// The woods noise, `noise(col, row, 6, salt 1)`: above 0.58 the woods' mix, above 0.62 the woods green.
    static func woods(_ col: Int, _ row: Int) -> Double {
        NatureFogNoise.noise(col, row, size: 6, salt: 1)
    }

    /// The mockup's `kindAt`: short, long, flowers or boulder by `hash(col+1000, row+1000) % 100`.
    static func ground(_ col: Int, _ row: Int) -> NatureHexKind {
        let roll = Int(NatureFogNoise.hash(col + 1_000, row + 1_000) % 100)
        let inWoods = woods(col, row) > 0.58
        let short = inWoods ? 56 : 46, long = inWoods ? 36 : 28, flowers = inWoods ? 6 : 22, boulder = inWoods ? 2 : 4
        if roll < short { return .short }
        if roll < short + long { return .long }
        if roll < short + long + flowers { return .flowers }
        return roll < short + long + flowers + boulder ? .boulder : .short
    }

    /// The mockup's `treeCand`: whether a tree may start here, more often deeper in the woods.
    static func treeCandidate(_ col: Int, _ row: Int) -> NatureTreeChoice? {
        let wood = woods(col, row), key = NatureFogNoise.hash(col + 3_000, row + 3_000)
        let chance = 0.04 + 0.42 * max(0, min(1, (wood - 0.42) / 0.4))
        guard Double(key % 1_000) / 1_000 < chance else { return nil }
        let conifer = NatureFogNoise.noise(col, row, size: 7, salt: 3)
        return NatureTreeChoice(pine: (key >> 10) % 100 < (conifer > 0.58 ? 75 : 18),
                                big: (key >> 17) % 100 < (wood > 0.55 ? 60 : 35),
                                key: key, variant: Int((key >> 20) % 4))
    }

    /// The mockup's `treeAt`: a candidate that no neighbouring candidate outranks.
    static func tree(_ col: Int, _ row: Int) -> NatureTreeChoice? {
        guard let choice = treeCandidate(col, row) else { return nil }
        let deltas = row & 1 == 1 ? oddRowSides : evenRowSides
        for delta in deltas {
            if let rival = treeCandidate(col + delta.0, row + delta.1), rival.key > choice.key { return nil }
        }
        return choice
    }
}
