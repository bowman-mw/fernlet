import CoreGraphics
import Foundation
import WorldMapStore

nonisolated extension NatureFogGrower {
    /// The sand-ripple colours (the mockup's `ripples`).
    private static let rippleShadow: UInt32 = 0xC9AA6A
    private static let rippleLight: UInt32 = 0xF1E0B6

    /// A sea hex (World-Exploration-Spec §1): water ground with no seam, a sand line along every side that meets
    /// fogged land, and at full detail a few wave marks (or the water's specks).
    func sea(_ kind: NatureHexKind, spot: NatureFogSpot, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        layout.seas.append((spot.centre, kind == .edge ? .edge : NaturePaint.grasses[Int((spot.hash >> 8) % 3)]))
        for (index, side) in NatureFogRules.sides(of: spot.cell).enumerated() where state(side) != .clear && !land(side).set.isWater {
            layout.coasts.append((Self.corner(spot.centre, scale.radius, index), Self.corner(spot.centre, scale.radius, (index + 1) % 6)))
        }
        guard !scale.reduced else { return }
        switch kind {
        case .waves: waves(spot, random: &random, into: &layout)
        case .short: dots(spot, count: 2, inks: [.paint(.speck)], random: &random, into: &layout)
        default: break
        }
    }

    /// What grows on a hex of a set other than meadow and forest (the mockup's `terra()` per kind): specks,
    /// sand ripples, scree, lichen, cracks and snow on the ground; grass, flowers, boulders, crop rows and roofs
    /// as pieces.
    func terrain(_ kind: NatureHexKind, land: TerrainHex, spot: NatureFogSpot, ground: Bool, random: inout NatureRandom,
                 into layout: inout NatureFogLayout) {
        switch kind {
        case .long, .flowers: grass(kind, spot: spot, into: &layout)
        case .boulder: boulder(spot, random: &random, into: &layout)
        case .crops:
            let wheat = land.season != .winter && (spot.hash >> 5) % 3 != 0
            place(.crops(wheat: wheat), anchor: spot.anchor, spot: spot, lift: 0, sway: nil, into: &layout)
        case .roof:
            let roofAnchor = CGPoint(x: spot.anchor.x, y: spot.anchor.y + 3 * scale.unit)
            place(.house(variant: Int((spot.hash >> 7) % 7)), anchor: roofAnchor, spot: spot, lift: 0.4, sway: nil,
                  unit: scale.unit * 0.8, into: &layout)
        default:
            guard ground else { return }
            groundMarks(kind, spot: spot, random: &random, into: &layout)
        }
    }

    /// The marks a kind leaves on the ground picture.
    private func groundMarks(_ kind: NatureHexKind, spot: NatureFogSpot, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        switch kind {
        case .short: dots(spot, count: 2, inks: [.paint(.speck)], random: &random, into: &layout)
        case .ripples: ripples(spot, random: &random, into: &layout)
        case .scree: dots(spot, count: 6, inks: [.fixed(0x7E796F), .fixed(0xC4BFB5), .fixed(0x8C877D)], width: 2, random: &random, into: &layout)
        case .lichen: dots(spot, count: 6, inks: [.fixed(0xC0743A), .fixed(0xC9A63A), .fixed(0xE2DDBA)], random: &random, into: &layout)
        case .crack: cracks(spot, random: &random, into: &layout)
        case .snow: dots(spot, count: 3, inks: [.fixed(0xFFFFFF)], width: 3, random: &random, into: &layout)
        default: break
        }
    }

    /// One mark of `width` × `height` units at unit offset (`x`, `y`) from the hex's anchor.
    private func mark(_ spot: NatureFogSpot, _ x: Int, _ y: Int, _ width: Int, _ height: Int, _ ink: NatureInk,
                      into layout: inout NatureFogLayout) {
        let unit = scale.unit
        let rect = CGRect(x: spot.anchor.x + Double(x) * unit, y: spot.anchor.y + Double(y) * unit,
                          width: Double(width) * unit, height: Double(height) * unit)
        layout.marks.append(NatureFogMark(rect: rect, ink: ink, look: spot.look))
    }

    /// The mockup's `dots`: `count` marks `width` units wide at random spots within 4 units, each a random ink.
    private func dots(_ spot: NatureFogSpot, count: Int, inks: [NatureInk], width: Int = 1, random: inout NatureRandom,
                      into layout: inout NatureFogLayout) {
        guard !inks.isEmpty else { return }
        for _ in 0..<count {
            let x = -4 + random.below(8), y = -4 + random.below(8)
            mark(spot, x, y, width, 1, inks[random.below(inks.count)], into: &layout)
        }
    }

    /// Two wave marks: a crest over a trough (the mockup's `waves`, light `#B6DAEE`, dark `#6E93AE`).
    private func waves(_ spot: NatureFogSpot, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        let ink = NatureInk.pair(light: 0xB6DAEE, dark: 0x6E93AE)
        for row in 0..<2 {
            let x = -4 + random.below(5), y = -4 + row * 4 + random.below(2)
            mark(spot, x, y, 1, 1, ink, into: &layout)
            mark(spot, x + 1, y + 1, 2, 1, ink, into: &layout)
            mark(spot, x + 3, y, 1, 1, ink, into: &layout)
        }
    }

    /// Two sand ripples: a lit crest over a shadowed foot (the mockup's `ripples`).
    private func ripples(_ spot: NatureFogSpot, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        for row in 0..<2 {
            let x = -5 + random.below(3), y = -3 + row * 4
            mark(spot, x, y + 1, 1, 1, .fixed(Self.rippleShadow), into: &layout)
            mark(spot, x + 1, y, 4, 1, .fixed(Self.rippleShadow), into: &layout)
            mark(spot, x + 1, y - 1, 4, 1, .fixed(Self.rippleLight), into: &layout)
            mark(spot, x + 5, y + 1, 1, 1, .fixed(Self.rippleShadow), into: &layout)
        }
    }

    /// A crack across the ice: six steps right, each one up or down (the mockup's `cracks`).
    private func cracks(_ spot: NatureFogSpot, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        var x = -4 + random.below(3), y = -3 + random.below(3)
        for _ in 0..<6 {
            mark(spot, x, y, 1, 1, .fixed(0x9DB9C6), into: &layout)
            x += 1
            y = max(-5, min(5, y + (random.next() < 0.5 ? 1 : -1)))
        }
    }
}
