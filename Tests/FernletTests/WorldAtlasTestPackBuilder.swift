import Foundation
import WorldMapStore

/// Writes small World atlas packs in the exact Docs/World-Atlas-Pack.md format (little-endian, raw DEFLATE
/// bodies through Apple's Compression `zlib`, which is RFC 1951 with no header), for the atlas engine and
/// format tests. The grid is `rows` (18 or 36) by twice as many columns; every cell starts as water with no
/// codes.
struct WorldAtlasTestPackBuilder {
    /// A country row for `CTRY`.
    struct Country {
        /// Territory alpha-2.
        var code: String
        /// Sovereign alpha-2.
        var sovereign: String
        /// Continent code.
        var continent: UInt8 = 1
        /// Flags (bit 0: one of the 195).
        var flags: UInt8 = 1
        /// The outline.
        var feature: Feature
    }

    /// A bbox and rings, in degrees (lon, lat).
    struct Feature {
        /// minLon, minLat, maxLon, maxLat.
        var bbox: (Double, Double, Double, Double)
        /// Rings of (lon, lat) points.
        var rings: [[(Double, Double)]]

        /// A rectangle's ring, west-south to north-west.
        static func box(_ west: Double, _ south: Double, _ east: Double, _ north: Double) -> [(Double, Double)] {
            [(west, south), (east, south), (east, north), (west, north)]
        }
    }

    /// A sea row for `SEAS`.
    struct Sea {
        /// Its token.
        var token: String
        /// Parent ocean code 1–5.
        var parent: UInt8
        /// English name.
        var name: String
        /// Spanish name (empty: use English).
        var spanish: String = ""
    }

    /// A city row for `CITY`.
    struct City {
        /// Its token.
        var token: String
        /// Country alpha-2.
        var country: String
        /// Size class code 0–3.
        var size: UInt8
        /// Population.
        var population: UInt32 = 50_000
        /// Its point.
        var lat: Double
        /// Its point.
        var lon: Double
        /// Urban polygon index, -1 for none.
        var polygon: Int32 = -1
        /// English name.
        var name: String
    }

    let rows: Int
    var cols: Int { rows * 2 }
    var land: [UInt8]
    var climate: [UInt8]
    var ocean: [UInt8]
    var continent: [UInt8]
    var masks: [Int: [UInt8]] = [:]
    var seas: [Sea] = []
    var countries: [Country] = []
    var urban: [Feature] = []
    var cities: [City] = []
    var meta: String? = #"{"generator":"tests"}"#

    /// An all-water grid of `rows` rows.
    init(rows: Int = 18) {
        self.rows = rows
        let cells = rows * rows * 2
        land = Array(repeating: 0, count: cells)
        climate = Array(repeating: 0, count: cells)
        ocean = Array(repeating: 0, count: cells)
        continent = Array(repeating: 0, count: cells)
    }

    /// The flat index of the cell holding (`lat`, `lon`), by the doc's rule.
    func index(lat: Double, lon: Double) -> Int {
        let step = 180 / Double(rows)
        let row = min(max(Int(((90 - lat) / step).rounded(.down)), 0), rows - 1)
        let col = Int(((lon + 180) / step).rounded(.down)) % cols
        return row * cols + col
    }

    /// Sets the cell holding (`lat`, `lon`).
    mutating func set(lat: Double, lon: Double, state: UInt8, climate code: UInt8 = 0, ocean body: UInt8 = 0,
                      continent area: UInt8 = 0, mask: [UInt8]? = nil) {
        let cell = index(lat: lat, lon: lon)
        land[cell] = state
        climate[cell] = code
        ocean[cell] = body
        continent[cell] = area
        if let mask { masks[cell] = mask }
    }

    /// A 16 × 16 coast mask with land wherever `isLand(sx, sy)`.
    static func mask(_ isLand: (Int, Int) -> Bool) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        for sy in 0..<16 {
            for sx in 0..<16 where isLand(sx, sy) {
                let bit = sy * 16 + sx
                bytes[bit >> 3] |= UInt8(1 << (bit & 7))
            }
        }
        return bytes
    }

    // MARK: Sections

    /// Every section's raw (inflated) body, in the order the shipped pack writes them.
    func rawSections() -> [(tag: String, raw: Data)] {
        var sections: [(tag: String, raw: Data)] = [
            ("LAND", landSection()), ("CLIM", Data(climate)), ("OCEA", Data(ocean)), ("CONT", Data(continent)),
            ("SEAS", seasSection()), ("CTRY", countriesSection()), ("URBN", urbanSection()), ("CITY", citiesSection()),
        ]
        if let meta { sections.append(("META", Data(meta.utf8))) }
        return sections
    }

    /// The whole pack file.
    func build() throws -> Data {
        try Self.assemble(rawSections())
    }

    /// A pack file from raw sections: header, table, deflated bodies. `rawLengthDelta` lies about a section's
    /// `rawLength`; `magic` and `version` can be wrong on purpose.
    static func assemble(_ sections: [(tag: String, raw: Data)], magic: String = "FWA1", version: UInt16 = 1,
                         rawLengthDelta: [String: Int] = [:]) throws -> Data {
        let bodies = try sections.map { try ($0.raw as NSData).compressed(using: .zlib) as Data }
        var file = Data(magic.utf8)
        file.appendLE(version)
        file.appendLE(UInt16(sections.count))
        var offset = 8 + 16 * sections.count
        for (section, body) in zip(sections, bodies) {
            file.append(Data(section.tag.utf8))
            file.appendLE(UInt32(offset))
            file.appendLE(UInt32(body.count))
            file.appendLE(UInt32(section.raw.count + (rawLengthDelta[section.tag] ?? 0)))
            offset += body.count
        }
        for body in bodies { file.append(body) }
        return file
    }

    private func landSection() -> Data {
        var data = Data()
        data.appendLE(UInt32(cols))
        data.appendLE(UInt32(rows))
        data.appendLE(UInt16(16))
        data.append(contentsOf: land)
        let coast = land.indices.filter { land[$0] == 2 }
        data.appendLE(UInt32(coast.count))
        for cell in coast { data.append(contentsOf: masks[cell] ?? [UInt8](repeating: 0, count: 32)) }
        return data
    }

    private func seasSection() -> Data {
        var data = Data()
        data.appendLE(UInt16(seas.count))
        for sea in seas {
            data.appendShort(sea.token)
            data.append(sea.parent)
            data.appendNames(sea.name, spanish: sea.spanish)
        }
        return data
    }

    private func countriesSection() -> Data {
        var data = Data()
        data.appendLE(UInt16(countries.count))
        for country in countries {
            data.append(Data(country.code.utf8))
            data.append(Data(country.sovereign.utf8))
            data.append(country.continent)
            data.append(country.flags)
            data.appendFeature(country.feature)
        }
        return data
    }

    private func urbanSection() -> Data {
        var data = Data()
        data.appendLE(UInt32(urban.count))
        for feature in urban { data.appendFeature(feature) }
        return data
    }

    private func citiesSection() -> Data {
        var data = Data()
        data.appendLE(UInt32(cities.count))
        for city in cities {
            data.appendShort(city.token)
            data.append(Data(city.country.utf8))
            data.append(city.size)
            data.appendLE(city.population)
            data.appendLE(UInt32(bitPattern: Self.units(city.lon)))
            data.appendLE(UInt32(bitPattern: Self.units(city.lat)))
            data.appendLE(UInt32(bitPattern: city.polygon))
            data.appendNames(city.name)
        }
        return data
    }

    /// Degrees in the pack's 1e-5 units.
    static func units(_ degrees: Double) -> Int32 {
        Int32((degrees * 100_000).rounded())
    }
}

fileprivate extension Data {
    /// Appends `value` little-endian.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    /// Appends a `u8 len · bytes` string.
    mutating func appendShort(_ text: String) {
        let bytes = Array(text.utf8)
        append(UInt8(bytes.count))
        append(contentsOf: bytes)
    }

    /// Appends the four names (English, then es, fr, de; empty means "use English").
    mutating func appendNames(_ english: String, spanish: String = "") {
        appendShort(english)
        appendShort(spanish)
        appendShort("")
        appendShort("")
    }

    /// Appends a zigzag LEB128 varint.
    mutating func appendZigzag(_ value: Int64) {
        var bits = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        repeat {
            let low = UInt8(bits & 0x7F)
            bits >>= 7
            append(bits == 0 ? low : low | 0x80)
        } while bits != 0
    }

    /// Appends `bbox · ringCount · rings`.
    mutating func appendFeature(_ feature: WorldAtlasTestPackBuilder.Feature) {
        let box = feature.bbox
        for edge in [box.0, box.1, box.2, box.3] {
            appendLE(UInt32(bitPattern: WorldAtlasTestPackBuilder.units(edge)))
        }
        appendLE(UInt16(feature.rings.count))
        for ring in feature.rings {
            appendLE(UInt32(ring.count))
            var last = (lon: Int64(0), lat: Int64(0))
            for (slot, point) in ring.enumerated() {
                let now = (lon: Int64(WorldAtlasTestPackBuilder.units(point.0)),
                           lat: Int64(WorldAtlasTestPackBuilder.units(point.1)))
                if slot == 0 {
                    appendLE(UInt32(bitPattern: Int32(now.lon)))
                    appendLE(UInt32(bitPattern: Int32(now.lat)))
                } else {
                    appendZigzag(now.lon - last.lon)
                    appendZigzag(now.lat - last.lat)
                }
                last = now
            }
        }
    }
}

extension WorldAtlasTestPackBuilder {
    /// The engine tests' world, on the 18-row (10°) grid:
    /// - a tropical (Af) African land cell at 0–10°N, 0–10°E, with the Atlantic east of it, a sea (the
    ///   Caribbean's token) north of it and water no ocean names (a lake, the Caspian) west of it;
    /// - a desert coast cell at 20–30°N, 0–10°E, land in its west half, the Atlantic in its east half;
    /// - a coast cell at 20–30°N, 20–30°E, all water but one land sub-cell (sx 5, sy 3);
    /// - country AA (20–40°E, 20–40°S) with a hole (25–35°E, 25–35°S); territory BB of CC (50–60°E,
    ///   30–40°S); DD (70–80°E, 30–40°S) whose box wrongly sits at 0–1°, so the prefilter skips it;
    /// - an urban boundary (100–102°E, 10–12°N) holding cities Q1 and Q2; a loose town ne:3 at 15°N 120°E and
    ///   a loose city Q4 at 15°N 130°E.
    static func standardWorld(rows: Int = 18) -> WorldAtlasTestPackBuilder {
        var world = WorldAtlasTestPackBuilder(rows: rows)
        world.seas = [Sea(token: "Q1247", parent: 2, name: "Caribbean Sea", spanish: "Mar Caribe")]
        world.set(lat: 5, lon: 5, state: 1, climate: 1, continent: 1)
        world.set(lat: 5, lon: 15, state: 0, ocean: 2)
        world.set(lat: 15, lon: 5, state: 0, ocean: 6)
        world.set(lat: 25, lon: 5, state: 2, climate: 4, ocean: 2, continent: 1, mask: mask { sx, _ in sx < 8 })
        world.set(lat: 25, lon: 25, state: 2, climate: 4, ocean: 2, continent: 1,
                  mask: mask { sx, sy in sx == 5 && sy == 3 })
        world.countries = [
            Country(code: "AA", sovereign: "AA",
                    feature: Feature(bbox: (20, -40, 40, -20), rings: [Feature.box(20, -40, 40, -20), Feature.box(25, -35, 35, -25)])),
            Country(code: "BB", sovereign: "CC", flags: 0,
                    feature: Feature(bbox: (50, -40, 60, -30), rings: [Feature.box(50, -40, 60, -30)])),
            Country(code: "DD", sovereign: "DD",
                    feature: Feature(bbox: (0, 0, 1, 1), rings: [Feature.box(70, -40, 80, -30)])),
        ]
        world.urban = [Feature(bbox: (100, 10, 102, 12), rings: [Feature.box(100, 10, 102, 12)])]
        world.cities = [
            City(token: "Q1", country: "EE", size: 1, lat: 10.5, lon: 100.5, polygon: 0, name: "West Town"),
            City(token: "Q2", country: "EE", size: 2, lat: 11.5, lon: 101.5, polygon: 0, name: "East Town"),
            City(token: "ne:3", country: "EE", size: 0, lat: 15, lon: 120, name: "Little Town"),
            City(token: "Q4", country: "EE", size: 1, lat: 15, lon: 130, name: "Middle City"),
        ]
        return world
    }
}
