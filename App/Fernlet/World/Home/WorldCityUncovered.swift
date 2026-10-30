import Foundation
import WorldMapStore

/// How much of a city the person has uncovered (the city card's "3% of the city", World-Exploration-Spec §2): the
/// lifted fog cells inside the city's urban area over the cells the area holds. Pure, nonisolated and bounded, for a
/// background task; ``WorldCityUncoveredCache`` keeps each answer.
///
/// - **The area** is the atlas's urban boundary holding the city's point (`WorldAtlas.urbanArea(of:)`), measured by
///   sampling its box on a ``samplesPerSide`` grid; a city with no boundary under its point takes its core disc
///   (`WorldAtlas.cityCoreRadiusMetres(for:)`), the part of the city rule that still names it there.
/// - **The cells inside** are the lifted cells whose centres fall in the area. Cells are read in ``bucketDegrees``
///   buckets (about 100 m), each bucket's centre tested once, so a lifetime of walking costs one test per bucket.
nonisolated enum WorldCityUncovered {
    /// The grid the area's box is sampled on, per side.
    static let samplesPerSide = 48
    /// The bucket the lifted cells are tested in, in degrees.
    static let bucketDegrees = 0.001
    /// The most lifted cells read (the fog store's own cap, `FogCellStore.maxCells`).
    static let maxLifted = 250_000

    /// Where a city is: its boundary, or its core disc.
    enum Area: Sendable {
        case boundary(AtlasPolygon)
        case core(centre: GeoPoint, metres: Double)
    }

    /// The share of `area` the `lifted` cells uncover, 0…1. Bounded: at most ``maxLifted`` cells and
    /// ``samplesPerSide``² samples.
    static func share(of area: Area, lifted: Set<HexCell>) -> Double {
        let squareMetres = self.squareMetres(of: area)
        guard squareMetres > 0, !lifted.isEmpty else { return 0 }
        let latitude = centre(of: area).latitude
        let radius = MercatorHexGrid.groundRadius(at: latitude)
        let cellArea = 1.5 * 3.0.squareRoot() * radius * radius
        guard cellArea > 0 else { return 0 }
        let inside = cellsInside(area, lifted: lifted)
        return min(Double(inside) / (squareMetres / cellArea), 1)
    }

    /// How many of `lifted` lie in `area` (by bucket).
    static func cellsInside(_ area: Area, lifted: Set<HexCell>) -> Int {
        var buckets: [Int64: Bool] = [:]
        var inside = 0
        // Bounded: at most maxLifted cells, each one dictionary read or one area test.
        for cell in lifted.prefix(Self.maxLifted) {
            let point = MercatorHexGrid.centreGeo(of: cell)
            let row = Int64((point.latitude / bucketDegrees).rounded(.down))
            let col = Int64((point.longitude / bucketDegrees).rounded(.down))
            let key = row &* 1_000_000 &+ col
            if let known = buckets[key] {
                inside += known ? 1 : 0
                continue
            }
            let probe = GeoPoint((Double(row) + 0.5) * bucketDegrees, (Double(col) + 0.5) * bucketDegrees)
            let holds = contains(area, probe)
            buckets[key] = holds
            inside += holds ? 1 : 0
        }
        return inside
    }

    /// The area's size on the ground, in square metres.
    static func squareMetres(of area: Area) -> Double {
        switch area {
        case .core(_, let metres):
            return metres > 0 ? Double.pi * metres * metres : 0
        case .boundary(let polygon):
            let south = Double(polygon.minLat) / AtlasPolygon.unitsPerDegree, north = Double(polygon.maxLat) / AtlasPolygon.unitsPerDegree
            let west = Double(polygon.minLon) / AtlasPolygon.unitsPerDegree, east = Double(polygon.maxLon) / AtlasPolygon.unitsPerDegree
            guard north > south, east > west else { return 0 }
            let middle = (north + south) / 2
            let box = (north - south) * GeoPoint.metresPerDegree * (east - west) * GeoPoint.metresPerDegree * cos(middle * .pi / 180)
            return box * insideFraction(polygon, south: south, north: north, west: west, east: east)
        }
    }

    /// The fraction of the box's sample points the polygon holds.
    private static func insideFraction(_ polygon: AtlasPolygon, south: Double, north: Double, west: Double, east: Double) -> Double {
        let side = samplesPerSide
        var hits = 0
        // Bounded: samplesPerSide² samples.
        for row in 0..<side {
            for col in 0..<side {
                let latitude = south + (Double(row) + 0.5) / Double(side) * (north - south)
                let longitude = west + (Double(col) + 0.5) / Double(side) * (east - west)
                if polygon.contains(GeoPoint(latitude, longitude)) { hits += 1 }
            }
        }
        return Double(hits) / Double(side * side)
    }

    /// Whether `area` holds `point`.
    static func contains(_ area: Area, _ point: GeoPoint) -> Bool {
        switch area {
        case .boundary(let polygon): polygon.boxContains(point) && polygon.contains(point)
        case .core(let centre, let metres): centre.distance(to: point) <= metres
        }
    }

    /// The area's middle (the box's, or the disc's centre).
    static func centre(of area: Area) -> GeoPoint {
        switch area {
        case .core(let centre, _):
            return centre
        case .boundary(let polygon):
            return GeoPoint(Double(polygon.minLat + polygon.maxLat) / 2 / AtlasPolygon.unitsPerDegree,
                            Double(polygon.minLon + polygon.maxLon) / 2 / AtlasPolygon.unitsPerDegree)
        }
    }

    /// `city`'s area in `atlas`: its boundary, else its core disc.
    static func area(of city: AtlasCity, in atlas: WorldAtlas) -> Area {
        if let polygon = atlas.urbanArea(of: city) { return .boundary(polygon) }
        return .core(centre: city.point, metres: WorldAtlas.cityCoreRadiusMetres(for: city.size))
    }
}

/// Each city's uncovered share, worked out once per city and number of lifted cells, off the main actor, and kept
/// (at most ``maxCities``) for the session.
@MainActor
final class WorldCityUncoveredCache {
    /// The most cities kept.
    static let maxCities = 64

    private var shares: [String: (cells: Int, share: Double)] = [:]

    /// `city`'s uncovered share with `lifted` (from memory when the count of lifted cells is unchanged).
    func share(of city: AtlasCity, in atlas: WorldAtlas, lifted: Set<HexCell>) async -> Double {
        if let kept = shares[city.token], kept.cells == lifted.count { return kept.share }
        let area = WorldCityUncovered.area(of: city, in: atlas)
        let share = await Task.detached(priority: .utility) { WorldCityUncovered.share(of: area, lifted: lifted) }.value
        if shares.count >= Self.maxCities { shares.removeAll(keepingCapacity: true) }
        shares[city.token] = (lifted.count, share)
        return share
    }
}
