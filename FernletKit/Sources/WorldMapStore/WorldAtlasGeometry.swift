import Foundation

/// The atlas's one global raster grid (Docs/World-Atlas-Pack.md, "The grid"): `cols = 2 × rows` square cells
/// of `180° / rows`, row 0 just south of 90°N, column 0 starting at 180°W. The shipped pack uses 1,800 rows
/// (0.1° cells); tests build 18 or 36.
public nonisolated struct AtlasGrid: Hashable, Sendable {
    /// The most rows a pack may declare: the shipped 0.1° grid. A finer grid raises this in the same commit.
    public static let maxRows = 1_800
    /// The fewest rows a pack may declare.
    public static let minRows = 2
    /// Sub-cells on a side of a coast cell's mask.
    public static let subdivisions = 16

    /// Rows, north to south.
    public let rows: Int
    /// Columns, west to east (always twice the rows).
    public let cols: Int

    /// A grid of `rows` rows, or nil outside ``minRows``...``maxRows``.
    public init?(rows: Int) {
        guard rows >= Self.minRows, rows <= Self.maxRows else { return nil }
        self.rows = rows
        cols = rows * 2
    }

    /// Degrees on a cell's side.
    public var step: Double { 180 / Double(rows) }

    /// Cells in the whole grid.
    public var cellCount: Int { rows * cols }

    /// A point's place on the grid: its cell and where in the cell it lies.
    public struct Spot: Hashable, Sendable {
        /// The cell's row.
        public let row: Int
        /// The cell's column.
        public let col: Int
        /// How far south of the cell's north edge, 0..<1.
        public let fracRow: Double
        /// How far east of the cell's west edge, 0..<1.
        public let fracCol: Double
        /// The longitude the spot was found at, normalised to -180..<180.
        public let longitude: Double
    }

    /// Where `point` lies, by the doc's rule (latitude clamped to the grid, longitude normalised).
    public func spot(of point: GeoPoint) -> Spot {
        let rowPosition = min(max((90 - point.latitude) / step, 0), Double(rows) - 1e-9)
        let longitude = Self.normalised(point.longitude)
        let colPosition = min(max((longitude + 180) / step, 0), Double(cols) - 1e-9)
        let row = min(Int(rowPosition.rounded(.down)), rows - 1)
        let col = min(Int(colPosition.rounded(.down)), cols - 1)
        return Spot(row: row, col: col, fracRow: rowPosition - Double(row), fracCol: colPosition - Double(col),
                    longitude: longitude)
    }

    /// The flat index of row `row`, column `col` (the column wrapped round the globe).
    public func index(row: Int, col: Int) -> Int {
        let wrapped = ((col % cols) + cols) % cols
        return min(max(row, 0), rows - 1) * cols + wrapped
    }

    /// The flat index of the cell under `point`.
    public func index(of point: GeoPoint) -> Int {
        let spot = spot(of: point)
        return index(row: spot.row, col: spot.col)
    }

    /// `longitude` in -180..<180 (a non-finite value becomes 0).
    static func normalised(_ longitude: Double) -> Double {
        guard longitude.isFinite else { return 0 }
        var value = longitude.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }
}

/// A polygon from the pack (a country or an urban boundary): its bounding box and rings in 1e-5 degrees,
/// tested with the even-odd rule, so a hole is just another ring.
///
/// Decoding is bounded: at most ``maxRings`` rings and ``maxPointsPerRing`` points a ring (and never more
/// points than the section has bytes left), every point checked onto the globe.
public nonisolated struct AtlasPolygon: Hashable, Sendable {
    /// The most rings one feature may have (Canada and Indonesia, the most fragmented, have a few thousand).
    public static let maxRings = 10_000
    /// The most points one ring may have (the longest simplified 1:10m coastline ring has under 100,000); a
    /// ring needs at least three.
    public static let maxPointsPerRing = 200_000
    /// Stored units in one degree.
    public static let unitsPerDegree = 100_000.0

    /// West, south, east, north edges in 1e-5 degrees.
    public let minLon: Int32, minLat: Int32, maxLon: Int32, maxLat: Int32
    /// Every ring's longitudes, end to end.
    let lons: [Int32]
    /// Every ring's latitudes, end to end.
    let lats: [Int32]
    /// Where each ring ends in ``lons`` and ``lats``.
    let ringEnds: [Int]

    /// Whether `point` lies in the box (edges included).
    public func boxContains(_ point: GeoPoint) -> Bool {
        let lon = point.longitude * Self.unitsPerDegree, lat = point.latitude * Self.unitsPerDegree
        return lon >= Double(minLon) && lon <= Double(maxLon) && lat >= Double(minLat) && lat <= Double(maxLat)
    }

    /// Whether `point` lies inside: the box first, then the even-odd rule over every ring.
    public func contains(_ point: GeoPoint) -> Bool {
        guard point.isValid, boxContains(point) else { return false }
        let x = point.longitude * Self.unitsPerDegree, y = point.latitude * Self.unitsPerDegree
        var inside = false
        var start = 0
        // Bounded: every ring is walked once; rings and points are capped at decode.
        for end in ringEnds {
            guard end - start >= 3 else { start = end; continue }
            var previous = end - 1
            for current in start..<end {
                let xi = Double(lons[current]), yi = Double(lats[current])
                let xj = Double(lons[previous]), yj = Double(lats[previous])
                if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
                previous = current
            }
            start = end
        }
        return inside
    }

    /// How many rings the outline has (holes and islands are rings too).
    public var ringCount: Int { ringEnds.count }

    /// Ring `index`'s points in order, for a screen to draw a country, state or province line (the last
    /// point repeats the first when the source closed it); empty for an index out of range.
    public func ring(_ index: Int) -> [GeoPoint] {
        guard ringEnds.indices.contains(index) else { return [] }
        let start = index == 0 ? 0 : ringEnds[index - 1], end = ringEnds[index]
        guard start <= end, end <= lons.count, end <= lats.count else { return [] }
        // Bounded: one ring, at most maxPointsPerRing points.
        return (start..<end).map { GeoPoint(Double(lats[$0]) / Self.unitsPerDegree, Double(lons[$0]) / Self.unitsPerDegree) }
    }

    /// Reads `bbox · ringCount · rings` (the `CTRY` and `URBN` encoding) from `reader`.
    static func read(from reader: inout AtlasByteReader) throws -> AtlasPolygon {
        let box = (try reader.i32(), try reader.i32(), try reader.i32(), try reader.i32())
        guard box.0 <= box.2, box.1 <= box.3, box.0.magnitude <= 18_000_000, box.2.magnitude <= 18_000_000,
              box.1.magnitude <= 9_000_000, box.3.magnitude <= 9_000_000 else {
            throw WorldAtlasPackError.malformed(reader.tag, "bbox")
        }
        let ringCount = Int(try reader.u16())
        guard ringCount <= maxRings else { throw WorldAtlasPackError.malformed(reader.tag, "ringCount") }
        var lons: [Int32] = [], lats: [Int32] = [], ends: [Int] = []
        // Bounded: ringCount <= maxRings.
        for _ in 0..<ringCount {
            try readRing(from: &reader, lons: &lons, lats: &lats)
            ends.append(lons.count)
        }
        return AtlasPolygon(minLon: box.0, minLat: box.1, maxLon: box.2, maxLat: box.3, lons: lons, lats: lats,
                            ringEnds: ends)
    }

    /// Reads one ring (`u32 pointCount · first point · deltas`) onto the end of `lons` and `lats`.
    private static func readRing(from reader: inout AtlasByteReader, lons: inout [Int32], lats: inout [Int32]) throws {
        let count = Int(try reader.u32())
        // Each delta pair is at least two bytes, so a count the bytes cannot hold is refused before looping.
        guard count >= 3, count <= maxPointsPerRing, count - 1 <= reader.remaining / 2 else {
            throw WorldAtlasPackError.malformed(reader.tag, "pointCount")
        }
        var lon = Int64(try reader.i32()), lat = Int64(try reader.i32())
        // Bounded: count <= maxPointsPerRing.
        for slot in 0..<count {
            if slot > 0 {
                let east = try reader.zigzag(), north = try reader.zigzag()
                guard east.magnitude <= 36_000_000, north.magnitude <= 18_000_000 else {
                    throw WorldAtlasPackError.malformed(reader.tag, "delta")
                }
                lon += east
                lat += north
            }
            guard lon.magnitude <= 18_000_000, lat.magnitude <= 9_000_000 else {
                throw WorldAtlasPackError.malformed(reader.tag, "point")
            }
            lons.append(Int32(lon))
            lats.append(Int32(lat))
        }
    }
}
