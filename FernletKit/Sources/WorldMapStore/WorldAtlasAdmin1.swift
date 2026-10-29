import Foundation

// The pack's `ADM1` section (Docs/World-Atlas-Pack.md): Natural Earth's states and provinces, for the world
// view's State and City zooms (World-Exploration-Spec, "The world view", answer 13): their lines, and the
// plate's place ("Oregon · United States"). No county data, ever.

/// A state or province from the pack's `ADM1` section.
public nonisolated struct AtlasAdmin1: Hashable, Sendable {
    /// The frozen token: its ISO 3166-2 code ("US-OR"), else "ne:<Natural Earth id>".
    public let token: String
    /// The ISO 3166-1 alpha-2 code of the `CTRY` country it belongs to (the screen localises the country's
    /// name from it).
    public let countryCode: String
    /// Its English name and its Spanish one (empty: use English); data, not catalog strings.
    public let names: AtlasCityNames
    /// Its outline, for the point test and for the screen to draw the state and province lines.
    public let polygon: AtlasPolygon

    /// An entry with every field given.
    public init(token: String, countryCode: String, names: AtlasCityNames, polygon: AtlasPolygon) {
        self.token = token
        self.countryCode = countryCode
        self.names = names
        self.polygon = polygon
    }

    /// The most bytes a token may have.
    public static let maxTokenBytes = 24

    /// Whether `token` has an admin-1 token's shape: an ISO 3166-2 code (two capital letters, a hyphen,
    /// one to three capitals or digits) or "ne:" and one to 12 digits.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count <= maxTokenBytes else { return false }
        let isUpper: (UInt8) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
        let isDigit: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
        if bytes.count >= 4, bytes.count <= 6, isUpper(bytes[0]), isUpper(bytes[1]), bytes[2] == 0x2D {
            return bytes[3...].allSatisfy { isUpper($0) || isDigit($0) }
        }
        let prefix = Array("ne:".utf8)
        guard bytes.count > prefix.count, bytes.count <= prefix.count + 12,
              Array(bytes[0..<prefix.count]) == prefix else { return false }
        return bytes[prefix.count...].allSatisfy(isDigit)
    }
}

/// Where a point is, for the world view's plate and its VoiceOver words: the state or province and the
/// country. The screen formats it ("Oregon · United States"), naming the country from ``countryCode``.
public nonisolated struct AtlasPlaceName: Hashable, Sendable {
    /// The country's alpha-2 code.
    public let countryCode: String
    /// The state or province's frozen token, or nil where the pack has none under the point.
    public let admin1Token: String?
    /// The state or province's names (English, Spanish), or nil with ``admin1Token``.
    public let admin1Names: AtlasCityNames?

    /// A place with every field given.
    public init(countryCode: String, admin1Token: String? = nil, admin1Names: AtlasCityNames? = nil) {
        self.countryCode = countryCode
        self.admin1Token = admin1Token
        self.admin1Names = admin1Names
    }
}

extension WorldAtlasLayers {
    /// The most states and provinces (Natural Earth's admin-1 layer has about 4,600 features).
    static let maxAdmin1s = 8_192

    /// `ADM1`: each entry's token, country, names and outline. Refuses a count over ``maxAdmin1s``, a token
    /// of the wrong shape or used twice, a country `CTRY` does not have, an empty English name, and any
    /// malformed outline.
    static func admin1s(_ bytes: [UInt8], countryCodes: Set<String>) throws -> [AtlasAdmin1] {
        var reader = AtlasByteReader(bytes, tag: "ADM1")
        let count = Int(try reader.u16())
        guard count <= maxAdmin1s else { throw WorldAtlasPackError.malformed("ADM1", "count") }
        var entries: [AtlasAdmin1] = []
        var tokens = Set<String>()
        // Bounded: count <= maxAdmin1s.
        for _ in 0..<count {
            let token = try reader.shortString(field: "token")
            guard AtlasAdmin1.isValidToken(token), tokens.insert(token).inserted else {
                throw WorldAtlasPackError.malformed("ADM1", "token")
            }
            let country = try reader.ascii(2, field: "country")
            guard countryCodes.contains(country) else { throw WorldAtlasPackError.malformed("ADM1", "country") }
            let english = try reader.shortString(field: "name"), spanish = try reader.shortString(field: "name")
            guard !english.isEmpty else { throw WorldAtlasPackError.malformed("ADM1", "name") }
            let polygon = try AtlasPolygon.read(from: &reader)
            entries.append(AtlasAdmin1(token: token, countryCode: country,
                                       names: AtlasCityNames(english: english, spanish: spanish), polygon: polygon))
        }
        try reader.expectEnd()
        return entries
    }
}

/// The admin-1 lookups. Bounded: a fix tests only its country's own entries (the United States has 51) when
/// the country under it is known, else one pass over the decoded table (at most
/// `WorldAtlasLayers.maxAdmin1s`); each entry's box is tested before its rings.
extension WorldAtlas {
    /// The state or province whose frozen token is `token`, or nil. A dictionary lookup.
    public func admin1(token: String) -> AtlasAdmin1? {
        guard let index = admin1Index[token], admin1s.indices.contains(index) else { return nil }
        return admin1s[index]
    }

    /// The states and provinces of country `code`, in table order (empty for a code the pack has none for).
    public func admin1s(ofCountry code: String) -> [AtlasAdmin1] {
        (admin1sByCountry[code] ?? []).compactMap { admin1s.indices.contains($0) ? admin1s[$0] : nil }
    }

    /// The state or province under `point`: only the entries of the country under it when the pack has one
    /// there, else every entry. Nil when no entry's rings hold it (at sea, or in the sliver where the
    /// simplified state lines and the country's outline differ).
    public func admin1(at point: GeoPoint) -> AtlasAdmin1? {
        admin1(at: point, inCountry: country(at: point)?.code)
    }

    /// The state or province under `point`, among `countryCode`'s entries when it is given, else among all.
    public func admin1(at point: GeoPoint, inCountry countryCode: String?) -> AtlasAdmin1? {
        guard point.isValid else { return nil }
        guard let countryCode else { return admin1s.first { $0.polygon.contains(point) } }
        for index in admin1sByCountry[countryCode] ?? [] where admin1s.indices.contains(index) {
            if admin1s[index].polygon.contains(point) { return admin1s[index] }
        }
        return nil
    }

    /// The plate's place at `point`: the state or province and its country, or just the country where no
    /// state holds the point, or nil where neither does (at sea).
    public func placeName(at point: GeoPoint) -> AtlasPlaceName? {
        guard point.isValid else { return nil }
        let country = country(at: point)?.code
        if let admin1 = admin1(at: point, inCountry: country) {
            return AtlasPlaceName(countryCode: admin1.countryCode, admin1Token: admin1.token, admin1Names: admin1.names)
        }
        return country.map { AtlasPlaceName(countryCode: $0) }
    }

    /// The states and provinces whose boxes touch `viewport`, for the screen to draw their lines. One pass
    /// over the table.
    public func admin1s(overlapping viewport: MapViewport) -> [AtlasAdmin1] {
        guard let box = AtlasGeoBox(viewport: viewport) else { return [] }
        return admin1s.filter { box.overlaps($0.polygon) }
    }

    /// The countries whose boxes touch `viewport`, for the screen to draw the country lines. One pass over
    /// the table.
    public func countries(overlapping viewport: MapViewport) -> [AtlasCountry] {
        guard let box = AtlasGeoBox(viewport: viewport) else { return [] }
        return countries.filter { box.overlaps($0.polygon) }
    }
}

/// A viewport as a latitude and longitude box, in the pack's 1e-5-degree units, for the line accessors'
/// box test. A viewport that wraps past the antimeridian (Mercator `x` outside 0...1) is tested shifted a
/// whole turn either way; one a whole turn wide or more touches every longitude.
nonisolated struct AtlasGeoBox: Sendable {
    /// West and east edges, unwrapped (east may pass 180°).
    let west: Double, east: Double
    /// South and north edges.
    let south: Double, north: Double

    /// The box `viewport` shows, or nil for an unusable viewport.
    init?(viewport: MapViewport) {
        guard viewport.isUsable, viewport.width < 8, viewport.height < 8, abs(viewport.minX) < 8,
              abs(viewport.minY) < 8 else { return nil }
        let scale = AtlasPolygon.unitsPerDegree
        let fullTurn = viewport.width >= 1
        west = fullTurn ? -180 * scale : (viewport.minX * 360 - 180) * scale
        east = fullTurn ? 180 * scale : ((viewport.minX + viewport.width) * 360 - 180) * scale
        north = WebMercator.geo(x: 0, y: viewport.minY).latitude * scale
        south = WebMercator.geo(x: 0, y: viewport.minY + viewport.height).latitude * scale
    }

    /// Whether `polygon`'s box touches this one, trying the box a turn east and west too.
    func overlaps(_ polygon: AtlasPolygon) -> Bool {
        guard Double(polygon.maxLat) >= south, Double(polygon.minLat) <= north else { return false }
        let turn = 360 * AtlasPolygon.unitsPerDegree
        return [-turn, 0, turn].contains { shift in
            Double(polygon.maxLon) + shift >= west && Double(polygon.minLon) + shift <= east
        }
    }
}
