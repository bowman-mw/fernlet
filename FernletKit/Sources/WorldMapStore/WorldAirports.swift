import Foundation

/// How big an airport is in OurAirports' list (World-Airports-Spec §3): a large one with an approved outline
/// is found by ten minutes inside it, a medium one only by a ticket or a landing.
public nonisolated enum WorldAirportSize: UInt8, Sendable {
    case large = 1
    case medium = 2
}

/// An airport's grounds (spec §2): our own approved outline, the outline of its runways widened about 500 m,
/// or a 1.5 km circle where the list has no runway ends.
public nonisolated enum WorldAirportGrounds: Equatable, Sendable {
    case circle(radiusMetres: Double)
    case runways([GeoPoint])
    case outline([GeoPoint])

    /// Whether the outline is ours and approved (only then do ten minutes inside find a large airport).
    public var isOurOutline: Bool {
        if case .outline = self { return true }
        return false
    }
}

/// One unlockable airport (every large and medium airport in OurAirports, spec §1.1).
public nonisolated struct WorldAirport: Equatable, Identifiable, Sendable {
    /// The frozen passport token (`AtlasDiscoveryKind` "airport"): its IATA code when it was first frozen,
    /// else its ident. A later data update never changes it.
    public let token: String
    /// Its IATA code, or nil where it has none.
    public let iata: String?
    /// OurAirports' ident (the ICAO code where there is one), shown where there's no IATA code.
    public let ident: String
    /// The airport's reference point.
    public let point: GeoPoint
    /// Its ISO 3166-1 alpha-2 country.
    public let countryCode: String
    public let size: WorldAirportSize
    /// Its IANA time zone (the zone flight times without a zone are read in, spec §9.2).
    public let timeZoneIdentifier: String
    /// The everyday English name ("Portland International", "Heathrow").
    public let englishName: String
    /// The Spanish name, or nil where it's the English one.
    public let spanishName: String?
    /// The city it serves, in English ("Portland").
    public let englishCity: String
    /// The city in Spanish, or nil where it's the English one.
    public let spanishCity: String?
    public let grounds: WorldAirportGrounds

    public var id: String { token }
    /// The code shown on plates and stubs: IATA, else the ident.
    public var code: String { iata ?? ident }

    /// The name in Spanish or English.
    public func name(spanish: Bool) -> String {
        spanish ? (spanishName ?? englishName) : englishName
    }

    /// The city in Spanish or English.
    public func city(spanish: Bool) -> String {
        spanish ? (spanishCity ?? englishCity) : englishCity
    }

    /// Whether `point` is inside the airport's grounds.
    public func contains(_ point: GeoPoint) -> Bool {
        switch grounds {
        case .circle(let radius):
            return point.distance(to: self.point) <= radius
        case .runways(let ring), .outline(let ring):
            return WorldAirports.ring(ring, contains: point, around: self.point)
        }
    }
}

/// An IATA-coded airport as a point only (spec §1.1): every one of them, so any imported flight can draw.
public nonisolated struct WorldAirportPoint: Equatable, Sendable {
    public let iata: String
    public let point: GeoPoint
    public let timeZoneIdentifier: String
    /// Whether it's also an unlockable (``WorldAirports/airport(code:)`` finds it).
    public let isUnlockable: Bool
}

/// One airline in the hand-made table (spec §9.3), used only to compare two records of one flight in memory.
public nonisolated struct WorldAirline: Equatable, Sendable {
    public let icao: String
    public let iata: String
    /// The names an event or an export may use; the first is the everyday one.
    public let names: [String]
}

/// The bundled `WorldAirports.pack`, opened (Docs/World-Airports-Pack.md: `FAP1`, version 1, the atlas's
/// section layout with its own magic). It refuses, throwing ``WorldAtlasPackError`` and never trapping, a file
/// over ``maxPackBytes``, a bad header or table, a section out of bounds or of the wrong length, a missing
/// required section, and any field the format doesn't allow.
public nonisolated struct WorldAirports: Sendable {
    /// The file's first four bytes.
    public static let magic: [UInt8] = Array("FAP1".utf8)
    /// The one format version this reader knows.
    public static let version: UInt16 = 1
    /// The whole file's cap (the generator refuses more).
    public static let maxPackBytes = 1_048_576
    /// One section's inflated cap.
    public static let maxRawSectionBytes = 4_194_304
    /// The most sections a table may list.
    public static let maxSections = 8
    /// The most airports either list may hold (the shipped pack has 5,280 unlockables and 9,052 points).
    public static let maxAirports = 20_000
    /// The most points one ring of grounds may have.
    public static let maxRingPoints = 64
    /// The sections every pack must carry (`META`, the generator's provenance, is optional).
    public static let requiredTags = ["TZNS", "APTS", "PNTS", "AIRL"]
    /// The shipped `WorldAirports.pack`'s SHA-256 (generated 2026-10-31 by
    /// `Scripts/world-atlas/build_world_airports.py`). Regenerating the pack changes it on purpose.
    public static let expectedSHA256 = "5a0c37862375648fd13d4b3802713c9b99744b5dc677073855dcaf60a440ace5"
    /// Degrees per grid cell of the grounds index.
    static let indexCellDegrees = 1.0

    /// Every unlockable, sorted by token.
    public let airports: [WorldAirport]
    /// Every IATA point, sorted by code.
    public let points: [WorldAirportPoint]
    /// The airline table.
    public let airlines: [WorldAirline]
    private let byToken: [String: Int]
    private let byCode: [String: Int]
    private let byIATA: [String: Int]
    /// Unlockable indexes by the 1° cells their grounds touch.
    private let cells: [Int: [Int]]

    /// Opens `data`, or throws why it's refused.
    public init(data: Data) throws {
        guard data.count <= Self.maxPackBytes else { throw WorldAtlasPackError.tooLarge }
        let sections = try Self.sections(of: [UInt8](data))
        let zones = try Self.zones(sections["TZNS"] ?? [])
        airports = try Self.airports(sections["APTS"] ?? [], zones: zones)
        points = try Self.points(sections["PNTS"] ?? [], zones: zones, unlockables: airports.count)
        airlines = try Self.airlines(sections["AIRL"] ?? [])
        var byToken: [String: Int] = [:], byCode: [String: Int] = [:], byIATA: [String: Int] = [:]
        var cells: [Int: [Int]] = [:]
        // Bounded: at most maxAirports airports and maxAirports points.
        for (index, airport) in airports.enumerated() {
            guard byToken[airport.token] == nil else { throw WorldAtlasPackError.malformed("APTS", "token") }
            byToken[airport.token] = index
            byCode[airport.code] = byCode[airport.code] ?? index
            byCode[airport.ident] = byCode[airport.ident] ?? index
            for cell in Self.cellKeys(around: airport) { cells[cell, default: []].append(index) }
        }
        for (index, point) in points.enumerated() {
            guard byIATA[point.iata] == nil else { throw WorldAtlasPackError.malformed("PNTS", "code") }
            byIATA[point.iata] = index
        }
        self.byToken = byToken
        self.byCode = byCode
        self.byIATA = byIATA
        self.cells = cells
    }

    /// The unlockable with this frozen token.
    public func airport(token: String) -> WorldAirport? {
        byToken[token].map { airports[$0] }
    }

    /// The unlockable with this IATA code or ident.
    public func airport(code: String) -> WorldAirport? {
        byCode[code.uppercased()].map { airports[$0] }
    }

    /// The IATA point with this code (any airport an imported flight may name).
    public func point(iata: String) -> WorldAirportPoint? {
        byIATA[iata.uppercased()].map { points[$0] }
    }

    /// The time zone of the airport with this IATA code, or nil for a code not in the list.
    public func timeZone(iata: String) -> TimeZone? {
        point(iata: iata).flatMap { TimeZone(identifier: $0.timeZoneIdentifier) }
    }

    /// Every unlockable whose grounds hold `point` (two only where grounds touch).
    public func airports(containing point: GeoPoint) -> [WorldAirport] {
        guard point.isValid else { return [] }
        let key = Self.cellKey(latitude: point.latitude, longitude: point.longitude)
        return (cells[key] ?? []).map { airports[$0] }.filter { $0.contains(point) }
    }

    /// The airline an event or export names by ICAO code, IATA code or name (case and accents ignored).
    public func airline(named text: String) -> WorldAirline? {
        let wanted = Self.folded(text)
        guard !wanted.isEmpty else { return nil }
        return airlines.first { airline in
            Self.folded(airline.icao) == wanted || Self.folded(airline.iata) == wanted
                || airline.names.contains { Self.folded($0) == wanted }
        }
    }

    // MARK: - Geometry

    /// Even-odd test of `point` against the closed `ring`, in metres around `origin` (airports are a few km
    /// across, so a flat local projection is exact enough).
    static func ring(_ ring: [GeoPoint], contains point: GeoPoint, around origin: GeoPoint) -> Bool {
        let p = point.metres(from: origin)
        var inside = false
        var previous = ring.last.map { $0.metres(from: origin) }
        // Bounded: at most maxRingPoints edges.
        for vertex in ring {
            let current = vertex.metres(from: origin)
            if let last = previous, (current.north > p.north) != (last.north > p.north) {
                let crossing = current.east + (p.north - current.north) * (last.east - current.east)
                    / (last.north - current.north)
                if crossing > p.east { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func cellKey(latitude: Double, longitude: Double) -> Int {
        let row = Int(((latitude + 90) / indexCellDegrees).rounded(.down))
        let col = Int(((longitude + 180) / indexCellDegrees).rounded(.down)) % 360
        return row * 1_000 + col
    }

    /// The 1° cells an airport's grounds touch: every cell its bounding box covers (grounds are under 20 km
    /// across, so at most a few cells; a box crossing 180° is split).
    private static func cellKeys(around airport: WorldAirport) -> [Int] {
        var south = airport.point.latitude, north = south, west = airport.point.longitude, east = west
        switch airport.grounds {
        case .circle(let radius):
            let dLat = radius / GeoPoint.metresPerDegree
            let dLon = radius / max(1, airport.point.metresPerDegreeLongitude)
            south -= dLat; north += dLat; west -= dLon; east += dLon
        case .runways(let ring), .outline(let ring):
            for vertex in ring {
                south = min(south, vertex.latitude); north = max(north, vertex.latitude)
                west = min(west, vertex.longitude); east = max(east, vertex.longitude)
            }
        }
        var keys: Set<Int> = []
        let rows = Int(((min(89.999, north) + 90) / indexCellDegrees)) - Int(((max(-90, south) + 90) / indexCellDegrees))
        let cols = Int(((east + 180) / indexCellDegrees).rounded(.down)) - Int(((west + 180) / indexCellDegrees).rounded(.down))
        // Bounded: grounds are a few km across, so rows and cols are 0 to 2 (capped at 4 either way).
        for row in 0...min(4, max(0, rows)) {
            for col in 0...min(4, max(0, cols)) {
                let lat = max(-90, south) + Double(row) * indexCellDegrees
                var lon = west + Double(col) * indexCellDegrees
                if lon >= 180 { lon -= 360 } else if lon < -180 { lon += 360 }
                keys.insert(cellKey(latitude: min(89.999, lat), longitude: lon))
            }
        }
        keys.insert(cellKey(latitude: min(89.999, north), longitude: east >= 180 ? east - 360 : east))
        keys.insert(cellKey(latitude: max(-90, south), longitude: west < -180 ? west + 360 : west))
        return keys.sorted()
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en"))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Reading

    private static func sections(of bytes: [UInt8]) throws -> [String: [UInt8]] {
        guard bytes.count >= 8 else { throw WorldAtlasPackError.badTable }
        guard Array(bytes[0..<4]) == magic else { throw WorldAtlasPackError.badMagic }
        var head = AtlasByteReader(Array(bytes[4..<8]), tag: "HEAD")
        guard try head.u16() == version else { throw WorldAtlasPackError.badVersion }
        let count = Int(try head.u16())
        guard count >= 1, count <= maxSections, bytes.count >= 8 + count * 16 else {
            throw WorldAtlasPackError.badTable
        }
        var sections: [String: [UInt8]] = [:]
        // Bounded: count <= maxSections.
        for slot in 0..<count {
            var row = AtlasByteReader(Array(bytes[(8 + slot * 16)..<(24 + slot * 16)]), tag: "TABL")
            guard let tag = String(bytes: try row.bytes(4), encoding: .ascii), tag.count == 4 else {
                throw WorldAtlasPackError.badTable
            }
            let offset = Int(try row.u32()), stored = Int(try row.u32()), raw = Int(try row.u32())
            guard sections[tag] == nil else { throw WorldAtlasPackError.duplicateSection(tag) }
            guard offset >= 8, stored > 0, offset <= bytes.count, stored <= bytes.count - offset else {
                throw WorldAtlasPackError.sectionOutOfBounds(tag)
            }
            guard raw > 0, raw <= maxRawSectionBytes else { throw WorldAtlasPackError.sectionTooLarge(tag) }
            guard let body = WorldAtlasInflate.inflate(Data(bytes[offset..<(offset + stored)]), rawLength: raw) else {
                throw WorldAtlasPackError.wrongRawLength(tag)
            }
            sections[tag] = body
        }
        for tag in requiredTags where sections[tag] == nil { throw WorldAtlasPackError.missingSection(tag) }
        return sections
    }

    private static func zones(_ body: [UInt8]) throws -> [String] {
        var reader = AtlasByteReader(body, tag: "TZNS")
        let count = Int(try reader.u16())
        var zones: [String] = []
        // Bounded: count <= UInt16.max.
        for _ in 0..<count {
            let zone = try reader.shortString(field: "zone")
            guard !zone.isEmpty else { throw WorldAtlasPackError.malformed("TZNS", "zone") }
            zones.append(zone)
        }
        try reader.expectEnd()
        return zones
    }

    private static func airports(_ body: [UInt8], zones: [String]) throws -> [WorldAirport] {
        var reader = AtlasByteReader(body, tag: "APTS")
        let count = Int(try reader.u16())
        guard count <= maxAirports else { throw WorldAtlasPackError.malformed("APTS", "count") }
        var out: [WorldAirport] = []
        out.reserveCapacity(count)
        // Bounded: count <= maxAirports.
        for _ in 0..<count {
            let token = try reader.shortString(field: "token")
            let iata = try reader.shortString(field: "iata")
            let ident = try reader.shortString(field: "ident")
            guard !token.isEmpty, !ident.isEmpty, iata.isEmpty || iata.count == 3 else {
                throw WorldAtlasPackError.malformed("APTS", "code")
            }
            let point = GeoPoint(Double(try reader.i32()) / 100_000, Double(try reader.i32()) / 100_000)
            guard point.isValid else { throw WorldAtlasPackError.malformed("APTS", "point") }
            let country = try reader.ascii(2, field: "country")
            guard let size = WorldAirportSize(rawValue: try reader.u8()) else {
                throw WorldAtlasPackError.malformed("APTS", "size")
            }
            let zone = Int(try reader.u16())
            guard zone < zones.count else { throw WorldAtlasPackError.malformed("APTS", "zone") }
            let englishName = try reader.shortString(field: "name")
            let spanishName = try reader.shortString(field: "name")
            let englishCity = try reader.shortString(field: "city")
            let spanishCity = try reader.shortString(field: "city")
            let grounds: WorldAirportGrounds
            switch try reader.u8() {
            case 0: grounds = .circle(radiusMetres: Double(try reader.u16()))
            case 1: grounds = .runways(try ring(&reader))
            case 2: grounds = .outline(try ring(&reader))
            default: throw WorldAtlasPackError.malformed("APTS", "grounds")
            }
            out.append(WorldAirport(
                token: token, iata: iata.isEmpty ? nil : iata, ident: ident, point: point, countryCode: country,
                size: size, timeZoneIdentifier: zones[zone], englishName: englishName,
                spanishName: spanishName.isEmpty ? nil : spanishName, englishCity: englishCity,
                spanishCity: spanishCity.isEmpty ? nil : spanishCity, grounds: grounds))
        }
        try reader.expectEnd()
        return out
    }

    /// `u32 pointCount · i32 lon · i32 lat · zigzag deltas`, the atlas's ring.
    private static func ring(_ reader: inout AtlasByteReader) throws -> [GeoPoint] {
        let count = Int(try reader.u32())
        guard count >= 4, count <= maxRingPoints else { throw WorldAtlasPackError.malformed("APTS", "ring") }
        var lon = Int64(try reader.i32()), lat = Int64(try reader.i32())
        var ring = [GeoPoint(Double(lat) / 100_000, Double(lon) / 100_000)]
        // Bounded: count <= maxRingPoints.
        for _ in 1..<count {
            lon += try reader.zigzag()
            lat += try reader.zigzag()
            let point = GeoPoint(Double(lat) / 100_000, Double(lon) / 100_000)
            guard point.isValid else { throw WorldAtlasPackError.malformed("APTS", "ring") }
            ring.append(point)
        }
        return ring
    }

    private static func points(_ body: [UInt8], zones: [String], unlockables: Int) throws -> [WorldAirportPoint] {
        var reader = AtlasByteReader(body, tag: "PNTS")
        let count = Int(try reader.u16())
        guard count <= maxAirports else { throw WorldAtlasPackError.malformed("PNTS", "count") }
        var out: [WorldAirportPoint] = []
        out.reserveCapacity(count)
        // Bounded: count <= maxAirports.
        for _ in 0..<count {
            let code = try reader.ascii(3, field: "code")
            let point = GeoPoint(Double(try reader.i32()) / 100_000, Double(try reader.i32()) / 100_000)
            let zone = Int(try reader.u16()), unlockable = Int(try reader.u16())
            guard point.isValid, zone < zones.count, unlockable == 0xFFFF || unlockable < unlockables else {
                throw WorldAtlasPackError.malformed("PNTS", "point")
            }
            out.append(WorldAirportPoint(iata: code, point: point, timeZoneIdentifier: zones[zone],
                                         isUnlockable: unlockable != 0xFFFF))
        }
        try reader.expectEnd()
        return out
    }

    private static func airlines(_ body: [UInt8]) throws -> [WorldAirline] {
        var reader = AtlasByteReader(body, tag: "AIRL")
        let count = Int(try reader.u16())
        var out: [WorldAirline] = []
        // Bounded: count <= UInt16.max.
        for _ in 0..<count {
            let icao = try reader.ascii(3, field: "icao"), iata = try reader.ascii(2, field: "iata")
            let names = try reader.shortString(field: "names").split(separator: "|").map(String.init)
            guard !names.isEmpty else { throw WorldAtlasPackError.malformed("AIRL", "names") }
            out.append(WorldAirline(icao: icao, iata: iata, names: names))
        }
        try reader.expectEnd()
        return out
    }
}
