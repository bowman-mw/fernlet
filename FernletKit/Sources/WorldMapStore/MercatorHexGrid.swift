import Foundation

/// One fog cell: a pointy-top hexagon in axial coordinates on the global ``MercatorHexGrid``.
///
/// A cell's coordinates never change, so a lifted cell stays exactly where it was on any base map,
/// phase 2's MapLibre included. ``id`` packs both coordinates into one `Int64` for storage.
public nonisolated struct HexCell: Hashable, Comparable, Sendable {
    /// The axial column.
    public var q: Int
    /// The axial row (grows southward, as Mercator `y` does).
    public var r: Int

    /// The offset that keeps both packed halves non-negative.
    private static let bias = 1 << 30

    /// A cell at axial (`q`, `r`).
    public init(q: Int, r: Int) {
        self.q = q
        self.r = r
    }

    /// Both coordinates in one value: `q` in the high 32 bits, `r` in the low, each biased by 2^30.
    public var id: Int64 {
        (Int64(q + Self.bias) << 32) | Int64(r + Self.bias)
    }

    /// The cell a packed ``id`` names, or nil when the value cannot be one (out of the grid's range).
    public init?(id: Int64) {
        guard id >= 0 else { return nil }
        let q = Int(id >> 32) - Self.bias
        let r = Int(id & 0xFFFF_FFFF) - Self.bias
        guard abs(q) < Self.bias, abs(r) < Self.bias else { return nil }
        self.init(q: q, r: r)
    }

    /// Orders by ``id``, so stored cell lists are deterministic.
    public static func < (lhs: HexCell, rhs: HexCell) -> Bool { lhs.id < rhs.id }
}

/// The fog's one hexagon grid, laid over the whole world in Web Mercator.
///
/// The cells are regular hexagons in Mercator space, so they stay regular on any north-up base map and
/// every cell keeps one stable ID worldwide. Their size on the ground shrinks away from the equator as
/// Mercator stretches: about 17.5 m centre-to-corner (35 m across) at 45°, 25 m at the equator, 12 m at
/// 60°. That is the "coarse" the design asks for: a cell says "you've been round here", never which
/// door you went in.
public nonisolated enum MercatorHexGrid {
    /// The centre-to-corner radius on the ground at ``referenceLatitude``, in metres.
    public static let referenceRadiusMetres = 17.5
    /// The latitude where a cell has its reference size.
    public static let referenceLatitude = 45.0
    /// The centre-to-corner radius in Mercator units (the same everywhere).
    public static let radius = referenceRadiusMetres * WebMercator.unitsPerMetre(at: referenceLatitude)

    /// The most cells one query returns. A query that would exceed it returns what it has so far;
    /// callers treat the cap as "zoomed too far out to draw cell by cell".
    public static let maxCellsPerQuery = 12_000

    /// The centre-to-corner radius on the ground near `latitude`, in metres.
    public static func groundRadius(at latitude: Double) -> Double {
        radius / WebMercator.unitsPerMetre(at: latitude)
    }

    /// The Mercator centre of `cell`.
    public static func centre(of cell: HexCell) -> (x: Double, y: Double) {
        let q = Double(cell.q), r = Double(cell.r)
        return (radius * 3.0.squareRoot() * (q + r / 2), radius * 1.5 * r)
    }

    /// The centre of `cell` as a place.
    public static func centreGeo(of cell: HexCell) -> GeoPoint {
        let centre = centre(of: cell)
        return WebMercator.geo(x: centre.x, y: centre.y)
    }

    /// The cell that contains the Mercator position (`x`, `y`).
    public static func cell(x: Double, y: Double) -> HexCell {
        let q = (3.0.squareRoot() / 3 * x - y / 3) / radius
        let r = (2.0 / 3 * y) / radius
        return round(q: q, r: r)
    }

    /// The cell that contains `point`.
    public static func cell(containing point: GeoPoint) -> HexCell {
        let unit = WebMercator.unit(point)
        return cell(x: unit.x, y: unit.y)
    }

    /// Every cell whose centre lies within `metres` of `point`, always including the cell under it.
    /// The reach is capped at 12 rings (about 400 m at 45°), so one fix can never lift a district.
    public static func cells(around point: GeoPoint, within metres: Double) -> [HexCell] {
        cells(around: point, within: metres, maxRings: 11)
    }

    /// The most rings ``disc(around:radius:)`` reaches: a home's 1 km at 60° latitude.
    public static let maxDiscRings = 63

    /// Every cell whose centre lies within `metres` of `point`, for the circles Fernlet draws uncovered
    /// around a home, a hotel or a place the person keeps (World build round 6: 1 km and about 300 m). Never
    /// written into the fog: drawn, so removing the place fogs its circle again. Capped at
    /// ``maxDiscRings`` rings.
    public static func disc(around point: GeoPoint, radius metres: Double) -> [HexCell] {
        cells(around: point, within: metres, maxRings: maxDiscRings)
    }

    /// The cells within `metres` of `point`, reaching at most `maxRings` rings.
    private static func cells(around point: GeoPoint, within metres: Double, maxRings: Int) -> [HexCell] {
        let middle = cell(containing: point)
        guard point.isValid, metres.isFinite, metres > 0 else { return [middle] }
        let reachUnits = metres * WebMercator.unitsPerMetre(at: point.latitude)
        // Clamp in Double before converting, so a huge radius can never overflow `Int`.
        let reach = Int(min((reachUnits / (radius * 1.5)).rounded(.up), Double(maxRings))) + 1
        let origin = WebMercator.unit(point)
        var found = [middle]
        for dq in -reach...reach {
            for dr in -reach...reach where dq != 0 || dr != 0 {
                let candidate = HexCell(q: middle.q + dq, r: middle.r + dr)
                let centre = centre(of: candidate)
                let dx = centre.x - origin.x, dy = centre.y - origin.y
                if (dx * dx + dy * dy).squareRoot() <= reachUnits { found.append(candidate) }
            }
        }
        return found
    }

    /// The six corners of a cell, as Mercator offsets from its centre (pointy-top).
    public static let cornerOffsets: [(x: Double, y: Double)] = (0..<6).map { index in
        let angle = (60 * Double(index) + 30) * .pi / 180
        return (radius * cos(angle), radius * sin(angle))
    }

    /// The six cells that share an edge with `cell`.
    public static func neighbours(of cell: HexCell) -> [HexCell] {
        [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)].map { HexCell(q: cell.q + $0.0, r: cell.r + $0.1) }
    }

    /// The cells that can touch `viewport`, padded by about one ring, row by row; at most
    /// ``maxCellsPerQuery``. Empty for an unusable viewport.
    public static func cells(in viewport: MapViewport) -> [HexCell] {
        // A real viewport lies on (or just around) the unit square; anything else is nonsense to skip.
        guard viewport.isUsable, abs(viewport.minX) < 4, abs(viewport.minY) < 4,
              viewport.width < 4, viewport.height < 4 else { return [] }
        let pad = radius * 2
        let rowHeight = radius * 1.5, columnWidth = radius * 3.0.squareRoot()
        let rMin = Int(((viewport.minY - pad) / rowHeight).rounded(.down))
        let rMax = Int(((viewport.minY + viewport.height + pad) / rowHeight).rounded(.up))
        let xMin = viewport.minX - pad, xMax = viewport.minX + viewport.width + pad
        guard rMax >= rMin, rMax - rMin < 600 else { return [] }
        var cells: [HexCell] = []
        for r in rMin...rMax {
            let qMin = Int((xMin / columnWidth - Double(r) / 2).rounded(.down))
            let qMax = Int((xMax / columnWidth - Double(r) / 2).rounded(.up))
            guard qMax >= qMin, qMax - qMin < 600 else { continue }
            for q in qMin...qMax { cells.append(HexCell(q: q, r: r)) }
            if cells.count >= maxCellsPerQuery { break }
        }
        return cells
    }

    /// Rounds fractional axial coordinates to the nearest cell (cube rounding).
    private static func round(q: Double, r: Double) -> HexCell {
        guard q.isFinite, r.isFinite, abs(q) < 1e9, abs(r) < 1e9 else { return HexCell(q: 0, r: 0) }
        let s = -q - r
        var rq = q.rounded(), rr = r.rounded()
        let rs = s.rounded()
        let dq = abs(rq - q), dr = abs(rr - r), ds = abs(rs - s)
        if dq > dr && dq > ds { rq = -rr - rs } else if dr > ds { rr = -rq - rs }
        return HexCell(q: Int(rq), r: Int(rr))
    }
}
