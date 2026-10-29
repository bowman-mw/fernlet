import Foundation

/// The bundled World atlas, read: what lies under an accepted fix (land or water, the climate, the
/// continent, the country, the city, the ocean or sea within reach) and the passport's visit rules
/// (Docs/World-Atlas-Pack.md, "The rules the reader applies").
///
/// Immutable once built, so one instance is shared freely across tasks. Pure lookups on bundled data: it
/// opens no connection and writes nothing (the keeper decides which fixes reach it). Every query is bounded:
/// a raster lookup is one index; the coast mask lookup a binary search of at most 64 steps; the reach search
/// at most `(2 × maxReachSpan + 1)²` cells of 256 sub-cells each; the country and city searches one pass over
/// the decoded tables, whose sizes the decoder caps.
public nonisolated final class WorldAtlas: Sendable {
    // MARK: The rules' constants (each one decided once, here)

    /// How near water must be to count its ocean or sea: 2 km (owner, 2026-10-29).
    public static let oceanReachMetres = 2_000.0
    /// The Antarctic Treaty area's edge, 60°S (owner, 2026-10-29): any accepted fix south of it counts
    /// Antarctica, on land, on ice or at sea.
    public static let antarcticaLatitude = -60.0
    /// The most cells the reach search walks either side of the fix's cell, in rows and in columns. At the
    /// shipped 0.1° grid that is about 44 km north–south, far past the 2 km reach; only poleward of about 84°,
    /// where a degree of longitude is under 12 km, is the east–west search narrower than the reach.
    public static let maxReachSpan = 4
    /// Bytes in one coast cell's 16 × 16 bit mask.
    static let maskBytes = 32

    /// How near a city with no urban boundary a fix must be to enter it, by its size class (Fernlet's
    /// proposal, 2026-10-29): a town 2 km, a city 4 km, a large city 8 km, a megacity 12 km. Natural Earth
    /// draws boundaries for nearly every large and mega city, so the bigger radii are a fallback.
    public static func townRadiusMetres(for size: AtlasCitySize) -> Double {
        switch size {
        case .town: 2_000
        case .city: 4_000
        case .large: 8_000
        case .mega: 12_000
        }
    }

    // MARK: The layers

    /// The pack's grid.
    public let grid: AtlasGrid
    /// The seas, in `SEAS` order (`OCEA` code `6 + i` is sea `i`).
    public let seas: [AtlasSea]
    /// The countries and territories.
    public let countries: [AtlasCountry]
    /// The urban boundaries.
    public let urbanAreas: [AtlasPolygon]
    /// The cities.
    public let cities: [AtlasCity]
    /// The generator's provenance JSON (`META`), when the pack carries it.
    public let metaJSON: String?
    /// Every cell's state: 0 water, 1 land, 2 coast.
    let land: [UInt8]
    /// The coast cells' indices, ascending (the masks' order).
    let coastCells: [Int32]
    /// The coast cells' masks, 32 bytes each.
    let coastMasks: [UInt8]
    /// Every cell's Köppen-Geiger code (0 none).
    let climate: [UInt8]
    /// Every cell's ocean or sea code (0 none).
    let oceans: [UInt8]
    /// Every cell's continent code (0 none).
    let continents: [UInt8]
    /// Each urban boundary's cities, as indices into ``cities``.
    let citiesByArea: [[Int]]
    /// The cities with no urban boundary, as indices into ``cities``.
    let looseCities: [Int]

    /// The atlas in `data` (a whole pack file), or the reason it is refused.
    public convenience init(data: Data) throws {
        try self.init(pack: WorldAtlasPack(data: data))
    }

    /// The atlas an opened pack holds, or the reason a section is refused.
    public init(pack: WorldAtlasPack) throws {
        let layers = try WorldAtlasLayers(pack: pack)
        grid = layers.grid
        seas = layers.seas
        countries = layers.countries
        urbanAreas = layers.urbanAreas
        cities = layers.cities
        metaJSON = layers.metaJSON
        land = layers.land
        coastCells = layers.coastCells
        coastMasks = layers.coastMasks
        climate = layers.climate
        oceans = layers.oceans
        continents = layers.continents
        var byArea = Array(repeating: [Int](), count: layers.urbanAreas.count)
        var loose: [Int] = []
        // Bounded: one pass over the cities (decoder-capped); each polygon index was checked in range.
        for (index, polygon) in layers.cityPolygons.enumerated() {
            if polygon >= 0, polygon < byArea.count { byArea[polygon].append(index) } else { loose.append(index) }
        }
        citiesByArea = byArea
        looseCities = loose
    }

    // MARK: What lies under a point

    /// Whether `point` is land (a coast cell answers from its 16 × 16 sub-mask; lakes are land).
    public func isLand(at point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        let spot = grid.spot(of: point)
        let index = grid.index(row: spot.row, col: spot.col)
        switch land[index] {
        case 1: return true
        case 2: return subCellIsLand(cell: index, sx: Self.sub(spot.fracCol), sy: Self.sub(spot.fracRow))
        default: return false
        }
    }

    /// The Köppen-Geiger code (Beck et al. 2018: 1 Af … 29 ET, 30 EF) of the cell under `point`, 0 for none.
    public func climateCode(at point: GeoPoint) -> UInt8 {
        guard point.isValid else { return 0 }
        return climate[grid.index(of: point)]
    }

    /// The continent `point` counts toward: Antarctica anywhere south of ``antarcticaLatitude``, else the
    /// `CONT` cell under a land fix, else nil (at sea).
    public func continent(at point: GeoPoint) -> AtlasContinent? {
        guard point.isValid else { return nil }
        guard point.latitude >= Self.antarcticaLatitude else { return .antarctica }
        guard isLand(at: point) else { return nil }
        return AtlasContinent(packCode: continents[grid.index(of: point)])
    }

    /// The country whose rings hold `point` (each country's box first, then the even-odd rule), or nil.
    public func country(at point: GeoPoint) -> AtlasCountry? {
        guard point.isValid else { return nil }
        // Bounded: one pass over the countries (at most WorldAtlasLayers.maxCountries).
        return countries.first { $0.polygon.contains(point) }
    }

    /// The city `point` is in: inside an urban boundary, the nearest of the cities sharing it; otherwise the
    /// nearest city with no boundary within ``townRadiusMetres(for:)`` of its point; else nil.
    public func city(at point: GeoPoint) -> AtlasCity? {
        guard point.isValid else { return nil }
        // Bounded: one pass over the urban boundaries, then over one boundary's cities or the loose ones.
        if let area = urbanAreas.firstIndex(where: { $0.contains(point) }),
           let index = nearest(of: citiesByArea[area], to: point, radius: { _ in .infinity }) {
            return cities[index]
        }
        guard let index = nearest(of: looseCities, to: point, radius: Self.townRadiusMetres(for:)) else { return nil }
        return cities[index]
    }

    /// The nearest of `candidates` to `point` that lies within its own `radius`.
    private func nearest(of candidates: [Int], to point: GeoPoint, radius: (AtlasCitySize) -> Double) -> Int? {
        guard !candidates.isEmpty else { return nil }
        var best: (index: Int, metres: Double)?
        for index in candidates where index >= 0 && index < cities.count {
            let metres = Self.separation(point, cities[index].point)
            guard metres <= radius(cities[index].size), metres < (best?.metres ?? .infinity) else { continue }
            best = (index, metres)
        }
        return best?.index
    }

    // MARK: The visit

    /// Everything one accepted fix counts toward, with every rule applied: the country under it, its
    /// continent (Antarctica's lighter rule included), the ocean or the sea within ``oceanReachMetres``
    /// (never both), its city and its terrain. An invalid point gives an empty visit over water.
    public func visit(at point: GeoPoint) -> AtlasVisit {
        let terrain = AtlasTerrainClassifier(atlas: self).terrain(at: point)
        guard point.isValid else { return AtlasVisit(terrain: terrain) }
        let country = country(at: point)
        var visit = AtlasVisit(countryCode: country?.code, sovereignCode: country?.sovereignCode,
                               continent: continent(at: point), city: city(at: point), terrain: terrain)
        switch water(near: point) {
        case .ocean(let ocean): visit.ocean = ocean
        case .sea(let sea): visit.sea = sea
        case nil: break
        }
        return visit
    }

    // MARK: Helpers

    /// A fraction of a cell (0..<1) as a sub-cell index, 0...15.
    static func sub(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return min(max(Int((fraction * Double(AtlasGrid.subdivisions)).rounded(.down)), 0), AtlasGrid.subdivisions - 1)
    }

    /// Whether sub-cell (`sx`, `sy`) of coast cell `cell` is land (bit `sy × 16 + sx`, least significant first).
    func subCellIsLand(cell: Int, sx: Int, sy: Int) -> Bool {
        guard let ordinal = coastOrdinal(of: cell), (0..<16).contains(sx), (0..<16).contains(sy) else { return false }
        let bit = sy * AtlasGrid.subdivisions + sx
        let byteIndex = ordinal * Self.maskBytes + (bit >> 3)
        guard byteIndex < coastMasks.count else { return false }
        return (coastMasks[byteIndex] >> UInt8(bit & 7)) & 1 == 1
    }

    /// Where coast cell `cell` sits among ``coastCells`` (a binary search, at most 64 steps), or nil.
    func coastOrdinal(of cell: Int) -> Int? {
        guard !coastCells.isEmpty else { return nil }
        var low = 0, high = coastCells.count - 1
        for _ in 0..<64 where low <= high {
            let middle = (low + high) / 2
            let value = Int(coastCells[middle])
            if value == cell { return middle }
            if value < cell { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// The flat-earth distance between two points in metres, the longitude difference taken the short way
    /// round (so a city across the antimeridian is measured correctly).
    static func separation(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let east = AtlasGrid.normalised(b.longitude - a.longitude) * a.metresPerDegreeLongitude
        let north = (b.latitude - a.latitude) * GeoPoint.metresPerDegree
        return (east * east + north * north).squareRoot()
    }
}

/// The bundled atlas is what the app's passport keeper reads accepted fixes against.
extension WorldAtlas: AtlasVisitResolving {}
