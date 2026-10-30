import CoreGraphics
import Foundation
import WorldMapStore

nonisolated extension NatureFogGrower {
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
            guard let sprite = atlas.sprite(plan.sprite) else { continue }
            let frame = sprite.frame(anchor: plan.root, unit: scale.unit), centre = scale.centre(of: plan.anchor)
            guard frame.intersects(area) else { continue }
            layout.pieces.append(NaturePiece(sprite: plan.sprite, frame: frame, sortY: centre.y + 0.5, sortX: centre.x, swayGroup: nil))
            layout.trees.append(NatureStandingTree(anchor: plan.anchor, canopy: plan.canopy))
        }
        layout.pieces.sort { $0.sortY != $1.sortY ? $0.sortY < $1.sortY : $0.sortX < $1.sortX }
        return layout
    }

    /// One hex's ground and what grows on it, with the hex's own mulberry32 stream (`hash ^ 0x9e3779b9`).
    private func grow(_ cell: HexCell, area: CGRect, ground: Bool, covered: Set<HexCell>, into layout: inout NatureFogLayout) {
        guard case .wild(let kind) = state(cell) else { return }
        let at = NatureFogRules.offset(of: cell), centre = scale.centre(of: cell)
        let hash = NatureFogNoise.hash(at.col + 1_000, at.row + 1_000)
        var random = NatureRandom(seed: hash ^ 0x9E37_79B9)
        let anchor = snapped(centre), unit = scale.unit
        if ground { layout.hexes.append((centre, groundPaint(kind, col: at.col, row: at.row, hash: hash))) }
        if kind == .pond {
            if ground { pond(cell, centre: centre, anchor: anchor, random: &random, into: &layout) }
            if !scale.reduced && !covered.contains(cell) { reeds(cell, centre: centre, anchor: anchor, hash: hash, area: area, into: &layout) }
            return
        }
        guard !covered.contains(cell) else { return }
        if scale.reduced {
            guard kind == .flowers, ground else { return }
            for _ in 0..<3 {
                let x = anchor.x + Double(-3 + random.below(6)) * unit, y = anchor.y + Double(-3 + random.below(6)) * unit
                layout.waterMarks.append(NatureFogBlock(rect: CGRect(x: x, y: y, width: unit, height: unit), paint: NaturePaint.petals[random.below(4)]))
            }
            return
        }
        switch kind {
        case .short where ground:
            for _ in 0..<2 {
                let x = anchor.x + Double(-4 + random.below(8)) * unit, y = anchor.y + Double(-4 + random.below(8)) * unit
                layout.specks.append(NatureFogBlock(rect: CGRect(x: x, y: y, width: unit, height: unit), paint: .speck))
            }
        case .long, .flowers:
            let variant = Int((hash >> 12) % UInt32(kind == .long ? NatureFogAtlas.grassVariants : NatureFogAtlas.flowerVariants))
            let sway = ((cell.q - cell.r) % 3 + 3) % 3
            place(kind == .long ? .grass(variant) : .flowers(variant), anchor: anchor, centre: centre, lift: 0, sway: sway, area: area, into: &layout)
        case .boulder:
            let side = random.next() < 0.5 ? -1 : 1, left = side * (3 + random.below(2)) - 4
            let corner = CGPoint(x: anchor.x + Double(left) * unit, y: anchor.y + unit)
            place(.boulder, anchor: corner, centre: centre, lift: 0.2, sway: nil, area: area, into: &layout)
        default:
            break
        }
    }

    /// The ground green: the lightest for an edge, the darker long-grass ground, the woods green deep in the
    /// woods, else one of the three grass greens by hash.
    private func groundPaint(_ kind: NatureHexKind, col: Int, row: Int, hash: UInt32) -> NaturePaint {
        if kind == .edge { return .edge }
        if kind == .long { return .long }
        if NatureFogRules.woods(col, row) > 0.62 { return .woods }
        return NaturePaint.grasses[Int((hash >> 8) % 3)]
    }

    /// Adds a sprite piece anchored at `anchor` if its frame crosses `area`.
    private func place(_ key: NatureSprite, anchor: CGPoint, centre: CGPoint, lift: Double, sway: Int?, area: CGRect,
                       into layout: inout NatureFogLayout) {
        guard let sprite = atlas.sprite(key) else { return }
        let frame = sprite.frame(anchor: anchor, unit: scale.unit)
        guard frame.intersects(area) else { return }
        layout.pieces.append(NaturePiece(sprite: key, frame: frame, sortY: centre.y + lift, sortX: centre.x, swayGroup: sway))
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
    private func reeds(_ cell: HexCell, centre: CGPoint, anchor: CGPoint, hash: UInt32, area: CGRect, into layout: inout NatureFogLayout) {
        let sides = NatureFogRules.sides(of: cell)
        guard sides.count == 6, state(sides[1]) != .wild(.pond) || state(sides[0]) != .wild(.pond) else { return }
        let variant = Int((hash >> 12) % UInt32(NatureFogAtlas.reedVariants))
        place(.reeds(variant), anchor: anchor, centre: centre, lift: 0, sway: nil, area: area, into: &layout)
    }

    /// Corner `index` of a pointy-top hex (the mockup's `vert`: 30° + 60° steps, y down).
    static func corner(_ centre: CGPoint, _ radius: Double, _ index: Int) -> CGPoint {
        let angle = Double.pi / 3 * Double(index) + Double.pi / 6
        return CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
    }
}
