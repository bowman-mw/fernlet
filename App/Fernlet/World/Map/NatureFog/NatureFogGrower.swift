import CoreGraphics
import Foundation
import WorldMapStore

/// Lays out the nature fog over one area, from the mockup's `field()`: which hexes are edges, ponds or ground
/// cover, which trees stand, and where every piece goes (spec "What each hex is", "Trees and pines",
/// "Pieces on a hex").
///
/// Unlike the mockup's screenful of cells, the fog here is the whole world minus the uncovered cells, so a
/// hex's kind depends only on its own (col, row) and its neighbours: any area lays out the same pieces as
/// its neighbours do where they overlap, which is what lets tiles meet seamlessly. Cell states are kept
/// while the clearing stays the same (at most ``memoLimit``, then forgotten).
nonisolated final class NatureFogGrower {
    let scale: NatureFogScale
    let clearing: NatureFogClearing
    let atlas: NatureFogAtlas
    private var memo: [HexCell: NatureCellState] = [:]

    /// The most cell states kept before the memo starts again.
    static let memoLimit = 60_000

    /// A grower for `clearing` at `scale`, placing `atlas`'s sprites.
    init(scale: NatureFogScale, clearing: NatureFogClearing, atlas: NatureFogAtlas) {
        self.scale = scale
        self.clearing = clearing
        self.atlas = atlas
    }

    /// What `cell` is: clear, an edge (a neighbour is clear), a pond (all neighbours wild and the pond noise),
    /// or its ground cover.
    func state(_ cell: HexCell) -> NatureCellState {
        if let known = memo[cell] { return known }
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        let state = classify(cell)
        memo[cell] = state
        return state
    }

    private func classify(_ cell: HexCell) -> NatureCellState {
        guard !clearing.isClear(cell) else { return .clear }
        if MercatorHexGrid.neighbours(of: cell).contains(where: clearing.isClear) { return .wild(.edge) }
        let at = NatureFogRules.offset(of: cell)
        if NatureFogRules.isPond(at.col, at.row) { return .wild(.pond) }
        return .wild(NatureFogRules.ground(at.col, at.row))
    }

    /// Whether `cell` is wild ground a tree may stand over: fog, not an edge and not a pond.
    private func isDeepWild(_ cell: HexCell) -> Bool {
        guard case .wild(let kind) = state(cell) else { return false }
        return kind != .edge && kind != .pond
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

    /// The tree `anchor` would stand, before the wildness check: nil when the hex grows none.
    func treePlan(_ anchor: HexCell) -> NatureTreePlan? {
        guard isDeepWild(anchor) else { return nil }
        let at = NatureFogRules.offset(of: anchor)
        guard let choice = NatureFogRules.tree(at.col, at.row) else { return nil }
        let unit = scale.unit, base = snapped(scale.centre(of: anchor))
        let root = CGPoint(x: base.x, y: base.y + 3 * unit)
        if choice.pine {
            let height = NatureFogNoise.jsRoundInt((choice.big ? 2.4 : 1.8) * scale.radius / unit)
            return NatureTreePlan(anchor: anchor, sprite: .pine(height: height, odd: choice.variant & 1 == 1), root: root,
                                  canopy: CGPoint(x: root.x, y: root.y - Double(height) / 2 * unit),
                                  canopyRadius: Double(height) / 2 * unit * 0.8)
        }
        let radius = NatureFogNoise.jsRoundInt((choice.big ? 1.45 : 1.05) * scale.radius / unit)
        return NatureTreePlan(anchor: anchor, sprite: .tree(radius: radius, variant: choice.variant), root: root,
                              canopy: CGPoint(x: root.x, y: root.y + Double(NatureFogTreeArt.canopyRow(radius: radius)) * unit),
                              canopyRadius: Double(radius) * unit * 1.05)
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
    /// fog, not an edge and not a pond. Clearing any of them lifts the whole tree, and no new tree appears.
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
