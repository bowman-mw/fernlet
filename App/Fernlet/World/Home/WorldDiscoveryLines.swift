import Foundation
import WorldMapStore

/// What kind of new place one of Sprout's discovery lines is for (World-Exploration-Spec §4, the mockup's `LINES`):
/// the terrain classes, a sea or lake shore, the five city sizes, a landmark, a new country, continent, ocean or
/// sea, the two specials, and a new airport and a landing (World-Airports-Spec §3, §6.3). Frozen tokens (they name
/// the lines' catalog keys and the DEBUG hook's words).
///
/// Cropland has lines but nothing selects it: the atlas carries no land cover (lane call, round 7).
nonisolated enum WorldLineCategory: String, CaseIterable, Sendable {
    case desert, mountain, temperateForest, tropicalForest, borealForest
    case grassland, cropland, shore, tundra, ice
    case village, town, city, bigCity, megacity
    case landmark, country, continent
    case ocean, sea, allContinents, allOceans
    case airport, landing

    /// The lines board the category sits on (the mockup's `land`, `open`, `towns`, `marks`, `world`).
    var board: WorldLineBoard {
        switch self {
        case .desert, .mountain, .temperateForest, .tropicalForest, .borealForest: .land
        case .grassland, .cropland, .shore, .tundra, .ice: .open
        case .village, .town, .city, .bigCity, .megacity: .towns
        case .landmark, .country, .continent: .marks
        case .ocean, .sea, .allContinents, .allOceans: .world
        case .airport, .landing: .airports
        }
    }

    /// Which line wins when one fix finds several new places (one line at a time): the two specials, then a
    /// continent, a country, an ocean, a sea, a landmark, a city (any size) and last the ground under it, so a
    /// city always beats a biome (spec §4). A landing beats everything (World-Airports-Spec §6.3: its line, not the
    /// new airport's, greets the landing), and a new airport ranks with a landmark. Higher wins.
    var priority: Int {
        switch board {
        case .land, .open: 0
        case .towns: 1
        case .marks, .world, .airports: Self.markPriority[self] ?? 2
        }
    }

    /// The order among the landmark, country, continent, ocean, sea and the specials (lane call, for the owner).
    private static let markPriority: [WorldLineCategory: Int] = [
        .landmark: 2, .sea: 3, .ocean: 4, .country: 5, .continent: 6, .allOceans: 7, .allContinents: 8,
        .airport: 2, .landing: 9,
    ]

    /// The category for a passport terrain class: the classifier's classes as the terrain sets map them
    /// (savanna and shrubland walk on the meadow ground, so they are grassland), water as a sea or lake shore.
    init(terrain: AtlasTerrain) {
        switch terrain {
        case .water: self = .shore
        case .ice: self = .ice
        case .tundra: self = .tundra
        case .mountain: self = .mountain
        case .borealForest: self = .borealForest
        case .temperateForest: self = .temperateForest
        case .tropicalForest: self = .tropicalForest
        case .savanna, .grassland, .shrubland: self = .grassland
        case .desert: self = .desert
        }
    }

    /// The category for a city of `size`.
    init(size: WorldCitySizeClass) {
        switch size {
        case .village: self = .village
        case .town: self = .town
        case .city: self = .city
        case .bigCity: self = .bigCity
        case .megacity: self = .megacity
        }
    }
}

/// The five lines boards of the approved page (`ex-lines-land`, `-open`, `-towns`, `-marks`, `-world`), and the
/// airports' (World-Airports-Spec §3, §6.3: a new airport and a landing, drafts for the owner's string review).
/// Frozen tokens.
nonisolated enum WorldLineBoard: String, CaseIterable, Sendable, Identifiable {
    case land, open, towns, marks, world, airports

    /// The board's token.
    var id: String { rawValue }

    /// The board's categories, in the mockup's order.
    var categories: [WorldLineCategory] {
        WorldLineCategory.allCases.filter { $0.board == self }
    }
}

/// One of Sprout's discovery lines: its category, which of the three lines (Sprout takes turns), the place's name
/// filled in, and the fix it came from (every first visit of one fix shares its date, so a later find of the same
/// fix is told apart from the next fix's).
nonisolated struct WorldDiscoveryLine: Equatable, Sendable {
    /// How many lines each category has (all three approved, spec §4).
    static let linesPerCategory = 3

    let category: WorldLineCategory
    /// Which line, 0 to 2.
    let index: Int
    /// The place's name, for the lines that fill one in.
    let name: String
    /// The fix's date (the first visit's).
    let at: Date

    /// The line's words, in the app's language.
    var text: String { WorldDiscoveryLinesCopy.line(category, index: index, name: name) }
}

/// What the lines need to know about a place beyond its token: its name in the app's language and a city's size.
/// The app reads them from the atlas and the landmark list (``live(_:)``); tests pass their own.
struct WorldDiscoveryPlaces {
    /// A city's name and size class, by token; nil when the atlas has no such city.
    var city: @MainActor (String) -> (name: String, size: WorldCitySizeClass)?
    /// A landmark's name, by token.
    var landmark: @MainActor (String) -> String?
    /// A sea's name, by token.
    var sea: @MainActor (String) -> String?
    /// A country's name, by its alpha-2 code.
    var country: @MainActor (String) -> String

    /// The places as the app knows them: the bundled atlas and landmark list (public data, opened by the keeper).
    static func live(_ keeper: WorldAtlasKeeper) -> WorldDiscoveryPlaces {
        WorldDiscoveryPlaces(
            city: { token in
                keeper.openedAtlas?.city(token: token).map { (name: WorldExploreCopy.name(of: $0), size: WorldCitySizeClass(city: $0)) }
            },
            landmark: { token in keeper.landmarks.landmark(token: token).map { WorldExploreCopy.name(of: $0) } },
            sea: { token in keeper.openedAtlas?.sea(token: token).map { PassportNames.sea($0) } },
            country: { code in WorldExploreCopy.country(code: code) })
    }
}

/// Chooses Sprout's line for one first visit (World-Exploration-Spec §4). Pure.
///
/// **Once per category and place, nothing stored.** A first visit happens once per place (the passport records each
/// token once), so a line is said only for a ``PassportEvent/firstVisit(_:)`` whose date is still the passport's own
/// first-visit date for that token: a restored or merged earlier date, or an event the book no longer holds, says
/// nothing. **Turns** come from the passport too: the line's index is the place's place among its kind's first
/// visits (earliest first, ties by token), modulo three, so the next new city of any size takes the next line.
/// **The specials:** a continent that completes all seven says the all-seven line instead, and an ocean that
/// completes all five the all-five line.
enum WorldLinePicker {
    /// The line for `discovery`, read against `book` (the passport after it was saved), or nil: a decoy, a
    /// date the book doesn't hold, cropland, a place whose name or size can't be read.
    static func line(for discovery: AtlasDiscovery, in book: PassportBook, places: WorldDiscoveryPlaces,
                     isDecoy: Bool) -> WorldDiscoveryLine? {
        guard !isDecoy, book.firstVisit(discovery.kind, token: discovery.token) == discovery.at,
              let named = categoryAndName(of: discovery, in: book, places: places) else { return nil }
        let index = turn(of: discovery, in: book)
        return WorldDiscoveryLine(category: named.0, index: index, name: named.1, at: discovery.at)
    }

    /// The better of two lines for one fix: the higher ``WorldLineCategory/priority``, the earlier on a tie; a line
    /// from a newer fix always replaces one from an older.
    static func better(_ current: WorldDiscoveryLine?, _ next: WorldDiscoveryLine) -> WorldDiscoveryLine {
        guard let current, current.at == next.at else { return next }
        return next.category.priority > current.category.priority ? next : current
    }

    /// The category and the name filled in.
    private static func categoryAndName(of discovery: AtlasDiscovery, in book: PassportBook,
                                        places: WorldDiscoveryPlaces) -> (WorldLineCategory, String)? {
        let token = discovery.token
        switch discovery.kind {
        case .terrain:
            return AtlasTerrain(rawValue: token).map { (WorldLineCategory(terrain: $0), "") }
        case .city:
            return places.city(token).map { (WorldLineCategory(size: $0.size), $0.name) }
        case .landmark:
            return places.landmark(token).map { (.landmark, $0) }
        case .country:
            return (.country, places.country(token))
        case .sea:
            return places.sea(token).map { (.sea, $0) }
        case .continent:
            guard let continent = AtlasContinent(rawValue: token) else { return nil }
            let all = completes(discovery, of: AtlasContinent.allCases.count, in: book)
            return (all ? .allContinents : .continent, String(localized: continent.passportName))
        case .ocean:
            guard let ocean = AtlasOcean(rawValue: token) else { return nil }
            let all = completes(discovery, of: AtlasOcean.allCases.count, in: book)
            return (all ? .allOceans : .ocean, String(localized: ocean.passportName))
        case .airport:
            // Sprout's new-airport lines (World-Airports-Spec §3): once per airport, taking turns; no name.
            return (.airport, "")
        }
    }

    /// Whether `discovery` is the visit that made its kind complete: the book holds all `total` and this one is
    /// the latest of them.
    static func completes(_ discovery: AtlasDiscovery, of total: Int, in book: PassportBook) -> Bool {
        let visits = book.visits(of: discovery.kind)
        return visits.count >= total && visits.values.max() == discovery.at
    }

    /// The line's turn: how many of its kind came first (earliest first, ties by token), modulo three. Bounded
    /// by the kind's cap.
    static func turn(of discovery: AtlasDiscovery, in book: PassportBook) -> Int {
        var before = 0
        for (token, date) in book.visits(of: discovery.kind).prefix(PassportBook.cap(for: discovery.kind))
        where date < discovery.at || (date == discovery.at && token < discovery.token) {
            before += 1
        }
        return before % WorldDiscoveryLine.linesPerCategory
    }

    /// The stamps a first visit earns, for the passport's new-stamp moment: a country, continent, ocean or sea
    /// stamp, followed by the all-seven or all-five special when it completes them; none for a city, a landmark
    /// or the ground, and none for an airport (its stamp has its own banners, World-Airports-Spec §3, §6.3).
    static func stamps(for discovery: AtlasDiscovery, in book: PassportBook) -> [PassportStamp] {
        let kind: PassportStamp.Kind
        switch discovery.kind {
        case .country: kind = .country
        case .continent: kind = .continent
        case .ocean: kind = .ocean
        case .sea: kind = .sea
        case .city, .landmark, .terrain, .airport: return []
        }
        var stamps = [PassportStamp(kind: kind, token: discovery.token, date: discovery.at)]
        if kind == .continent, completes(discovery, of: AtlasContinent.allCases.count, in: book) {
            stamps.append(PassportStamp(kind: .allContinents, token: PassportStamp.Kind.allContinents.rawValue, date: discovery.at))
        }
        if kind == .ocean, completes(discovery, of: AtlasOcean.allCases.count, in: book) {
            stamps.append(PassportStamp(kind: .allOceans, token: PassportStamp.Kind.allOceans.rawValue, date: discovery.at))
        }
        return stamps
    }
}
