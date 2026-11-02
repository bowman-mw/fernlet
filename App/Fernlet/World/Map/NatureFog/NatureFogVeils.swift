import Foundation
import WorldMapStore

/// The grounds of the airports the person has found, drawn as translucent fog (owner 2026-11-02, replacing
/// World-Airports-Spec §3's "its whole grounds uncover"): the map shows through, and the cells actually walked
/// stay fully clear, so the person's own path still reads. So do the runways, so the real ones show on the map.
///
/// Kept as shapes, not cells: a large airport is tens of thousands of hexes, too many to hold in a set for each
/// one found. Never written into the fog, so a veil counts towards no uncovered share and goes when its airport
/// leaves the passport. Two values with the same airports are equal, whatever order they were given in.
///
/// **Bounded** (Power of 10): at most ``maxShapes`` airports, each in at most ``maxBuckets`` buckets. A shape
/// reaching across more than that (a ring crossing 180°) is left out rather than laid over half the world.
nonisolated struct NatureFogVeils: Equatable, Sendable {
    /// One airport's grounds in Mercator units.
    private struct Shape: Sendable {
        let token: String
        /// The ring's corners; empty for a circle.
        let ring: [(x: Double, y: Double)]
        let middle: (x: Double, y: Double)
        /// The circle's radius in Mercator units; 0 for a ring.
        let radius: Double
        let minX: Double, maxX: Double, minY: Double, maxY: Double
        /// The runways, cleared of the veil: their ends and how far either side a hex centre counts as on one.
        var runways: [(a: (x: Double, y: Double), b: (x: Double, y: Double), reach: Double)] = []

        /// Whether (`x`, `y`) is on a runway.
        func isOnRunway(x: Double, y: Double) -> Bool {
            // Bounded: at most WorldAirports.maxRunways.
            runways.contains { runway in
                let dx = runway.b.x - runway.a.x, dy = runway.b.y - runway.a.y
                let along = dx * dx + dy * dy
                guard along > 0 else { return false }
                let share = min(1, max(0, ((x - runway.a.x) * dx + (y - runway.a.y) * dy) / along))
                let offX = x - (runway.a.x + dx * share), offY = y - (runway.a.y + dy * share)
                return (offX * offX + offY * offY).squareRoot() <= runway.reach
            }
        }

        /// Whether the Mercator position (`x`, `y`) is inside (even-odd along the ring).
        func contains(x: Double, y: Double) -> Bool {
            guard x >= minX, x <= maxX, y >= minY, y <= maxY else { return false }
            guard !ring.isEmpty else {
                let dx = x - middle.x, dy = y - middle.y
                return (dx * dx + dy * dy).squareRoot() <= radius
            }
            var inside = false
            var previous = ring[ring.count - 1]
            // Bounded: a ring holds at most WorldAirports.maxRingPoints corners.
            for corner in ring {
                if (corner.y > y) != (previous.y > y),
                   corner.x + (y - corner.y) * (previous.x - corner.x) / (previous.y - corner.y) > x {
                    inside.toggle()
                }
                previous = corner
            }
            return inside
        }
    }

    /// The most airports veiled at once.
    static let maxShapes = 2_048
    /// The most index buckets one airport may reach.
    static let maxBuckets = 36
    /// The index's buckets per Mercator unit: about 20 km on the ground at the equator.
    private static let bucketsPerUnit = 2_048.0

    /// No airports.
    static let none = NatureFogVeils(airports: [])

    private let shapes: [Shape]
    /// Which shapes reach each bucket, so a hex far from every airport costs one lookup however many are found.
    private let buckets: [Int64: [Int]]

    /// The veils over `airports`' grounds.
    init(airports: [WorldAirport]) {
        var kept: [Shape] = []
        var index: [Int64: [Int]] = [:]
        for airport in airports.sorted(by: { $0.token < $1.token }).prefix(Self.maxShapes) {
            let shape = Self.shape(of: airport)
            guard let keys = Self.keys(of: shape) else { continue }
            for key in keys { index[key, default: []].append(kept.count) }
            kept.append(shape)
        }
        shapes = kept
        buckets = index
    }

    /// Whether any airport is veiled.
    var isEmpty: Bool { shapes.isEmpty }

    /// Whether `cell`'s centre is inside a veiled airport's grounds.
    func covers(_ cell: HexCell) -> Bool {
        guard !shapes.isEmpty else { return false }
        let centre = MercatorHexGrid.centre(of: cell)
        guard let reaching = buckets[Self.key(x: centre.x, y: centre.y)] else { return false }
        return reaching.contains { shapes[$0].contains(x: centre.x, y: centre.y) }
    }

    /// Whether `cell` draws translucent fog: inside a veiled airport's grounds and off its runways, which stay clear
    /// (owner 2026-11-02). A hex the runway's middle line crosses counts as on it, so the strip has no gaps.
    func thins(_ cell: HexCell) -> Bool {
        guard !shapes.isEmpty else { return false }
        let centre = MercatorHexGrid.centre(of: cell)
        guard let reaching = buckets[Self.key(x: centre.x, y: centre.y)] else { return false }
        return reaching.contains {
            shapes[$0].contains(x: centre.x, y: centre.y) && !shapes[$0].isOnRunway(x: centre.x, y: centre.y)
        }
    }

    /// Whether this holds every airport `other` holds (false: moving from `other` fogs ground again).
    func holds(everyAirportIn other: NatureFogVeils) -> Bool {
        Set(other.shapes.map(\.token)).isSubset(of: shapes.map(\.token))
    }

    static func == (lhs: NatureFogVeils, rhs: NatureFogVeils) -> Bool {
        lhs.shapes.map(\.token) == rhs.shapes.map(\.token)
    }

    private static func shape(of airport: WorldAirport) -> Shape {
        let middle = WebMercator.unit(airport.point)
        let perMetre = WebMercator.unitsPerMetre(at: airport.point.latitude)
        let runways = airport.runways.prefix(WorldAirports.maxRunways).map { runway in
            (a: WebMercator.unit(runway.start), b: WebMercator.unit(runway.end),
             reach: max(runway.widthMetres / 2 * perMetre, MercatorHexGrid.radius))
        }
        switch airport.grounds {
        case .circle(let metres):
            let radius = metres * perMetre
            return Shape(token: airport.token, ring: [], middle: middle, radius: radius, minX: middle.x - radius,
                         maxX: middle.x + radius, minY: middle.y - radius, maxY: middle.y + radius, runways: runways)
        case .runways(let points), .outline(let points):
            let ring = points.prefix(WorldAirports.maxRingPoints).map { WebMercator.unit($0) }
            let xs = ring.map(\.x), ys = ring.map(\.y)
            return Shape(token: airport.token, ring: ring, middle: middle, radius: 0, minX: xs.min() ?? middle.x,
                         maxX: xs.max() ?? middle.x, minY: ys.min() ?? middle.y, maxY: ys.max() ?? middle.y,
                         runways: runways)
        }
    }

    /// The buckets `shape`'s box reaches; nil over ``maxBuckets``.
    private static func keys(of shape: Shape) -> [Int64]? {
        let low = cell(x: shape.minX, y: shape.minY), high = cell(x: shape.maxX, y: shape.maxY)
        let columns = high.column - low.column + 1, rows = high.row - low.row + 1
        guard columns > 0, rows > 0, columns * rows <= maxBuckets else { return nil }
        var keys: [Int64] = []
        for column in low.column...high.column {
            for row in low.row...high.row { keys.append(key(column: column, row: row)) }
        }
        return keys
    }

    private static func cell(x: Double, y: Double) -> (column: Int64, row: Int64) {
        (Int64((x * bucketsPerUnit).rounded(.down)), Int64((y * bucketsPerUnit).rounded(.down)))
    }

    private static func key(column: Int64, row: Int64) -> Int64 { column << 32 ^ row }

    private static func key(x: Double, y: Double) -> Int64 {
        let at = cell(x: x, y: y)
        return key(column: at.column, row: at.row)
    }
}
