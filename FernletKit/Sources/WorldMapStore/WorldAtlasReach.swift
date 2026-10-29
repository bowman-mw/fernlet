import Foundation

/// The ocean-or-sea reach search (Docs/World-Atlas-Pack.md: "the nearest water sub-cell within
/// `WorldAtlas.oceanReachMetres` of the fix; its `OCEA` code names an ocean or a sea, never both").
///
/// Bounded: the cells within the reach of the fix's cell, at most ``WorldAtlas/maxReachSpan`` either side in
/// rows and in columns (81 cells), and in a coast cell its 256 sub-cells. Water whose `OCEA` code is 0 (a lake,
/// the Caspian) never counts.
extension WorldAtlas {
    /// The ocean or sea whose water lies nearest `point` within `metres`, or nil when none does.
    public func water(near point: GeoPoint, within metres: Double = WorldAtlas.oceanReachMetres) -> AtlasWater? {
        guard point.isValid, metres.isFinite, metres >= 0 else { return nil }
        let spot = grid.spot(of: point)
        let window = reachWindow(spot, latitude: point.latitude, metres: metres)
        var best: (metres: Double, code: UInt8)?
        // Bounded: both ranges are clamped to ±maxReachSpan, so at most 81 cells.
        for rowOffset in window.rows {
            let row = spot.row + rowOffset
            guard row >= 0, row < grid.rows else { continue }
            for colOffset in window.cols {
                let col = spot.col + colOffset
                let index = grid.index(row: row, col: col)
                let code = oceans[index]
                guard code != 0, land[index] != 1 else { continue }
                let box = CellBox(grid: grid, row: row, unwrappedCol: col)
                let distance = waterDistance(in: box, cell: index, from: point, longitude: spot.longitude)
                guard distance <= metres, distance < (best?.metres ?? .infinity) else { continue }
                best = (distance, code)
            }
        }
        guard let best else { return nil }
        return waterBody(code: best.code)
    }

    /// The ocean or sea an `OCEA` code names: 1–5 an ocean, `6 + i` sea `i`.
    func waterBody(code: UInt8) -> AtlasWater? {
        if let ocean = AtlasOcean(packCode: code) { return .ocean(ocean) }
        let sea = Int(code) - 6
        guard sea >= 0, sea < seas.count else { return nil }
        return .sea(seas[sea])
    }

    /// The row and column offsets from the fix's cell that the reach can touch, clamped to ±maxReachSpan.
    func reachWindow(_ spot: AtlasGrid.Spot, latitude: Double, metres: Double) -> (rows: ClosedRange<Int>,
                                                                                     cols: ClosedRange<Int>) {
        let step = grid.step
        let dLat = metres / GeoPoint.metresPerDegree
        let dLon = metres / (GeoPoint.metresPerDegree * max(cos(latitude * .pi / 180), 1e-6))
        let rowPosition = spot.fracRow * step, colPosition = spot.fracCol * step
        let top = Self.clampedOffset((rowPosition - dLat) / step), bottom = Self.clampedOffset((rowPosition + dLat) / step)
        let west = Self.clampedOffset((colPosition - dLon) / step), east = Self.clampedOffset((colPosition + dLon) / step)
        return (min(top, bottom)...max(top, bottom), min(west, east)...max(west, east))
    }

    /// `cells` rounded down and clamped to ±maxReachSpan (in Double first, so a huge value never traps).
    static func clampedOffset(_ cells: Double) -> Int {
        guard cells.isFinite else { return 0 }
        let span = Double(maxReachSpan)
        return Int(min(max(cells.rounded(.down), -span), span))
    }

    /// How far `point` lies from the nearest water in `box`: the whole box for a water cell, the nearest water
    /// sub-cell for a coast cell (256 at most), infinity when a coast cell has no water sub-cell.
    func waterDistance(in box: CellBox, cell: Int, from point: GeoPoint, longitude: Double) -> Double {
        guard land[cell] == 2 else { return box.distance(from: point, longitude: longitude) }
        let side = AtlasGrid.subdivisions
        var nearest = Double.infinity
        // Bounded: 16 × 16 sub-cells.
        for sy in 0..<side {
            for sx in 0..<side where !subCellIsLand(cell: cell, sx: sx, sy: sy) {
                nearest = min(nearest, box.subBox(sx: sx, sy: sy).distance(from: point, longitude: longitude))
            }
        }
        return nearest
    }
}

/// A grid cell's (or sub-cell's) edges in degrees, its west edge left unwrapped so that distances measured
/// from a fix near the antimeridian come out right.
nonisolated struct CellBox: Equatable {
    /// The north edge.
    let north: Double
    /// The south edge.
    let south: Double
    /// The west edge (may lie outside -180..<180).
    let west: Double
    /// The east edge.
    let east: Double

    /// Cell (`row`, `unwrappedCol`) of `grid`.
    init(grid: AtlasGrid, row: Int, unwrappedCol: Int) {
        let step = grid.step
        north = 90 - Double(row) * step
        south = north - step
        west = -180 + Double(unwrappedCol) * step
        east = west + step
    }

    /// A box with the edges given.
    init(north: Double, south: Double, west: Double, east: Double) {
        self.north = north
        self.south = south
        self.west = west
        self.east = east
    }

    /// Sub-cell (`sx`, `sy`) of this box, counted from its north-west corner.
    func subBox(sx: Int, sy: Int) -> CellBox {
        let height = (north - south) / Double(AtlasGrid.subdivisions)
        let width = (east - west) / Double(AtlasGrid.subdivisions)
        let top = north - Double(sy) * height, left = west + Double(sx) * width
        return CellBox(north: top, south: top - height, west: left, east: left + width)
    }

    /// The flat-earth distance in metres from `point` (at normalised `longitude`) to the nearest part of the
    /// box: zero inside it.
    func distance(from point: GeoPoint, longitude: Double) -> Double {
        let lat = point.latitude
        let dy = lat > north ? lat - north : (lat < south ? south - lat : 0)
        let dx = longitude < west ? west - longitude : (longitude > east ? longitude - east : 0)
        let northMetres = dy * GeoPoint.metresPerDegree
        let eastMetres = dx * point.metresPerDegreeLongitude
        return (northMetres * northMetres + eastMetres * eastMetres).squareRoot()
    }
}
