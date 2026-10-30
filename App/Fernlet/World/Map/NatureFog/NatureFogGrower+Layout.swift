import CoreGraphics
import Foundation
import WorldMapStore

extension NatureFogGrower {
    /// Everything that draws inside `area` (global points), in draw order: the ground of every hex that
    /// reaches into it, then the pieces whose frames cross it, sorted by y then x. Pieces from hexes just
    /// outside are included, so a tree or tuft spanning two tiles is drawn in both (each clipped to its own).
    func layout(in area: CGRect) -> NatureFogLayout {
        var layout = NatureFogLayout()
        let radius = scale.radius
        var behind = Set<HexCell>()
        var standing: [NatureTreePlan] = []
        for anchor in cells(in: area.insetBy(dx: -5 * radius, dy: -5 * radius)) {
            guard let plan = treePlan(anchor), stands(plan) else { continue }
            standing.append(plan)
            behind.formUnion(covered(by: plan))
        }
        let groundArea = area.insetBy(dx: -(radius + 2), dy: -(radius + 2))
        for cell in cells(in: area.insetBy(dx: -2 * radius, dy: -2 * radius)) {
            grow(cell, area: area, ground: groundArea.contains(scale.centre(of: cell)), covered: behind, into: &layout)
        }
        for plan in standing {
            guard let sprite = atlas.sprite(plan.sprite, look: plan.look) else { continue }
            let frame = sprite.frame(anchor: plan.root, unit: scale.unit), centre = scale.centre(of: plan.anchor)
            guard frame.intersects(area) else { continue }
            layout.pieces.append(NaturePiece(sprite: plan.sprite, frame: frame, sortY: centre.y + 0.5, sortX: centre.x, swayGroup: nil,
                                             look: plan.look))
            layout.trees.append(NatureStandingTree(anchor: plan.anchor, canopy: plan.canopy))
        }
        layout.pieces.sort { $0.sortY != $1.sortY ? $0.sortY < $1.sortY : $0.sortX < $1.sortX }
        return layout
    }

    /// One hex's ground and what grows on it, with the hex's own mulberry32 stream (`hash ^ 0x9e3779b9`).
    private func grow(_ cell: HexCell, area: CGRect, ground: Bool, covered: Set<HexCell>, into layout: inout NatureFogLayout) {
        guard case .wild(let kind) = state(cell) else { return }
        let land = self.land(cell)
        let at = NatureFogRules.offset(of: cell), centre = scale.centre(of: cell)
        let hash = NatureFogNoise.hash(at.col + 1_000, at.row + 1_000)
        var random = NatureRandom(seed: hash ^ 0x9E37_79B9)
        let spot = NatureFogSpot(cell: cell, centre: centre, anchor: snapped(centre), hash: hash, look: land.look, area: area)
        if land.set.isWater {
            if ground { sea(kind, spot: spot, random: &random, into: &layout) }
            return
        }
        if ground { layout.hexes.append((centre, groundPaint(kind, land: land, col: at.col, row: at.row, hash: hash), land.look)) }
        if kind == .pond {
            if ground { pond(cell, centre: centre, anchor: spot.anchor, random: &random, into: &layout) }
            if !scale.reduced && !covered.contains(cell) { reeds(spot, into: &layout) }
            return
        }
        guard !covered.contains(cell) else { return }
        if scale.reduced {
            guard land.set.isApproved, kind == .flowers, ground else { return }
            let unit = scale.unit
            for _ in 0..<3 {
                let x = spot.anchor.x + Double(-3 + random.below(6)) * unit, y = spot.anchor.y + Double(-3 + random.below(6)) * unit
                layout.waterMarks.append(NatureFogBlock(rect: CGRect(x: x, y: y, width: unit, height: unit), paint: NaturePaint.petals[random.below(4)],
                                                        look: spot.look))
            }
            return
        }
        if land.set.isApproved {
            approved(kind, spot: spot, ground: ground, random: &random, into: &layout)
        } else {
            terrain(kind, land: land, spot: spot, ground: ground, random: &random, into: &layout)
        }
    }

    /// What grows on a meadow or forest hex: the approved nature fog's specks, grass, flowers and boulder.
    private func approved(_ kind: NatureHexKind, spot: NatureFogSpot, ground: Bool, random: inout NatureRandom,
                          into layout: inout NatureFogLayout) {
        let unit = scale.unit
        switch kind {
        case .short where ground:
            for _ in 0..<2 {
                let x = spot.anchor.x + Double(-4 + random.below(8)) * unit, y = spot.anchor.y + Double(-4 + random.below(8)) * unit
                layout.specks.append(NatureFogBlock(rect: CGRect(x: x, y: y, width: unit, height: unit), paint: .speck, look: spot.look))
            }
        case .long, .flowers:
            grass(kind, spot: spot, into: &layout)
        case .boulder:
            boulder(spot, random: &random, into: &layout)
        default:
            break
        }
    }

    /// Long grass or wildflowers, by hash, swaying in one of three phase groups.
    func grass(_ kind: NatureHexKind, spot: NatureFogSpot, into layout: inout NatureFogLayout) {
        let variant = Int((spot.hash >> 12) % UInt32(kind == .long ? NatureFogAtlas.grassVariants : NatureFogAtlas.flowerVariants))
        let sway = ((spot.cell.q - spot.cell.r) % 3 + 3) % 3
        place(kind == .long ? .grass(variant) : .flowers(variant), anchor: spot.anchor, spot: spot, lift: 0, sway: sway, into: &layout)
    }

    /// The boulder, left or right of the hex centre.
    func boulder(_ spot: NatureFogSpot, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        let unit = scale.unit, side = random.next() < 0.5 ? -1 : 1, left = side * (3 + random.below(2)) - 4
        let corner = CGPoint(x: spot.anchor.x + Double(left) * unit, y: spot.anchor.y + unit)
        place(.boulder, anchor: corner, spot: spot, lift: 0.2, sway: nil, into: &layout)
    }

    /// The ground green: the lightest for an edge, the darker long-grass ground, the woods green deep in the
    /// woods (meadow and forest), else one of the three ground shades by hash.
    private func groundPaint(_ kind: NatureHexKind, land: TerrainHex, col: Int, row: Int, hash: UInt32) -> NaturePaint {
        if kind == .edge { return .edge }
        if kind == .long { return .long }
        if land.set.isApproved && NatureFogRules.woods(col, row) > 0.62 { return .woods }
        return NaturePaint.grasses[Int((hash >> 8) % 3)]
    }

    /// Adds a sprite piece anchored at `anchor` in `spot`'s look if its frame (at `unit` points a unit, by
    /// default the scale's) crosses the area.
    func place(_ key: NatureSprite, anchor: CGPoint, spot: NatureFogSpot, lift: Double, sway: Int?, unit: Double? = nil,
               into layout: inout NatureFogLayout) {
        guard let sprite = atlas.sprite(key, look: spot.look) else { return }
        let frame = sprite.frame(anchor: anchor, unit: unit ?? scale.unit)
        guard frame.intersects(spot.area) else { return }
        layout.pieces.append(NaturePiece(sprite: key, frame: frame, sortY: spot.centre.y + lift, sortX: spot.centre.x, swayGroup: sway,
                                         look: spot.look))
    }

    /// A pond hex: water a little larger than the hex (covering the seams), a shore on every side that faces
    /// grass, and at full detail 2 ripples and sometimes a lily pad.
    private func pond(_ cell: HexCell, centre: CGPoint, anchor: CGPoint, random: inout NatureRandom, into layout: inout NatureFogLayout) {
        layout.ponds.append(centre)
        for (index, side) in NatureFogRules.sides(of: cell).enumerated() where state(side) != .wild(.pond) {
            layout.shores.append((Self.corner(centre, scale.radius, index), Self.corner(centre, scale.radius, (index + 1) % 6)))
        }
        guard !scale.reduced else { return }
        let unit = scale.unit
        for row in 0..<2 {
            let x = anchor.x + Double(-3 + random.below(4)) * unit, y = anchor.y + Double(-4 + row * 3 + random.below(2)) * unit
            layout.waterMarks.append(NatureFogBlock(rect: CGRect(x: x, y: y, width: 3 * unit, height: unit), paint: .ripple))
        }
        if random.next() < 0.5 {
            let x = anchor.x + Double(-2 + random.below(3)) * unit
            layout.waterMarks.append(NatureFogBlock(rect: CGRect(x: x, y: anchor.y + 2 * unit, width: 2 * unit, height: unit), paint: .lily))
        }
    }

    /// Reeds on a pond's near (lower) shore: where its south-west or south-east neighbour isn't pond.
    private func reeds(_ spot: NatureFogSpot, into layout: inout NatureFogLayout) {
        let sides = NatureFogRules.sides(of: spot.cell)
        guard sides.count == 6, state(sides[1]) != .wild(.pond) || state(sides[0]) != .wild(.pond) else { return }
        let variant = Int((spot.hash >> 12) % UInt32(NatureFogAtlas.reedVariants))
        place(.reeds(variant), anchor: spot.anchor, spot: spot, lift: 0, sway: nil, into: &layout)
    }

    /// Corner `index` of a pointy-top hex (the mockup's `vert`: 30° + 60° steps, y down).
    static func corner(_ centre: CGPoint, _ radius: Double, _ index: Int) -> CGPoint {
        let angle = Double.pi / 3 * Double(index) + Double.pi / 6
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }
}

/// One hex being grown: its cell, centre, snapped anchor and hash, its look, and the area being laid out.
nonisolated struct NatureFogSpot {
    let cell: HexCell
    let centre: CGPoint
    let anchor: CGPoint
    let hash: UInt32
    let look: TerrainLook
    let area: CGRect
}
