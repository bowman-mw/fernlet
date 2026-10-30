import Foundation

/// The terrain's pieces as the mockup draws them (`palmArt`, `cactusArt`, `peakArt`, `houseArt`, `bareArt`,
/// `crops`, `snowCaps` and the spring blossom), ported unit for unit in the mockup's fixed colours. Units count
/// from the piece's root (row 0 is its ground shadow) or, for the crop rows, from the hex centre. The atlas
/// renders them once; nothing here draws.
nonisolated enum TerrainArt {
    /// A palm `height` units tall: a curving trunk, eight drooping fronds; odd variants lean right, variants 2
    /// and 3 have longer fronds.
    static func palm(height: Int, variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        guard height >= 6, height <= 60 else { return art }
        let lean = variant & 1 == 1 ? 1.0 : -1.0, top = -height + 4
        for i in -2...2 { art.fixed(i, 0, 0x6F9B57) }
        func curve(_ j: Int) -> Int { NatureFogNoise.jsRoundInt(lean * 1.6 * pow(Double(-j) / Double(height), 2)) }
        for j in stride(from: -1, through: top, by: -1) {
            let x = curve(j)
            art.fixed(x, j, j & 2 != 0 ? 0xB08850 : 0xC9A26A)
            art.fixed(x + 1, j, 0x8A6438)
        }
        let cx = curve(top), cy = top
        let fronds: [(Double, Int)] = [(-2.6, 6), (-2.0, 6), (-1.2, 5), (-0.5, 4), (0.5, 4), (1.2, 5), (2.0, 6), (2.6, 6)]
        for frond in fronds {
            let angle = -Double.pi / 2 + frond.0 * 0.62, length = frond.1 + (variant & 2 != 0 ? 1 : 0)
            let droop = abs(frond.0) > 1.5 ? 3.0 : 1.5
            for t in 1...length {
                let step = Double(t)
                let px = NatureFogNoise.jsRoundInt(Double(cx) + cos(angle) * step)
                let py = NatureFogNoise.jsRoundInt(Double(cy) + sin(angle) * step + pow(step / Double(length), 2) * droop)
                art.fixed(px, py - 1, 0x245A26)
                art.fixed(px, py, t < length - 1 ? 0x7FC468 : 0xA6DA84)
                art.fixed(px, py + 1, 0x3F8F3A)
                art.fixed(px, py + 2, 0x1E4A20)
            }
        }
        art.fixed(cx, cy + 1, 0x7A4B2A)
        art.fixed(cx + 1, cy + 1, 0x7A4B2A)
        art.fixed(cx, cy, 0x46913F)
        return art
    }

    /// A cactus `height` units tall: a 3-wide body with a left arm, a right arm on odd variants, a pink flower on
    /// variants 2 and 3; dark outline, lit left.
    static func cactus(height: Int, variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        guard height >= 4, height <= 60 else { return art }
        for i in -2...2 { art.fixed(i, 0, 0xC9A866) }
        var body = Set<NatureUnit>()
        for j in stride(from: -1, through: -height, by: -1) {
            for i in -1...1 { body.insert(NatureUnit(i: i, j: j)) }
        }
        let low = -NatureFogNoise.jsRoundInt(Double(height) * 0.45), high = -NatureFogNoise.jsRoundInt(Double(height) * 0.62)
        for i in -3...(-2) { body.insert(NatureUnit(i: i, j: low)) }
        for j in stride(from: low, through: low - 3, by: -1) { body.insert(NatureUnit(i: -3, j: j)) }
        if variant & 1 == 1 {
            for i in 2...3 { body.insert(NatureUnit(i: i, j: high)) }
            for j in stride(from: high, through: high - 2, by: -1) { body.insert(NatureUnit(i: 3, j: j)) }
        }
        for unit in body {
            let rim = !body.contains(NatureUnit(i: unit.i - 1, j: unit.j)) || !body.contains(NatureUnit(i: unit.i + 1, j: unit.j))
                || !body.contains(NatureUnit(i: unit.i, j: unit.j - 1))
            art.fixed(unit.i, unit.j, rim ? 0x2E5A2B : unit.i == -1 || unit.i == -3 ? 0x76AE55 : 0x4E8B3D)
        }
        if variant & 2 != 0 { art.fixed(0, -height - 1, 0xF26B8A) }
        return art
    }

    /// A mountain peak `width` × `height` units: grey rock lit left of a wandering ridge, a snow cap, a dark
    /// outline, and a smaller shoulder peak to the right when wide (from the fixed seed `4242 + v·17 + W`).
    static func peak(width: Int, height: Int, variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        guard width >= 4, width <= 80, height >= 4, height <= 80 else { return art }
        var random = NatureRandom(seed: UInt32(truncatingIfNeeded: 4_242 + variant * 17 + width))
        let snow = NatureFogNoise.jsRoundInt(Double(height) * (0.3 + random.next() * 0.08))
        if width > 20 { shoulder(&art, width: width, height: height) }
        var ridge = 0
        for j in -height...(-1) {
            let half = NatureFogNoise.jsRoundInt(Double(j + height + 1) / Double(height) * Double(width) / 2)
            if random.next() < 0.3 { ridge += random.next() < 0.5 ? -1 : 1 }
            ridge = max(-2, min(2, ridge))
            let snowEdge = -height + snow + (random.next() < 0.5 ? 0 : 1)
            for i in -half...half {
                let edge = i == -half || i == half || j == -1, lit = i < ridge
                let rock: UInt32 = lit ? 0xC9C4BA : i > ridge + 1 ? 0x8C877D : 0xA9A498
                art.fixed(i, j, edge ? 0x5E5A52 : j < snowEdge ? (lit ? 0xFFFFFF : 0xDDE6EA) : rock)
            }
        }
        return art
    }

    /// The shoulder peak right of a wide peak.
    private static func shoulder(_ art: inout NaturePixelArt, width: Int, height: Int) {
        let top = NatureFogNoise.jsRoundInt(Double(height) * 0.62), spread = NatureFogNoise.jsRoundInt(Double(width) * 0.34)
        let centre = spread, cap = -top + NatureFogNoise.jsRoundInt(Double(top) * 0.28)
        guard top >= 1 else { return }
        for j in -top...(-1) {
            let half = NatureFogNoise.jsRoundInt(Double(j + top + 1) / Double(top) * Double(spread))
            for i in (centre - half)...(centre + half) {
                let edge = i == centre - half || i == centre + half
                art.fixed(i, j, edge ? 0x5E5A52 : j < cap ? 0xE8EEF1 : i < centre ? 0xB5B0A6 : 0x8C877D)
            }
        }
    }

    /// A house or, on every third variant, a tall block, for urban hexes; seven variants over four roof colours.
    static func house(variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        let roofs: [(UInt32, UInt32)] = [(0xB5523B, 0x8A3B2A), (0x4E6E9A, 0x3A5478), (0x6E6A66, 0x545050), (0x9A6B3E, 0x764F2C)]
        let roof = roofs[((variant % 4) + 4) % 4]
        if variant % 3 == 2 {
            for j in -13...(-1) {
                for i in -4...4 {
                    let wall: UInt32 = j % 3 == 0 && i % 2 == 0 ? 0x9CC9E4 : i < 0 ? 0xE6DCC6 : 0xCFC2A6
                    art.fixed(i, j, i == -4 || i == 4 || j == -13 ? 0x4A3A30 : wall)
                }
            }
            for i in -5...5 { art.fixed(i, -14, roof.1) }
            return art
        }
        for j in -6...(-1) {
            for i in -5...5 { art.fixed(i, j, i == -5 || i == 5 ? 0x4A3A30 : i < 0 ? 0xEADFC8 : 0xCFC2A6) }
        }
        art.fixed(-3, -3, 0x9CC9E4)
        art.fixed(-2, -3, 0x9CC9E4)
        for j in -4...(-2) { art.fixed(2, j, 0x7A4B2A) }
        for row in 0..<5 {
            for i in (-6 + row)...(6 - row) { art.fixed(i, -7 - row, i <= 0 ? roof.0 : roof.1) }
        }
        return art
    }

    /// A bare winter tree with crown radius `radius`: a 2-wide trunk and four branches (seed `777 + v·31 + r`).
    static func bare(radius: Int, variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        guard radius >= 2, radius <= 40 else { return art }
        var random = NatureRandom(seed: UInt32(truncatingIfNeeded: 777 + variant * 31 + radius))
        for i in -2...2 { art.fixed(i, 0, 0xAFBDB8) }
        for j in stride(from: -1, through: -radius - 3, by: -1) {
            art.fixed(0, j, 0x6B4A32)
            art.fixed(1, j, 0x4E3424)
        }
        let branches: [(Int, Double)] = [(-1, 0.55), (1, 0.62), (-1, 0.8), (1, 0.9)]
        for (index, branch) in branches.enumerated() {
            let start = -NatureFogNoise.jsRoundInt(Double(radius + 3) * branch.1)
            let length = NatureFogNoise.jsRoundInt(Double(radius) * (0.55 + random.next() * 0.2))
            guard length >= 1 else { continue }
            for t in 1...length {
                art.fixed(branch.0 * t + (branch.0 > 0 ? 1 : 0), start - NatureFogNoise.jsRoundInt(Double(t) * 0.8),
                          index < 2 ? 0x6B4A32 : 0x4E3424)
            }
        }
        return art
    }

    /// Three rows of crops across a hex, in units from its centre: wheat (gold heads) or greens.
    static func crops(wheat: Bool, hex: NatureHexUnits = .full) -> NaturePixelArt {
        var art = NaturePixelArt()
        let head: UInt32 = wheat ? 0xE2C15A : 0x8DBB5A, stem: UInt32 = wheat ? 0xB8932E : 0x5E8A3A
        for y in [-4, 0, 4] {
            let half = hex.half(Double(y)), start = -Int(half.rounded(.down)) + 1
            for x in stride(from: start, to: Int((half - 1).rounded(.up)), by: 2) where Double(x) < half - 1 {
                art.fixed(x, y - 2, stem)
                art.fixed(x, y - 1, stem)
                art.fixed(x, y - 3, head)
            }
        }
        return art
    }

    /// A winter pine: the approved pine with snow on the lit top row of its tiers (the mockup's `snowCaps`).
    static func snowyPine(height: Int, odd: Bool) -> NaturePixelArt {
        var art = NatureFogTreeArt.pine(height: height, variant: odd ? 1 : 0)
        let needles: Set<NatureInk> = [.paint(.pineOutline), .paint(.pineLight), .paint(.pineMid), .paint(.pineDark)]
        for run in art.runs where needles.contains(run.ink) && run.i <= 0 && run.j & 1 == 1 {
            for i in run.i..<(run.i + min(run.length, 3)) { art.fixed(i, run.j, 0xF5F8F8) }
        }
        return art
    }

    /// A spring tree: the approved round tree with its canopy in blossom pinks.
    static func blossom(radius: Int, variant: Int) -> NaturePixelArt {
        var art = NatureFogTreeArt.round(radius: radius, variant: variant)
        art.recolour(.paint(.leafDark), to: .fixed(0xB9667E))
        art.recolour(.paint(.leafMid), to: .fixed(0xE08FA8))
        art.recolour(.paint(.leafLight), to: .fixed(0xF2B4C7))
        art.recolour(.paint(.leafHighlight), to: .fixed(0xFFE0EA))
        return art
    }
}
