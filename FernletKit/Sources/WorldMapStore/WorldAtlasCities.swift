import Foundation

/// The city rule (Docs/World-Atlas-Pack.md, "City"; owner's rule, 2026-10-29). Natural Earth's urban areas cut
/// a metro area into fragments that do not follow its cities (in New York one polygon holds Manhattan, another
/// the Bronx and Stamford's point, a third Brooklyn and Queens with no city point at all), so a polygon only
/// says "this is built-up"; which city it is comes from the cities' points:
///
/// - (a) inside any urban boundary, every city whose point lies within its ``cityReachMetres(for:)`` of the fix
///   is a candidate;
/// - (b) anywhere, every city whose point lies within its ``cityCoreRadiusMetres(for:)`` of the fix is one;
/// - the nearest candidate of either kind (plain distance) is the city, and no candidate means no city.
extension WorldAtlas {
    /// The longest reach of any size class (a megacity's), 35 km: how far the city index is searched.
    public static let maxCityReachMetres = 35_000.0

    /// How far a city's pull reaches across urban boundaries, by its size class (owner's rule, 2026-10-29):
    /// a town 5 km, a city 10 km, a large city 20 km, a megacity 35 km. A fix inside any urban boundary is in
    /// the nearest city whose reach holds it, whichever polygon holds that city's point.
    public static func cityReachMetres(for size: AtlasCitySize) -> Double {
        switch size {
        case .town: 5_000
        case .city: 10_000
        case .large: 20_000
        case .mega: maxCityReachMetres
        }
    }

    /// How near a city's point a fix must be to be in that city with no urban boundary under it, by its size
    /// class (Fernlet's proposal, 2026-10-29, kept by the owner's rule): a town 2 km, a city 4 km, a large city
    /// 8 km, a megacity 12 km. Natural Earth's boundaries leave gaps (Toronto's waterfront, Stanley Park,
    /// central Copenhagen), so the core is what still names the city there.
    public static func cityCoreRadiusMetres(for size: AtlasCitySize) -> Double {
        switch size {
        case .town: 2_000
        case .city: 4_000
        case .large: 8_000
        case .mega: 12_000
        }
    }

    /// The city `point` is in, by the rule above, or nil. Bounded: the city index's few cells (see
    /// `AtlasCityIndex`), then, only when the nearest city in reach lies outside its own core, one pass over
    /// the urban boundaries (decoder-capped, each box tested before its rings).
    public func city(at point: GeoPoint) -> AtlasCity? {
        guard point.isValid else { return nil }
        let nearest = nearestCities(to: point)
        guard let reached = nearest.reached else { return nil }
        // Every core is inside its own reach, so the nearest city in reach, when it is also in its core, is
        // the nearest candidate of both kinds; otherwise it counts only inside an urban boundary.
        if nearest.core == reached || isUrban(point) { return cities[reached] }
        return nearest.core.map { cities[$0] }
    }

    /// Whether `point` lies inside any urban boundary. Bounded: one pass over the boundaries (at most
    /// `WorldAtlasLayers.maxUrbanAreas`), each box tested before its rings.
    public func isUrban(_ point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        return urbanAreas.contains { $0.contains(point) }
    }

    /// The urban boundary that holds `city`'s own point (the pack's `CITY` polygon field), or nil: for the
    /// screens to draw; the city rule does not read it.
    public func urbanArea(of city: AtlasCity) -> AtlasPolygon? {
        guard let index = cityIndex[city.token], cityPolygons.indices.contains(index) else { return nil }
        let polygon = cityPolygons[index]
        return urbanAreas.indices.contains(polygon) ? urbanAreas[polygon] : nil
    }

    /// The nearest city whose reach holds `point` and the nearest whose core holds it, as indices into
    /// ``cities`` (plain flat-earth distance, the first found on a tie). Bounded: the index's candidates.
    func nearestCities(to point: GeoPoint) -> (reached: Int?, core: Int?) {
        var reached: (index: Int, metres: Double)?
        var core: (index: Int, metres: Double)?
        for index in cityGrid.candidates(near: point) where cities.indices.contains(index) {
            let city = cities[index]
            let metres = Self.separation(point, city.point)
            if metres <= Self.cityReachMetres(for: city.size), metres < (reached?.metres ?? .infinity) {
                reached = (index, metres)
            }
            if metres <= Self.cityCoreRadiusMetres(for: city.size), metres < (core?.metres ?? .infinity) {
                core = (index, metres)
            }
        }
        return (reached?.index, core?.index)
    }
}

/// The cities bucketed by one-degree cell, built once when the atlas opens, so a fix's city search reads a few
/// cells instead of every city.
///
/// A search covers every city within ``WorldAtlas/maxCityReachMetres`` (35 km) of the fix: the fix's row and the
/// rows either side (35 km is under a third of a degree of latitude), and as many columns either side as 35 km
/// spans half a degree poleward of the fix, at most ``maxColumnSpan``. Bounded: at most 3 × (2 × 8 + 1) = 51
/// cells; the buckets together hold each city once (at most `WorldAtlasLayers.maxCities`). The cap covers the
/// whole reach up to about 87°N or S; no city lies that near a pole.
nonisolated struct AtlasCityIndex: Sendable {
    /// One-degree rows, north to south from 90°N.
    static let rows = 180
    /// One-degree columns, west to east from 180°W.
    static let cols = 360
    /// The most columns searched either side of the fix's.
    static let maxColumnSpan = 8

    /// Each non-empty cell's cities, as indices into the atlas's cities, keyed `row × cols + col`.
    private let buckets: [Int: [Int]]

    /// The index of `cities`. Bounded: one pass over a decoder-capped table.
    init(cities: [AtlasCity]) {
        var buckets: [Int: [Int]] = [:]
        for (index, city) in cities.enumerated() where city.point.isValid {
            let cell = Self.cell(of: city.point)
            buckets[cell.row * Self.cols + cell.col, default: []].append(index)
        }
        self.buckets = buckets
    }

    /// The one-degree cell under `point` (latitude clamped, longitude normalised).
    static func cell(of point: GeoPoint) -> (row: Int, col: Int) {
        let row = Int(min(max(90 - point.latitude, 0), Double(rows) - 1e-9).rounded(.down))
        let longitude = AtlasGrid.normalised(point.longitude)
        let col = Int(min(max(longitude + 180, 0), Double(cols) - 1e-9).rounded(.down))
        return (min(row, rows - 1), min(col, cols - 1))
    }

    /// Every city that may lie within ``WorldAtlas/maxCityReachMetres`` of `point` (a superset: the caller
    /// measures each), each once.
    func candidates(near point: GeoPoint) -> [Int] {
        guard point.isValid else { return [] }
        let cell = Self.cell(of: point)
        let poleward = min(abs(point.latitude) + 0.5, 89.9)
        let perDegree = GeoPoint.metresPerDegree * cos(poleward * .pi / 180)
        let span = min(Self.maxColumnSpan, Int((WorldAtlas.maxCityReachMetres / perDegree).rounded(.up)))
        var found: [Int] = []
        for row in max(cell.row - 1, 0)...min(cell.row + 1, Self.rows - 1) {
            for offset in -span...span {
                let col = ((cell.col + offset) % Self.cols + Self.cols) % Self.cols
                if let bucket = buckets[row * Self.cols + col] { found.append(contentsOf: bucket) }
            }
        }
        return found
    }
}
