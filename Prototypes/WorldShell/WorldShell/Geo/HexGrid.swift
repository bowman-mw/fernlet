import Foundation

/// One fog cell: a pointy-top hexagon in axial coordinates on a ``HexGrid``.
nonisolated struct HexCell: Hashable, Sendable {
    var q: Int
    var r: Int
}

/// The fog's coarse hexagon grid, laid flat on the ground around a fixed origin.
///
/// Cells are about 30 m across, so the fog says "you've been round here", never which door you
/// went in (design page: "Home shows only coarse fog"). Pure geometry over ``GeoPoint``s: no map
/// type, so phase 2 keeps every lifted cell exactly where it was.
nonisolated struct HexGrid: Sendable {
    /// The grid's origin: cell (0, 0) is centred here.
    let origin: GeoPoint
    /// Centre-to-corner radius of one cell, in metres.
    let radius: Double

    /// The centre of `cell`, in metres east and north of the origin.
    func centreMetres(of cell: HexCell) -> (east: Double, north: Double) {
        let q = Double(cell.q), r = Double(cell.r)
        return (radius * 3.0.squareRoot() * (q + r / 2), radius * 1.5 * r)
    }

    /// The centre of `cell` as a place.
    func centre(of cell: HexCell) -> GeoPoint {
        let metres = centreMetres(of: cell)
        return origin.offset(east: metres.east, north: metres.north)
    }

    /// The cell that contains `point`.
    func cell(containing point: GeoPoint) -> HexCell {
        let metres = point.metres(from: origin)
        let q = (3.0.squareRoot() / 3 * metres.east - metres.north / 3) / radius
        let r = (2.0 / 3 * metres.north) / radius
        return Self.round(q: q, r: r)
    }

    /// Every cell whose centre lies within `metres` of `point` (always at least the cell under it).
    func cells(around point: GeoPoint, within metres: Double) -> [HexCell] {
        let middle = cell(containing: point)
        let reach = min(12, Int((metres / (radius * 1.5)).rounded(.up)) + 1)
        var found = [middle]
        for dq in -reach...reach {
            for dr in -reach...reach where dq != 0 || dr != 0 {
                let candidate = HexCell(q: middle.q + dq, r: middle.r + dr)
                if centre(of: candidate).distance(to: point) <= metres { found.append(candidate) }
            }
        }
        return found
    }

    /// The six corners of a cell, in metres relative to its own centre (east, north), pointy-top.
    var cornerOffsets: [(east: Double, north: Double)] {
        (0..<6).map { index in
            let angle = (60 * Double(index) + 30) * .pi / 180
            return (radius * cos(angle), radius * sin(angle))
        }
    }

    /// The six cells that share an edge with `cell`.
    func neighbours(of cell: HexCell) -> [HexCell] {
        [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)].map { HexCell(q: cell.q + $0.0, r: cell.r + $0.1) }
    }

    /// Rounds fractional axial coordinates to the nearest cell (cube rounding).
    private static func round(q: Double, r: Double) -> HexCell {
        let s = -q - r
        var rq = q.rounded(), rr = r.rounded()
        let rs = s.rounded()
        let dq = abs(rq - q), dr = abs(rr - r), ds = abs(rs - s)
        if dq > dr && dq > ds { rq = -rr - rs } else if dr > ds { rr = -rq - rs }
        return HexCell(q: Int(rq), r: Int(rr))
    }
}
