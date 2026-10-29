import Foundation

/// A country or territory from the pack's `CTRY` section.
public nonisolated struct AtlasCountry: Hashable, Sendable {
    /// The territory's ISO 3166-1 alpha-2 code (Natural Earth `ISO_A2_EH`), the frozen token.
    public let code: String
    /// The sovereign state's alpha-2 code (a territory counts toward it in "N of 194").
    public let sovereignCode: String
    /// The country's own continent, for display, or nil when the pack gives none.
    public let continent: AtlasContinent?
    /// Whether it is one of the passport's ``WorldAtlas/passportCountryTotal`` (the 193 UN members, the Holy See
    /// and Palestine, without North Korea: owner, 2026-10-29).
    public let countsInPassport: Bool
    /// Its outline.
    public let polygon: AtlasPolygon
}

/// The water nearest a fix within reach: an ocean or a sea, never both (owner, 2026-10-29: a sea is its own
/// passport entry, so the Caribbean counts the Caribbean Sea and not the Atlantic).
public nonisolated enum AtlasWater: Hashable, Sendable {
    /// One of the five oceans.
    case ocean(AtlasOcean)
    /// A sea from the `SEAS` table.
    case sea(AtlasSea)
}

/// Every section of a pack decoded and checked, ready for ``WorldAtlas``. Bounded: at most ``maxSeas`` seas,
/// ``maxCountries`` countries, ``maxUrbanAreas`` urban boundaries, ``maxCities`` cities and ``maxAdmin1s``
/// states and provinces (each refused beyond), every raster exactly one byte a cell, every code within its table.
nonisolated struct WorldAtlasLayers: Sendable {
    /// The most seas: `OCEA` codes 6...255.
    static let maxSeas = 250
    /// The most countries and territories (Natural Earth has about 260).
    static let maxCountries = 512
    /// The most urban boundaries (Natural Earth has about 12,000, fewer once those without a city go).
    static let maxUrbanAreas = 16_384
    /// The most cities (Natural Earth's populated places number about 7,300).
    static let maxCities = 16_384
    /// The highest Köppen-Geiger code (30, EF).
    static let maxClimateCode: UInt8 = 30
    /// The highest continent code (7, South America).
    static let maxContinentCode: UInt8 = 7

    let grid: AtlasGrid
    let land: [UInt8]
    let coastCells: [Int32]
    let coastMasks: [UInt8]
    let climate: [UInt8]
    let oceans: [UInt8]
    let continents: [UInt8]
    let seas: [AtlasSea]
    let countries: [AtlasCountry]
    let urbanAreas: [AtlasPolygon]
    let cities: [AtlasCity]
    let cityPolygons: [Int]
    let admin1s: [AtlasAdmin1]
    let admin1Groups: [AtlasAdmin1Group]
    let metaJSON: String?

    /// Every layer of `pack`, or the reason one is refused.
    init(pack: WorldAtlasPack) throws {
        let land = try Self.land(try pack.section("LAND"))
        grid = land.grid
        self.land = land.states
        coastCells = land.coastCells
        coastMasks = land.masks
        seas = try Self.seas(try pack.section("SEAS"))
        climate = try Self.raster(try pack.section("CLIM"), tag: "CLIM", grid: grid, maxCode: Self.maxClimateCode)
        let maxOcean = UInt8(5 + seas.count)
        oceans = try Self.raster(try pack.section("OCEA"), tag: "OCEA", grid: grid, maxCode: maxOcean)
        continents = try Self.raster(try pack.section("CONT"), tag: "CONT", grid: grid, maxCode: Self.maxContinentCode)
        countries = try Self.countries(try pack.section("CTRY"))
        urbanAreas = try Self.urbanAreas(try pack.section("URBN"))
        let cities = try Self.cities(try pack.section("CITY"), urbanCount: urbanAreas.count)
        self.cities = cities.map(\.city)
        cityPolygons = cities.map(\.polygon)
        let admin1 = try Self.admin1s(try pack.section("ADM1"), countryCodes: Set(countries.map(\.code)))
        admin1s = admin1.entries
        admin1Groups = admin1.groups
        metaJSON = pack.sections["META"].flatMap { String(bytes: $0, encoding: .utf8) }
    }

    /// `LAND`: the grid size, every cell's state, and the coast cells' masks (in index order).
    static func land(_ bytes: [UInt8]) throws -> (grid: AtlasGrid, states: [UInt8], coastCells: [Int32], masks: [UInt8]) {
        var reader = AtlasByteReader(bytes, tag: "LAND")
        let cols = Int(try reader.u32()), rows = Int(try reader.u32()), sub = Int(try reader.u16())
        guard let grid = AtlasGrid(rows: rows), cols == grid.cols else {
            throw WorldAtlasPackError.malformed("LAND", "gridSize")
        }
        guard sub == AtlasGrid.subdivisions else { throw WorldAtlasPackError.malformed("LAND", "sub") }
        let states = Array(try reader.bytes(grid.cellCount))
        var coast: [Int32] = []
        // Bounded: one pass over cellCount <= 2 * maxRows^2 cells.
        for (index, state) in states.enumerated() {
            guard state <= 2 else { throw WorldAtlasPackError.malformed("LAND", "state") }
            if state == 2 { coast.append(Int32(index)) }
        }
        guard Int(try reader.u32()) == coast.count else { throw WorldAtlasPackError.malformed("LAND", "coastCount") }
        let masks = Array(try reader.bytes(coast.count * WorldAtlas.maskBytes))
        try reader.expectEnd()
        return (grid, states, coast, masks)
    }

    /// `CLIM`, `OCEA` or `CONT`: exactly one byte a cell, none above `maxCode`.
    static func raster(_ bytes: [UInt8], tag: String, grid: AtlasGrid, maxCode: UInt8) throws -> [UInt8] {
        guard bytes.count == grid.cellCount else { throw WorldAtlasPackError.malformed(tag, "length") }
        guard bytes.allSatisfy({ $0 <= maxCode }) else { throw WorldAtlasPackError.malformed(tag, "code") }
        return bytes
    }

    /// `SEAS`: each sea's token, parent ocean and names.
    static func seas(_ bytes: [UInt8]) throws -> [AtlasSea] {
        var reader = AtlasByteReader(bytes, tag: "SEAS")
        let count = Int(try reader.u16())
        guard count <= maxSeas else { throw WorldAtlasPackError.malformed("SEAS", "count") }
        var seas: [AtlasSea] = []
        // Bounded: count <= maxSeas.
        for _ in 0..<count {
            let token = try reader.shortString(field: "token")
            guard !token.isEmpty else { throw WorldAtlasPackError.malformed("SEAS", "token") }
            guard let parent = AtlasOcean(packCode: try reader.u8()) else {
                throw WorldAtlasPackError.malformed("SEAS", "parentOcean")
            }
            seas.append(AtlasSea(token: token, parentOcean: parent, names: try names(from: &reader)))
        }
        try reader.expectEnd()
        return seas
    }

    /// `CTRY`: each country's codes, continent, flags and outline.
    static func countries(_ bytes: [UInt8]) throws -> [AtlasCountry] {
        var reader = AtlasByteReader(bytes, tag: "CTRY")
        let count = Int(try reader.u16())
        guard count <= maxCountries else { throw WorldAtlasPackError.malformed("CTRY", "count") }
        var countries: [AtlasCountry] = []
        // Bounded: count <= maxCountries.
        for _ in 0..<count {
            let code = try reader.ascii(2, field: "code"), sovereign = try reader.ascii(2, field: "sovereign")
            let continentCode = try reader.u8(), flags = try reader.u8()
            guard continentCode <= maxContinentCode else { throw WorldAtlasPackError.malformed("CTRY", "continent") }
            let polygon = try AtlasPolygon.read(from: &reader)
            countries.append(AtlasCountry(code: code, sovereignCode: sovereign,
                                          continent: AtlasContinent(packCode: continentCode),
                                          countsInPassport: flags & 1 == 1, polygon: polygon))
        }
        try reader.expectEnd()
        return countries
    }

    /// `URBN`: the urban boundaries.
    static func urbanAreas(_ bytes: [UInt8]) throws -> [AtlasPolygon] {
        var reader = AtlasByteReader(bytes, tag: "URBN")
        let count = Int(try reader.u32())
        guard count <= maxUrbanAreas else { throw WorldAtlasPackError.malformed("URBN", "count") }
        var areas: [AtlasPolygon] = []
        // Bounded: count <= maxUrbanAreas.
        for _ in 0..<count {
            areas.append(try AtlasPolygon.read(from: &reader))
        }
        try reader.expectEnd()
        return areas
    }

    /// `CITY`: each city and the urban boundary it sits in (-1 for none).
    static func cities(_ bytes: [UInt8], urbanCount: Int) throws -> [(city: AtlasCity, polygon: Int)] {
        var reader = AtlasByteReader(bytes, tag: "CITY")
        let count = Int(try reader.u32())
        guard count <= maxCities else { throw WorldAtlasPackError.malformed("CITY", "count") }
        var cities: [(city: AtlasCity, polygon: Int)] = []
        // Bounded: count <= maxCities.
        for _ in 0..<count {
            let token = try reader.shortString(field: "token")
            let country = try reader.ascii(2, field: "country")
            guard !token.isEmpty, let size = AtlasCitySize(packCode: try reader.u8()) else {
                throw WorldAtlasPackError.malformed("CITY", "tokenOrSize")
            }
            let population = Int(try reader.u32())
            let lon = Double(try reader.i32()) / AtlasPolygon.unitsPerDegree
            let lat = Double(try reader.i32()) / AtlasPolygon.unitsPerDegree
            let polygon = Int(try reader.i32())
            let point = GeoPoint(lat, lon)
            guard point.isValid, polygon >= -1, polygon < urbanCount else {
                throw WorldAtlasPackError.malformed("CITY", "pointOrPolygon")
            }
            let city = AtlasCity(token: token, countryCode: country, size: size, population: population, point: point,
                                 names: try names(from: &reader))
            cities.append((city, polygon))
        }
        try reader.expectEnd()
        return cities
    }

    /// Four `u8 len · bytes` names: English, Spanish, French, German.
    private static func names(from reader: inout AtlasByteReader) throws -> AtlasCityNames {
        AtlasCityNames(english: try reader.shortString(field: "name"), spanish: try reader.shortString(field: "name"),
                       french: try reader.shortString(field: "name"), german: try reader.shortString(field: "name"))
    }
}
