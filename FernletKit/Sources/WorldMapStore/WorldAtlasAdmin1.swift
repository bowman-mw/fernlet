import Foundation

// The pack's `ADM1` section (Docs/World-Atlas-Pack.md): Natural Earth's states and provinces, for the world
// view's State and City zooms (World-Exploration-Spec, "The world view", answer 13): their lines, and the
// plate's place ("Oregon · United States"). Where Natural Earth's admin-1 is a second-level unit (Britain's
// council areas, France's départements, Italy's and Spain's provinces, Ireland's counties and a few more), each
// entry also names its first-level region, its plate group ("England", "Île-de-France"), and the plate and
// the state lines use that. No county data, ever.

/// A plate group: the first-level region a state or province is shown as (England for Camden, Île-de-France
/// for Paris), or, where Natural Earth's admin-1 is already first-level, the state or province itself.
public nonisolated struct AtlasAdmin1Group: Hashable, Sendable {
    /// The frozen token: the region's ISO 3166-2 code ("GB-ENG"), else "ne:region:<country>:<slug>"; for an
    /// entry that is its own group, the entry's token.
    public let token: String
    /// The alpha-2 code of the country it is in.
    public let countryCode: String
    /// Its English name and its Spanish one (empty: use English); data, not catalog strings.
    public let names: AtlasCityNames

    /// A group with every field given.
    public init(token: String, countryCode: String, names: AtlasCityNames) {
        self.token = token
        self.countryCode = countryCode
        self.names = names
    }

    /// The most bytes a group token may have.
    public static let maxTokenBytes = 64

    /// Whether `token` has a plate group token's shape: an ISO 3166-2 code, or "ne:region:", a capital
    /// alpha-2, ":" and one to 40 lower-case letters, digits or hyphens.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count <= maxTokenBytes else { return false }
        if AtlasAdmin1.hasISOShape(bytes) { return true }
        let prefix = Array("ne:region:".utf8)
        let isUpper: (UInt8) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
        let isSlug: (UInt8) -> Bool = { $0 >= 0x61 && $0 <= 0x7A || $0 >= 0x30 && $0 <= 0x39 || $0 == 0x2D }
        let head = prefix.count + 3
        guard bytes.count > head, bytes.count <= head + 40, Array(bytes[0..<prefix.count]) == prefix,
              isUpper(bytes[prefix.count]), isUpper(bytes[prefix.count + 1]), bytes[prefix.count + 2] == 0x3A else {
            return false
        }
        return bytes[head...].allSatisfy(isSlug)
    }
}

/// A state or province from the pack's `ADM1` section.
public nonisolated struct AtlasAdmin1: Hashable, Sendable {
    /// The frozen token: its ISO 3166-2 code ("US-OR"), else "ne:<Natural Earth id>".
    public let token: String
    /// The ISO 3166-1 alpha-2 code of the `CTRY` country it belongs to (the screen localises the country's
    /// name from it).
    public let countryCode: String
    /// Its English name and its Spanish one (empty: use English); data, not catalog strings.
    public let names: AtlasCityNames
    /// Its outline, for the point test (the screen draws state lines on hex edges between plate groups,
    /// ``WorldAtlas/border(between:and:)``, since an outline may be a second-level line).
    public let polygon: AtlasPolygon
    /// The plate group it is shown as: its first-level region, or itself.
    public let group: AtlasAdmin1Group

    /// An entry with every field given; with no `group` it is its own.
    public init(token: String, countryCode: String, names: AtlasCityNames, polygon: AtlasPolygon,
                group: AtlasAdmin1Group? = nil) {
        self.token = token
        self.countryCode = countryCode
        self.names = names
        self.polygon = polygon
        self.group = group ?? AtlasAdmin1Group(token: token, countryCode: countryCode, names: names)
    }

    /// The most bytes a token may have.
    public static let maxTokenBytes = 24

    /// Whether `token` has an admin-1 token's shape: an ISO 3166-2 code (two capital letters, a hyphen,
    /// one to three capitals or digits) or "ne:" and one to 12 digits.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard bytes.count <= maxTokenBytes else { return false }
        if hasISOShape(bytes) { return true }
        let isDigit: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
        let prefix = Array("ne:".utf8)
        guard bytes.count > prefix.count, bytes.count <= prefix.count + 12,
              Array(bytes[0..<prefix.count]) == prefix else { return false }
        return bytes[prefix.count...].allSatisfy(isDigit)
    }

    /// Whether `bytes` spell an ISO 3166-2 code: two capitals, a hyphen, one to three capitals or digits.
    static func hasISOShape(_ bytes: [UInt8]) -> Bool {
        let isUpper: (UInt8) -> Bool = { $0 >= 0x41 && $0 <= 0x5A }
        let isDigit: (UInt8) -> Bool = { $0 >= 0x30 && $0 <= 0x39 }
        guard bytes.count >= 4, bytes.count <= 6, isUpper(bytes[0]), isUpper(bytes[1]), bytes[2] == 0x2D else {
            return false
        }
        return bytes[3...].allSatisfy { isUpper($0) || isDigit($0) }
    }
}

/// Where a point is, for the world view's plate and its VoiceOver words: the plate group (the first-level
/// region, or the state or province itself) and the country. The screen formats it ("England · United
/// Kingdom", "Oregon · United States"), naming the country from ``countryCode``.
public nonisolated struct AtlasPlaceName: Hashable, Sendable {
    /// The country's alpha-2 code.
    public let countryCode: String
    /// The plate group's frozen token, or nil where the pack has no state under the point, or where the
    /// level names only the country.
    public let regionToken: String?
    /// The plate group's names (English, Spanish), or nil with ``regionToken``.
    public let regionNames: AtlasCityNames?

    /// A place with every field given.
    public init(countryCode: String, regionToken: String? = nil, regionNames: AtlasCityNames? = nil) {
        self.countryCode = countryCode
        self.regionToken = regionToken
        self.regionNames = regionNames
    }

    /// The place of `group`.
    public init(group: AtlasAdmin1Group) {
        self.init(countryCode: group.countryCode, regionToken: group.token, regionNames: group.names)
    }
}

extension WorldAtlasLayers {
    /// The most states and provinces (Natural Earth's admin-1 layer has about 4,600 features).
    static let maxAdmin1s = 8_192
    /// The most plate groups (the shipped pack has under a hundred).
    static let maxAdmin1Groups = 1_024
    /// The group index that means "its own group".
    static let ownGroup = 0xFFFF

    /// `ADM1`: the plate groups, then each entry's token, country, names, group and outline. Refuses a count
    /// over ``maxAdmin1s``, a token of the wrong shape or used twice, a country `CTRY` does not have, an empty
    /// English name, a group index past the table or in another country, and any malformed outline.
    static func admin1s(_ bytes: [UInt8], countryCodes: Set<String>) throws -> (groups: [AtlasAdmin1Group],
                                                                                entries: [AtlasAdmin1]) {
        var reader = AtlasByteReader(bytes, tag: "ADM1")
        let groups = try admin1Groups(from: &reader, countryCodes: countryCodes)
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
            let names = try admin1Names(from: &reader)
            let index = Int(try reader.u16())
            let group = groups.indices.contains(index) ? groups[index] : nil
            guard index == ownGroup || group?.countryCode == country else {
                throw WorldAtlasPackError.malformed("ADM1", "group")
            }
            entries.append(AtlasAdmin1(token: token, countryCode: country, names: names,
                                       polygon: try AtlasPolygon.read(from: &reader), group: group))
        }
        try reader.expectEnd()
        return (groups, entries)
    }

    /// The plate group table at the head of `ADM1`: each group's token, country and names.
    private static func admin1Groups(from reader: inout AtlasByteReader,
                                     countryCodes: Set<String>) throws -> [AtlasAdmin1Group] {
        let count = Int(try reader.u16())
        guard count <= maxAdmin1Groups else { throw WorldAtlasPackError.malformed("ADM1", "groupCount") }
        var groups: [AtlasAdmin1Group] = []
        var tokens = Set<String>()
        // Bounded: count <= maxAdmin1Groups.
        for _ in 0..<count {
            let token = try reader.shortString(field: "groupToken")
            guard AtlasAdmin1Group.isValidToken(token), tokens.insert(token).inserted else {
                throw WorldAtlasPackError.malformed("ADM1", "groupToken")
            }
            let country = try reader.ascii(2, field: "country")
            guard countryCodes.contains(country) else { throw WorldAtlasPackError.malformed("ADM1", "country") }
            groups.append(AtlasAdmin1Group(token: token, countryCode: country, names: try admin1Names(from: &reader)))
        }
        return groups
    }

    /// An English name (never empty) and a Spanish one (empty: use English).
    private static func admin1Names(from reader: inout AtlasByteReader) throws -> AtlasCityNames {
        let english = try reader.shortString(field: "name"), spanish = try reader.shortString(field: "name")
        guard !english.isEmpty else { throw WorldAtlasPackError.malformed("ADM1", "name") }
        return AtlasCityNames(english: english, spanish: spanish)
    }
}

/// The admin-1 lookups. Bounded: a fix tests only the entries whose boxes touch its one-degree cell
/// (`AtlasBoxIndex`, at most `WorldAtlasLayers.maxAdmin1s`), and of those only its country's own when the
/// country under it is known; each entry's box is tested before its rings.
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

    /// The state or province under `point`, among `countryCode`'s entries when it is given, else among all:
    /// the first in table order whose rings hold it. Only the entries whose boxes touch the point's one-degree
    /// cell are tested (``AtlasBoxIndex`` keeps table order, so the first found is the whole table's first).
    public func admin1(at point: GeoPoint, inCountry countryCode: String?) -> AtlasAdmin1? {
        guard point.isValid else { return nil }
        // Bounded: the cell's entries, each listed once (at most WorldAtlasLayers.maxAdmin1s).
        for index in admin1Boxes.candidates(at: point) where admin1s.indices.contains(Int(index)) {
            let entry = admin1s[Int(index)]
            if countryCode == nil || entry.countryCode == countryCode, entry.polygon.contains(point) { return entry }
        }
        return nil
    }

    /// The plate group under `point` (``admin1(at:)``'s group): England for a fix in Camden, Oregon for one
    /// in Portland. Nil where no state holds the point.
    public func admin1Group(at point: GeoPoint) -> AtlasAdmin1Group? {
        admin1(at: point)?.group
    }

    /// The plate's place at `point`: the plate group and its country, or just the country where no state
    /// holds the point, or nil where neither does (at sea).
    public func placeName(at point: GeoPoint) -> AtlasPlaceName? {
        guard point.isValid else { return nil }
        let country = country(at: point)?.code
        if let admin1 = admin1(at: point, inCountry: country) {
            return AtlasPlaceName(group: admin1.group)
        }
        return country.map { AtlasPlaceName(countryCode: $0) }
    }

    /// The states and provinces whose boxes touch `viewport`. One pass over the table. Their outlines can
    /// be second-level lines (Britain's council areas), so the screen draws state lines on hex edges by
    /// ``border(between:and:)`` instead.
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
        overlaps(minLon: polygon.minLon, minLat: polygon.minLat, maxLon: polygon.maxLon, maxLat: polygon.maxLat)
    }

    /// Whether the box with these edges (1e-5 degrees) touches this one, trying it a turn east and west too.
    func overlaps(minLon: Int32, minLat: Int32, maxLon: Int32, maxLat: Int32) -> Bool {
        guard Double(maxLat) >= south, Double(minLat) <= north else { return false }
        let turn = 360 * AtlasPolygon.unitsPerDegree
        return [-turn, 0, turn].contains { shift in
            Double(maxLon) + shift >= west && Double(minLon) + shift <= east
        }
    }
}
