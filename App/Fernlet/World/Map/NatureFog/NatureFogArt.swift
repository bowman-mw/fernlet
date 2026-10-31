import Foundation

/// One pixel of a sprite, in units (one unit = R / 8 on the map) from the sprite's anchor.
nonisolated struct NatureUnit: Hashable {
    let i: Int
    let j: Int
}

/// A piece of the fog's pixel art in units from its anchor (a hex centre, or a tree's root), as the mockup's
/// `rect` calls lay it down: a later pixel over the same unit wins. A unit holds a palette role or, for the
/// terrain's pieces, one of the mockup's fixed colours (``NatureInk``).
nonisolated struct NaturePixelArt {
    /// Every painted unit.
    private(set) var pixels: [NatureUnit: NatureInk] = [:]

    /// Paints one unit in a palette role.
    mutating func put(_ i: Int, _ j: Int, _ paint: NaturePaint) {
        pixels[NatureUnit(i: i, j: j)] = .paint(paint)
    }

    /// Paints one unit in `ink`.
    mutating func put(_ i: Int, _ j: Int, ink: NatureInk) {
        pixels[NatureUnit(i: i, j: j)] = ink
    }

    /// Paints one unit in the fixed colour `rgb` (0xRRGGBB).
    mutating func fixed(_ i: Int, _ j: Int, _ rgb: UInt32) {
        pixels[NatureUnit(i: i, j: j)] = .fixed(rgb)
    }

    /// Paints a `width` × `height` block with its top-left unit at (`x`, `y`); nothing for an empty one.
    mutating func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ paint: NaturePaint) {
        guard width > 0, height > 0, width <= 64, height <= 64 else { return }
        for j in y..<(y + height) {
            for i in x..<(x + width) { put(i, j, paint) }
        }
    }

    /// Repaints every unit painted `from` in `to` (the spring blossom's canopy).
    mutating func recolour(_ from: NatureInk, to: NatureInk) {
        for (unit, ink) in pixels where ink == from { pixels[unit] = to }
    }

    /// The painted units as the mockup's `runs`: rows top to bottom, each split into runs of one ink left to
    /// right, as (first column, row, ink, length).
    var runs: [(i: Int, j: Int, ink: NatureInk, length: Int)] {
        let ordered = pixels.keys.sorted { $0.j != $1.j ? $0.j < $1.j : $0.i < $1.i }
        var found: [(i: Int, j: Int, ink: NatureInk, length: Int)] = []
        for unit in ordered {
            guard let ink = pixels[unit] else { continue }
            if let last = found.last, last.j == unit.j, last.ink == ink, last.i + last.length == unit.i {
                found[found.count - 1].length += 1
            } else {
                found.append((unit.i, unit.j, ink, 1))
            }
        }
        return found
    }

    /// The painted units' bounding box: the top-left unit and the size; nil when nothing is painted.
    var bounds: (minI: Int, minJ: Int, width: Int, height: Int)? {
        guard let first = pixels.keys.first else { return nil }
        var minI = first.i, maxI = first.i, minJ = first.j, maxJ = first.j
        for unit in pixels.keys {
            minI = min(minI, unit.i)
            maxI = max(maxI, unit.i)
            minJ = min(minJ, unit.j)
            maxJ = max(maxJ, unit.j)
        }
        return (minI, minJ, maxI - minI + 1, maxJ - minJ + 1)
    }
}

/// A hex's shape in units: centre to corner, and half the width.
nonisolated struct NatureHexUnits {
    /// Centre to corner (`Ru`, 8 at full detail).
    let ru: Double
    /// Half the width (`hwu`).
    let hwu: Double

    /// Full detail: s = R / 8.
    static let full = NatureHexUnits(ru: 8, hwu: 8 * 3.0.squareRoot() / 2)

    /// The mockup's `topU`: where the hex's top edge is above column `xu`.
    func top(_ xu: Double) -> Double {
        let across = min(abs(xu), hwu)
        return -ru + across / hwu * ru / 2
    }

    /// The mockup's `halfAt`: the hex's half-width at row `y`.
    func half(_ y: Double) -> Double {
        let down = abs(y)
        return down <= ru / 2 ? hwu : hwu * (ru - down) / (ru / 2)
    }
}

/// The fog's pieces as the mockup draws them (`tuft`, `grass`, `boulder`, `treeArt`, `pineArt`; the mockup's `reeds` went with its ponds),
/// ported unit for unit. The atlas renders them once; nothing here draws.
nonisolated enum NatureFogArt {
    /// Long grass, or the shorter, sparser grass under wildflowers with 4–6 flowers on it.
    static func grass(flowers: Bool, random: inout NatureRandom, hex: NatureHexUnits = .full) -> NaturePixelArt {
        var art = NaturePixelArt()
        let rowScale = hex.ru / 8
        let rows = [-4, -1, 2, 5, 7].map { NatureFogNoise.jsRoundInt(Double($0) * rowScale) }
        for (index, y) in rows.enumerated() {
            tuftRow(&art, index: index, y: y, flowers: flowers, random: &random, hex: hex)
        }
        if flowers { blossoms(&art, random: &random, hex: hex) }
        return art
    }

    /// One row of tufts packed across the hex; the back row's tips end 1–2 units past the top edges.
    private static func tuftRow(_ art: inout NaturePixelArt, index: Int, y: Int, flowers: Bool,
                                random: inout NatureRandom, hex: NatureHexUnits) {
        let reach = (hex.half(Double(y)) - 0.6).rounded(.down)
        let start = -Int(reach) + (index & 1) + random.below(2), end = Int(reach)
        guard start <= end else { return }
        for x in stride(from: start, through: end, by: 3) {
            if flowers && random.next() < 0.45 { continue }
            var height: Int
            if index == 0 {
                let lift = random.next() < 0.5 ? 1 : 0
                height = y - (NatureFogNoise.jsRoundInt(hex.top(Double(x) + 0.5)) - 1 - lift) + 1
            } else {
                height = index == 4 ? 3 : 4 + random.below(2)
            }
            if flowers { height = max(3, height - 1) }
            let roll = random.next()
            let tone = index == 0 ? (roll < 0.5 ? 0 : 1)
                : index >= 3 ? (roll < 0.5 ? 2 : 1) : (roll < 0.2 ? 0 : roll < 0.8 ? 1 : 2)
            tuft(&art, x: x, y: y, height: height, tone: tone, random: &random)
        }
    }

    /// One tuft: a straight middle blade and two that bend outwards halfway up; tone 0 dark, 1 mid, 2 light.
    private static func tuft(_ art: inout NaturePixelArt, x: Int, y: Int, height: Int, tone: Int, random: inout NatureRandom) {
        let bases: [NaturePaint] = [.bladeDark, .bladeMid, .bladeLight], tips: [NaturePaint] = [.bladeMid, .bladeLight, .bladeTip]
        guard bases.indices.contains(tone) else { return }
        let base = bases[tone], tip = tips[tone]
        art.rect(x, y - height + 1, 1, height, base)
        art.rect(x, y - height + 1, 1, 1, tip)
        for side in [-1, 1] {
            let bent = max(2, height - 1 - random.below(2)), low = (bent + 1) / 2
            art.rect(x + side, y - low + 1, 1, low, base)
            if bent > low {
                art.rect(x + 2 * side, y - bent + 1, 1, bent - low, base)
                art.rect(x + 2 * side, y - bent + 1, 1, 1, tip)
            }
        }
    }

    /// 4–6 flowers on dark stalks: one main colour, 30 % in a second; 70 % a plus with a centre, else 2 × 1.
    private static func blossoms(_ art: inout NaturePixelArt, random: inout NatureRandom, hex: NatureHexUnits) {
        let limit = Int((hex.hwu - 0.3).rounded(.down)), stemFloor = Int(hex.half(0).rounded(.down))
        guard limit >= 2 else { return }
        let count = 4 + random.below(3)
        let main = NaturePaint.petals[random.below(4)], other = NaturePaint.petals[random.below(4)]
        for _ in 0..<count {
            let xu = -limit + 1 + random.below(2 * limit - 2)
            let head = NatureFogNoise.jsRoundInt(hex.top(Double(xu) + 0.5)) - 1 + random.below(7)
            let root = min(stemFloor, head + 3 + random.below(3))
            if root > head + 1 { art.rect(xu, head + 1, 1, root - head, .bladeDark) }
            let petal = random.next() < 0.7 ? main : other
            if random.next() < 0.7 {
                art.rect(xu - 1, head, 3, 1, petal)
                art.rect(xu, head - 1, 1, 3, petal)
                art.rect(xu, head, 1, 1, petal == .petalYellow ? .centreOnYellow : .centre)
            } else {
                art.rect(xu, head, 2, 1, petal)
            }
        }
    }

    /// One straight reed or blade from `root` up to `tip`: dark at the foot, light at the tip.
    private static func blade(_ art: inout NaturePixelArt, xu: Int, root: Int, tip: Int, lean: Int) {
        let count = root - tip + 1
        guard count >= 2 else { return }
        let dark = max(1, NatureFogNoise.jsRoundInt(Double(count) * 0.35))
        let light = max(1, NatureFogNoise.jsRoundInt(Double(count) * 0.22)), mid = count - dark - light
        art.rect(xu, root - dark + 1, 1, dark, .bladeDark)
        if mid > 0 { art.rect(xu, tip + light, 1, mid, .bladeMid) }
        art.rect(xu + lean, tip, 1, light, .bladeLight)
    }

    /// The boulder's 8 × 5 pixels (the mockup's `ROCK`), top-left at (0, 0).
    static func rock() -> NaturePixelArt {
        var art = NaturePixelArt()
        let rows = ["..kkkk..", ".khRrrk.", "khRrrrrk", "kRrrrrrk", ".kkkkkk."]
        for (j, row) in rows.enumerated() {
            for (i, mark) in row.enumerated() {
                switch mark {
                case "k": art.put(i, j, .rockDark)
                case "h": art.put(i, j, .rockHighlight)
                case "R": art.put(i, j, .rockLight)
                case "r": art.put(i, j, .rock)
                default: break
                }
            }
        }
        return art
    }
}
