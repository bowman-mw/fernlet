import Foundation

/// The trees' pixel art, ported from the mockup's `treeArt` and `pineArt`: units from the tree's root (row 0 is
/// the first row of its ground shadow), so a tree stands over several hexes from the one it grows on.
nonisolated enum NatureFogTreeArt {
    /// One round lump of a canopy, in units from the canopy's centre.
    private struct Lump {
        let x: Double
        let y: Double
        let radius: Double
    }

    /// A round tree's trunk height for canopy radius `radius`.
    static func trunkHeight(radius: Int) -> Int {
        max(2, NatureFogNoise.jsRoundInt(Double(radius) * 0.32))
    }

    /// The canopy centre's row (the mockup's `cy0`, negative: above the root).
    static func canopyRow(radius: Int) -> Int {
        -(trunkHeight(radius: radius) + NatureFogNoise.jsRoundInt(Double(radius) * 0.9))
    }

    /// A round tree: a lumpy canopy (a core plus 5 lumps) with a 1-unit dark outline, lit from the upper left
    /// in 4 greens, a trunk and a 2-row ground shadow.
    static func round(radius: Int, variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        guard radius >= 2, radius <= 40 else { return art }
        let canopyY = canopyRow(radius: radius), trunkWidth = radius >= 10 ? 3 : 2, left = -(trunkWidth / 2)
        let wide = NatureFogNoise.jsRoundInt(Double(radius) * 0.75), narrow = NatureFogNoise.jsRoundInt(Double(radius) * 0.5)
        for i in -wide...wide { art.put(i, 0, .shadow) }
        for i in -narrow...narrow { art.put(i, 1, .shadow) }
        for j in stride(from: -1, through: canopyY + 2, by: -1) {
            for i in 0..<trunkWidth { art.put(i + left, j, i == 0 ? .trunkLight : .trunkDark) }
        }
        art.put(left - 1, -1, .trunkDark)
        art.put(left + trunkWidth, -1, .trunkDark)
        canopy(&art, lumps: lumps(radius: radius, variant: variant), radius: radius, canopyY: canopyY)
        return art
    }

    /// The canopy's lumps, from `rng(9001 + v·131 + r·7)`.
    private static func lumps(radius: Int, variant: Int) -> [Lump] {
        var random = NatureRandom(seed: UInt32(truncatingIfNeeded: 9_001 + variant * 131 + radius * 7))
        let size = Double(radius)
        var lumps = [Lump(x: 0, y: 0, radius: size * 0.78)]
        for index in 0..<5 {
            let angle = Double(index) / 5 * Double.pi * 2 + Double(variant) * 1.3 + random.next() * 0.5
            let distance = size * (0.36 + random.next() * 0.1)
            lumps.append(Lump(x: cos(angle) * distance, y: sin(angle) * distance * 0.85, radius: size * (0.5 + random.next() * 0.1)))
        }
        return lumps
    }

    /// Whether unit (`i`, `j`) falls inside any lump.
    private static func inside(_ i: Int, _ j: Int, lumps: [Lump], canopyY: Int) -> Bool {
        let x = Double(i) + 0.5, y = Double(j) + 0.5 - Double(canopyY)
        return lumps.contains { lump in (x - lump.x) * (x - lump.x) + (y - lump.y) * (y - lump.y) <= lump.radius * lump.radius }
    }

    /// Paints the canopy: outline on its rim, the darkest green along its underside, shaded lumps inside.
    private static func canopy(_ art: inout NaturePixelArt, lumps: [Lump], radius: Int, canopyY: Int) {
        let reach = Int((Double(radius) * 1.15).rounded(.up)) + 1
        for j in (canopyY - reach)...(canopyY + reach) {
            for i in -reach...reach where inside(i, j, lumps: lumps, canopyY: canopyY) {
                let rim = !inside(i - 1, j, lumps: lumps, canopyY: canopyY) || !inside(i + 1, j, lumps: lumps, canopyY: canopyY)
                    || !inside(i, j - 1, lumps: lumps, canopyY: canopyY) || !inside(i, j + 1, lumps: lumps, canopyY: canopyY)
                if rim {
                    art.put(i, j, .outline)
                } else if !inside(i, j + 2, lumps: lumps, canopyY: canopyY) {
                    art.put(i, j, .leafDark)
                } else {
                    art.put(i, j, shade(i, j, lumps: lumps, radius: radius, canopyY: canopyY))
                }
            }
        }
    }

    /// The green of an inner canopy unit, lit from the upper left by its nearest lump.
    private static func shade(_ i: Int, _ j: Int, lumps: [Lump], radius: Int, canopyY: Int) -> NaturePaint {
        let x = Double(i) + 0.5, y = Double(j) + 0.5 - Double(canopyY)
        guard var best = lumps.first else { return .leafMid }
        var bestScore = -1e9
        for lump in lumps {
            let score = lump.radius - hypot(x - lump.x, y - lump.y)
            if score > bestScore {
                bestScore = score
                best = lump
            }
        }
        let light = -(((x - best.x) / best.radius) * 0.75 + ((y - best.y) / best.radius) * 0.95)
            - (y / Double(radius)) * 0.35 + ((i + j) & 1 == 1 ? 0.07 : -0.07)
        return light > 0.6 ? .leafHighlight : light > 0.15 ? .leafLight : light > -0.35 ? .leafMid : .leafDark
    }

    /// A pine `height` units tall: three stacked tiers lit from the left, a dark row under each tier, a 3-wide
    /// trunk and a shadow. Only the variant's parity changes the shape (the bottom tier one unit wider).
    static func pine(height: Int, variant: Int) -> NaturePixelArt {
        var art = NaturePixelArt()
        guard height >= 6, height <= 60 else { return art }
        let trunk = 2, crown = height - trunk, step = max(2, NatureFogNoise.jsRoundInt(Double(crown) * 0.29))
        let tier = crown - 2 * step
        guard tier > 0 else { return art }
        let widths = (0..<3).map { t in
            NatureFogNoise.jsRoundInt(Double(height) * 0.17 + Double(t) * Double(height) * 0.075) + (t == 2 && variant & 1 == 1 ? 1 : 0)
        }
        let last = widths[2]
        for i in -NatureFogNoise.jsRoundInt(Double(last) * 0.8)...NatureFogNoise.jsRoundInt(Double(last) * 0.8) { art.put(i, 0, .shadow) }
        for i in -NatureFogNoise.jsRoundInt(Double(last) * 0.5)...NatureFogNoise.jsRoundInt(Double(last) * 0.5) { art.put(i, 1, .shadow) }
        for j in stride(from: -1, through: -trunk, by: -1) {
            art.put(-1, j, .trunkLight)
            art.put(0, j, .trunkDark)
            art.put(1, j, .trunkDark)
        }
        let shape = PineShape(height: height, step: step, tier: tier, widths: widths)
        for j in -height...(-trunk - 1) { shape.paintRow(&art, j: j, trunk: trunk) }
        return art
    }

    /// A pine's tiers: how wide each row is and whether it is a tier's last row.
    private struct PineShape {
        let height: Int
        let step: Int
        let tier: Int
        let widths: [Int]

        /// The mockup's `width(j)`: the widest tier covering row `j` (−1 for none), and whether that row is
        /// the tier's bottom row.
        func width(_ j: Int) -> (width: Int, bottom: Bool) {
            var width = -1, bottom = false
            for (t, tierWidth) in widths.enumerated() {
                let k = j - (-height + t * step)
                guard k >= 0, k < tier else { continue }
                let w = NatureFogNoise.jsRoundInt(Double(tierWidth) * Double(k + 1) / Double(tier))
                if w >= width {
                    width = w
                    bottom = k == tier - 1
                }
            }
            return (width, bottom)
        }

        /// Paints row `j`: outline round the edge and under a wider row, dark on a tier's last row, lit left.
        func paintRow(_ art: inout NaturePixelArt, j: Int, trunk: Int) {
            let row = width(j)
            guard row.width >= 0 else { return }
            let up = width(j - 1).width, down = width(j + 1).width
            for i in -row.width...row.width {
                let edge = i == -row.width || i == row.width || abs(i) > up || (j + 1 <= -trunk - 1 && abs(i) > down)
                let paint: NaturePaint = edge ? .pineOutline : row.bottom ? .pineDark : i <= -1 ? .pineLight : i <= 1 ? .pineMid : .pineDark
                art.put(i, j, paint)
            }
        }
    }
}
