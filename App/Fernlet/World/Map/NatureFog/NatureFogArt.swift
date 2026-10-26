import Foundation

/// One pixel of a sprite, in units (one unit = R / 8 on the map) from the sprite's anchor.
nonisolated struct NatureUnit: Hashable {
    let i: Int
    let j: Int
}

/// A piece of the fog's pixel art in units from its anchor (a hex centre, or a tree's root), as the mockup's
/// `rect` calls lay it down: a later pixel over the same unit wins.
nonisolated struct NaturePixelArt {
    /// Every painted unit.
    private(set) var pixels: [NatureUnit: NaturePaint] = [:]

    /// Paints one unit.
    mutating func put(_ i: Int, _ j: Int, _ paint: NaturePaint) {
        pixels[NatureUnit(i: i, j: j)] = paint
    }

    /// Paints a `width` × `height` block with its top-left unit at (`x`, `y`); nothing for an empty one.
    mutating func rect(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ paint: NaturePaint) {
        guard width > 0, height > 0, width <= 64, height <= 64 else { return }
        for j in y..<(y + height) {
            for i in x..<(x + width) { put(i, j, paint) }
        }
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

/// The fog's pieces as the mockup draws them (`tuft`, `grass`, `boulder`, `reeds`, `treeArt`, `pineArt`),
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

    /// Reeds rising from a pond's lower shore; 35 % carry a brown cattail.
    static func reeds(random: inout NatureRandom, hex: NatureHexUnits = .full) -> NaturePixelArt {
        var art = NaturePixelArt()
        let limit = Int((hex.hwu - 0.3).rounded(.down))
        guard limit >= 2 else { return art }
        for xu in (-limit + 1)..<(limit - 1) {
            if random.next() > 0.55 { continue }
            let root = Int((-hex.top(Double(xu) + 0.5)).rounded(.down)) - 1
            let tip = root - 3 - random.below(3)
            blade(&art, xu: xu, root: root, tip: tip, lean: 0)
            if random.next() < 0.35 { art.rect(xu, tip - 2, 1, 2, .cattail) }
        }
        return art
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
