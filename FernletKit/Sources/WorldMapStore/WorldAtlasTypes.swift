import Foundation

// The World atlas's shared vocabulary (round 7, Docs/World-Atlas-Pack.md). Every rawValue here is a frozen
// token: the passport stores them, so they stay English and never change (the localization wall). Display
// names belong to the screens, which the design session approves first.

/// One of the seven continents, as the passport counts them.
public nonisolated enum AtlasContinent: String, CaseIterable, Codable, Sendable {
    case africa, antarctica, asia, europe, northAmerica, oceania, southAmerica

    /// The continent a pack's `CONT` code names (1 Africa … 7 South America), or nil for 0 or an unknown code.
    public init?(packCode: UInt8) {
        let order: [AtlasContinent] = [.africa, .antarctica, .asia, .europe, .northAmerica, .oceania, .southAmerica]
        guard packCode >= 1, Int(packCode) <= order.count else { return nil }
        self = order[Int(packCode) - 1]
    }
}

/// One of the five oceans, as the passport counts them. A sea is its own entry (``AtlasSea``), never its ocean.
public nonisolated enum AtlasOcean: String, CaseIterable, Codable, Sendable {
    case pacific, atlantic, indian, arctic, southern

    /// The ocean a pack's `OCEA` code names (1 Pacific … 5 Southern), or nil for 0 or an unknown code.
    public init?(packCode: UInt8) {
        let order: [AtlasOcean] = [.pacific, .atlantic, .indian, .arctic, .southern]
        guard packCode >= 1, Int(packCode) <= order.count else { return nil }
        self = order[Int(packCode) - 1]
    }
}

/// A sea from the bundled pack: its own passport entry, never counted toward its parent ocean (owner,
/// 2026-10-29: the Caribbean counts the Caribbean Sea, not the Atlantic).
public nonisolated struct AtlasSea: Hashable, Sendable {
    /// The frozen token: the sea's Wikidata ID, else "ne:<Natural Earth id>".
    public let token: String
    /// The ocean it opens onto, for display only ("a sea of the Atlantic").
    public let parentOcean: AtlasOcean
    /// Its names, in the same four languages a city's come in.
    public let names: AtlasCityNames

    /// A sea with every field given.
    public init(token: String, parentOcean: AtlasOcean, names: AtlasCityNames) {
        self.token = token
        self.parentOcean = parentOcean
        self.names = names
    }
}

/// The coarse terrain class of a map cell (the owner's coarse model: a coastline mask plus climate bands).
public nonisolated enum AtlasTerrain: String, CaseIterable, Codable, Sendable {
    case water, ice, tundra, mountain, borealForest, temperateForest, tropicalForest, savanna, grassland, desert,
         shrubland
}

/// A city's size class, from its population (the pixel skyline it gets on a card).
public nonisolated enum AtlasCitySize: String, CaseIterable, Codable, Sendable {
    /// Under 100,000 people.
    case town
    /// 100,000 or more.
    case city
    /// A million or more.
    case large
    /// Ten million or more.
    case mega

    /// The size a pack's `CITY` code names (0 town … 3 mega), or nil for an unknown code.
    public init?(packCode: UInt8) {
        let order: [AtlasCitySize] = [.town, .city, .large, .mega]
        guard Int(packCode) < order.count else { return nil }
        self = order[Int(packCode)]
    }
}

/// A city from the bundled pack.
public nonisolated struct AtlasCity: Hashable, Sendable {
    /// The frozen token: the city's Wikidata ID ("Q90"), else "ne:<Natural Earth id>".
    public let token: String
    /// The ISO 3166-1 alpha-2 code of the country it is in.
    public let countryCode: String
    /// Its size class.
    public let size: AtlasCitySize
    /// Its population, from the source (the largest figure Natural Earth gives).
    public let population: Int
    /// Its point.
    public let point: GeoPoint
    /// Its name in English, then Spanish, French and German where the source has them (data, not catalog
    /// strings; the screens pick one by the app's language).
    public let names: AtlasCityNames

    /// A city with every field given.
    public init(token: String, countryCode: String, size: AtlasCitySize, population: Int, point: GeoPoint,
                names: AtlasCityNames) {
        self.token = token
        self.countryCode = countryCode
        self.size = size
        self.population = population
        self.point = point
        self.names = names
    }
}

/// A city's names as the source spells them. An empty translation means "use English".
public nonisolated struct AtlasCityNames: Hashable, Sendable {
    /// The English name.
    public let english: String
    /// The Spanish name, or empty.
    public let spanish: String
    /// The French name, or empty.
    public let french: String
    /// The German name, or empty.
    public let german: String

    /// Names in the four languages the pack carries.
    public init(english: String, spanish: String = "", french: String = "", german: String = "") {
        self.english = english
        self.spanish = spanish
        self.french = french
        self.german = german
    }
}

/// Everything the atlas says about one accepted fix, with the visit rules already applied (ocean reach,
/// Antarctica's lighter rule, the city boundary).
public nonisolated struct AtlasVisit: Hashable, Sendable {
    /// The territory's ISO 3166-1 alpha-2 code, or nil at sea or where the pack has no country.
    public var countryCode: String?
    /// The sovereign state's alpha-2 code (a territory counts toward it in "N of 194"), or nil.
    public var sovereignCode: String?
    /// The continent the fix counts toward, or nil (at sea, unless Antarctica's rule holds).
    public var continent: AtlasContinent?
    /// The ocean within reach, or nil (nil whenever ``sea`` is set: the nearest water is one or the other).
    public var ocean: AtlasOcean?
    /// The sea within reach, or nil.
    public var sea: AtlasSea?
    /// The city whose boundary holds the fix, or nil.
    public var city: AtlasCity?
    /// The terrain class under the fix.
    public var terrain: AtlasTerrain
    /// The tokens (``AtlasLandmark/token``) of the landmarks whose find radius holds the fix, in the list's
    /// order; empty when none does or no landmark list is open. At most ``maxLandmarks`` are read.
    public var landmarks: [String]

    /// The most landmarks one visit counts (a fix within more find radii than this is not a real place).
    public static let maxLandmarks = 16

    /// A visit with every field given (tests build them by hand). `landmarks` comes last and defaults to none,
    /// so a visit written before landmarks existed reads the same.
    public init(countryCode: String? = nil, sovereignCode: String? = nil, continent: AtlasContinent? = nil,
                ocean: AtlasOcean? = nil, sea: AtlasSea? = nil, city: AtlasCity? = nil, terrain: AtlasTerrain,
                landmarks: [String] = []) {
        self.countryCode = countryCode
        self.sovereignCode = sovereignCode
        self.continent = continent
        self.ocean = ocean
        self.sea = sea
        self.city = city
        self.terrain = terrain
        self.landmarks = landmarks
    }
}

/// What kind of place a discovery is (a frozen token). The cases' order is the fixed order a visit's first
/// visits are reported in: country, continent, ocean, sea, city, landmark, terrain.
public nonisolated enum AtlasDiscoveryKind: String, CaseIterable, Codable, Sendable {
    case country, continent, ocean, sea, city, landmark, terrain
}

/// One first visit: the passport's record and the event Sprout's lines will hook into (idea B).
public nonisolated struct AtlasDiscovery: Hashable, Codable, Sendable {
    /// What kind of place.
    public let kind: AtlasDiscoveryKind
    /// The frozen token: an alpha-2 country code, an ``AtlasContinent``, ``AtlasOcean`` or ``AtlasTerrain``
    /// rawValue, or a sea's ``AtlasSea/token``, a city's ``AtlasCity/token`` or a landmark's
    /// ``AtlasLandmark/token``.
    public let token: String
    /// When it was first visited.
    public let at: Date

    /// A discovery of `token` of `kind` at `at`.
    public init(kind: AtlasDiscoveryKind, token: String, at: Date) {
        self.kind = kind
        self.token = token
        self.at = at
    }
}
