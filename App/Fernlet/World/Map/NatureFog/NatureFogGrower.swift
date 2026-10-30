import CoreGraphics
import Foundation
import WorldMapStore

/// Lays out the nature fog over one area, from the mockup's `field()`: which hexes are edges or ground
/// cover (no ponds: water only where the atlas has it, owner 2026-10-30), which trees stand, and where every piece goes (spec "What each hex is", "Trees and pines",
/// "Pieces on a hex").
///
/// Unlike the mockup's screenful of cells, the fog here is the whole world minus the uncovered cells, so a
/// hex's kind depends only on its own (col, row) and its neighbours: any area lays out the same pieces as
/// its neighbours do where they overlap, which is what lets tiles meet seamlessly. Cell states are kept
/// while the clearing stays the same (at most ``memoLimit``, then forgotten).
///
/// **The land under the fog** (World-Exploration-Spec §1). With a ``NatureTerrainMemo`` each hex draws its own
/// terrain set and season (the mockup's `terra()`): the sea, desert, mountain, tropical, boreal, urban, tundra and
/// ice sets swap the ground and what grows, on the same hexes and in the same back-to-front order. Grassland and
/// temperate forest in summer grow exactly what the approved fog grows; with no memo every hex is that.
nonisolated final class NatureFogGrower {
    let scale: NatureFogScale
    let clearing: NatureFogClearing
    let atlas: NatureFogAtlas
    /// What land each hex is; nil for today's nature fog everywhere.
    let terrain: NatureTerrainMemo?
    private var memo: [HexCell: NatureCellState] = [:]

    /// The most cell states kept before the memo starts again.
    static let memoLimit = 60_000

    /// A grower for `clearing` at `scale`, placing `atlas`'s sprites, on `terrain`'s land (none: the nature fog).
    init(scale: NatureFogScale, clearing: NatureFogClearing, atlas: NatureFogAtlas, terrain: NatureTerrainMemo? = nil) {
        self.scale = scale
        self.clearing = clearing
        self.atlas = atlas
        self.terrain = terrain
    }

    /// What `cell` is: clear, an edge (a neighbour is clear), or its ground cover. The mockup's random
    /// ponds are gone (owner, 2026-10-30): water is only the atlas's, drawn by the water set.
    func state(_ cell: HexCell) -> NatureCellState {
        if let known = memo[cell] { return known }
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        let state = classify(cell)
        memo[cell] = state
        return state
    }

    /// The land `cell` draws as: the terrain's answer, or the approved meadow with no terrain.
    func land(_ cell: HexCell) -> TerrainHex {
        terrain?.hex(cell) ?? .approved
    }

    private func classify(_ cell: HexCell) -> NatureCellState {
        guard !clearing.isClear(cell) else { return .clear }
        if MercatorHexGrid.neighbours(of: cell).contains(where: clearing.isClear) { return .wild(.edge) }
        let at = NatureFogRules.offset(of: cell), land = self.land(cell)
        return .wild(TerrainRules.ground(land, col: at.col, row: at.row))
    }

    /// Whether `cell` is wild ground a tree may stand over: fog, not an edge, not the sea.
    private func isDeepWild(_ cell: HexCell) -> Bool {
        guard case .wild(let kind) = state(cell) else { return false }
        return kind != .edge && !land(cell).set.isWater
    }

    /// Every cell whose centre lies in `area` (global points), row by row; bounded to 400 rows and columns.
    func cells(in area: CGRect) -> [HexCell] {
        let rowHeight = scale.radius * 1.5, width = scale.hexWidth
        guard rowHeight > 0, area.minX.isFinite, area.maxY.isFinite else { return [] }
        let rMin = Int((area.minY / rowHeight).rounded(.down)), rMax = Int((area.maxY / rowHeight).rounded(.up))
        guard rMax >= rMin, rMax - rMin < 400 else { return [] }
        var found: [HexCell] = []
        for r in rMin...rMax {
            let qMin = Int((area.minX / width - Double(r) / 2).rounded(.down))
            let qMax = Int((area.maxX / width - Double(r) / 2).rounded(.up))
            guard qMax >= qMin, qMax - qMin < 400 else { continue }
            for q in qMin...qMax {
                let cell = HexCell(q: q, r: r)
                if area.contains(scale.centre(of: cell)) { found.append(cell) }
            }
        }
        return found
    }

    /// The pixel-snapped anchor for a hex centre: the global s-grid.
    func snapped(_ point: CGPoint) -> CGPoint {
        let unit = scale.unit
        return CGPoint(x: NatureFogNoise.jsRound(point.x / unit) * unit, y: NatureFogNoise.jsRound(point.y / unit) * unit)
    }

    /// The tree, palm, cactus or peak `anchor` would stand, before the wildness check: nil when the hex grows none.
    func treePlan(_ anchor: HexCell) -> NatureTreePlan? {
        guard isDeepWild(anchor) else { return nil }
        let at = NatureFogRules.offset(of: anchor), here = land(anchor)
        let around = NatureFogRules.sides(of: anchor).map { land($0) }
        guard let stand = TerrainRules.stand(here, col: at.col, row: at.row, neighbours: around) else { return nil }
        let base = snapped(scale.centre(of: anchor))
        let root = CGPoint(x: base.x, y: base.y + 3 * scale.unit)
        return TerrainStandPlanner(scale: scale).plan(stand, anchor: anchor, root: root, land: here)
    }

    /// The cells round a tree's canopy within `reach`, as the mockup scans them (its offset window).
    private func cells(round plan: NatureTreePlan, within reach: Double) -> [HexCell] {
        let at = NatureFogRules.offset(of: plan.anchor)
        let rows = Int((reach / (1.5 * scale.radius)).rounded(.up)) + 1, columns = Int((reach / scale.hexWidth).rounded(.up)) + 1
        guard rows < 40, columns < 40 else { return [] }
        var found: [HexCell] = []
        for dr in -rows...rows {
            for dc in -columns...columns {
                let cell = NatureFogRules.cell(col: at.col + dc, row: at.row + dr), centre = scale.centre(of: cell)
                if hypot(centre.x - plan.canopy.x, centre.y - plan.canopy.y) <= reach { found.append(cell) }
            }
        }
        return found
    }

    /// The wildness rule: a tree stands only while every hex within canopy radius + 0.7 R of its canopy is
    /// fog, not an edge and not the sea. Clearing any of them lifts the whole tree, and no new tree
    /// appears.
    func stands(_ plan: NatureTreePlan) -> Bool {
        cells(round: plan, within: plan.canopyRadius + 0.7 * scale.radius).allSatisfy(isDeepWild)
    }

    /// The hexes behind a standing tree (centre at or above the anchor's, within canopy radius + 0.2 R): ground only.
    func covered(by plan: NatureTreePlan) -> [HexCell] {
        let anchorY = scale.centre(of: plan.anchor).y, limit = plan.canopyRadius + 0.2 * scale.radius
        return cells(round: plan, within: limit).filter { cell in
            let centre = scale.centre(of: cell)
            return centre.y <= anchorY && hypot(centre.x - plan.canopy.x, centre.y - plan.canopy.y) < limit
        }
    }
}

/// Sizes a stand's sprite and canopy at one scale, as the mockup's `terra()` does (pines, round trees and the
/// approved sizes exactly as ``NatureFogGrower`` placed them before the terrain): the season turns a temperate
/// round tree bare (winter) or into blossom (spring, 2 in 5 by `hash(col+77, row+77)`), and snows its pines.
nonisolated struct TerrainStandPlanner {
    let scale: NatureFogScale

    /// The plan for `stand` on `anchor`, rooted at `root`, on `land`.
    func plan(_ stand: TerrainStand, anchor: HexCell, root: CGPoint, land: TerrainHex) -> NatureTreePlan {
        let unit = scale.unit, units = scale.radius / unit
        func size(_ big: Double, _ small: Double) -> Int { NatureFogNoise.jsRoundInt((stand.big ? big : small) * units) }
        func upright(_ sprite: NatureSprite, height: Int, share: Double) -> NatureTreePlan {
            NatureTreePlan(anchor: anchor, sprite: sprite, root: root, canopy: CGPoint(x: root.x, y: root.y - Double(height) / 2 * unit),
                           canopyRadius: Double(height) / 2 * unit * share, look: land.look)
        }
        let winter = land.season == .winter, at = NatureFogRules.offset(of: anchor)
        switch stand.kind {
        case .pine:
            let height = size(2.4, 1.8)
            return upright(winter ? .snowyPine(height: height, odd: stand.variant & 1 == 1) : .pine(height: height, odd: stand.variant & 1 == 1),
                           height: height, share: 0.8)
        case .round where winter:
            let radius = size(1.3, 1.0)
            return upright(.bare(radius: radius, variant: stand.variant), height: radius + 3, share: 0.7)
        case .round:
            let radius = size(1.45, 1.05)
            let blossom = land.season == .spring && NatureFogNoise.hash(at.col + 77, at.row + 77) % 100 < 40
            return NatureTreePlan(anchor: anchor, sprite: blossom ? .blossom(radius: radius, variant: stand.variant) : .tree(radius: radius, variant: stand.variant),
                                  root: root, canopy: CGPoint(x: root.x, y: root.y + Double(NatureFogTreeArt.canopyRow(radius: radius)) * unit),
                                  canopyRadius: Double(radius) * unit * 1.05, look: land.look)
        case .palm:
            let height = size(2.3, 1.8)
            return upright(.palm(height: height, variant: stand.variant), height: height, share: 0.75)
        case .cactus:
            let height = size(1.6, 1.1)
            return upright(.cactus(height: height, variant: stand.variant), height: height, share: 0.7)
        case .peak:
            let width = size(3.2, 2.4), height = size(2.6, 1.9)
            let plan = upright(.peak(width: width, height: height, variant: stand.variant), height: height, share: 0.7)
            return NatureTreePlan(anchor: anchor, sprite: plan.sprite, root: root, canopy: plan.canopy,
                                  canopyRadius: max(Double(height), Double(width) / 2) * unit * 0.7, look: land.look)
        }
    }
}
