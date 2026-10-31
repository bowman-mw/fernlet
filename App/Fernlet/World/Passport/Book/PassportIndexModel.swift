import FernletDomainModel
import Foundation
import WorldMapStore

/// The index at the back of Sprout's passport (World-Passport-Spec §7) and a continent's countries A to Z (§8),
/// worked out from the book and the atlas's countries.
///
/// The index names only what was found: one row per continent with its count and the countries found, A to Z, each
/// with every page it is on ("United States 3, 5", a stamp each trip); Antarctica's row; the oceans and the seas;
/// then (World-Airports-Spec §4.2) the airports found A to Z with every page they're on (the home airport a page
/// per trip), and the Flights row's count, pages and layovers.
/// The A to Z view lists every country of a continent in the current language's order, the earned ones named and
/// the rest as unnamed spaces. Names come from the caller (`name`), so the order follows the language the screen
/// shows. Bounded by the book's stamps and the atlas's country table.
nonisolated struct PassportIndexModel: Equatable, Sendable {
    /// A place found: its token (a passport country's upper-case code, an ocean's, a sea's or an airport's token),
    /// its name, and every page its stamps are on, earliest first.
    struct Place: Hashable, Sendable {
        let token: String
        let name: String
        let pages: [Int]
    }

    /// One continent's row: whether its own stamp is earned, its country count, the countries found A to Z.
    struct ContinentRow: Hashable, Sendable {
        let continent: AtlasContinent
        let earned: Bool
        let total: Int
        let places: [Place]
        /// The continent stamp's page, when earned.
        let page: Int?
    }

    /// The seven continents, in the passport's order.
    let continents: [ContinentRow]
    /// The oceans found, A to Z.
    let oceans: [Place]
    /// The seas found, A to Z.
    let seas: [Place]
    /// The airports found, A to Z, each with every page its trips' tickets are on.
    let airports: [Place]
    /// The Flights row, or nil where the book shows no Flights page (a decoy, the demo without flights).
    let flights: FlightsRow?
    /// How many passport countries are found (each once).
    let countryCount: Int

    /// The Flights row (`ap-index`): every flight counted once, the Flights pages' numbers, the layovers.
    struct FlightsRow: Hashable, Sendable {
        let count: Int
        let pages: ClosedRange<Int>
        let layovers: Int
    }

    /// The index of `book`, with `table` for each country's continent and sovereign, `name` for each place's
    /// name in `language` (which also orders them), and `flights` (the Flights pages' model, nil with none) for the
    /// Flights row.
    init(book: PassportBookModel, table: PassportCountryTable, language: FernletLanguage = .app,
         flights: PassportFlightsModel? = nil, name: (PassportStampKind) -> String) {
        var countryPages: [String: [Int]] = [:], airportPages: [String: [Int]] = [:]
        var otherPages: [PassportStampKey: Int] = [:]
        // Bounded: the book holds at most PassportStampEntry.maxEntries.
        for entry in book.ordered {
            guard let page = book.pageNumber(of: entry) else { continue }
            if entry.kind == .country {
                guard let code = table.passportCode(for: entry.token) else { continue }
                countryPages[code, default: []].append(page)
            } else if entry.kind == .airport {
                airportPages[entry.token, default: []].append(page)
            } else {
                otherPages[PassportStampKey(entry)] = page
            }
        }
        let places = countryPages.map { code, pages in
            Place(token: code, name: name(.country(code)), pages: Array(Set(pages)).sorted())
        }
        continents = AtlasContinent.passportOrder.map { continent in
            let found = places.filter { table.continent(of: $0.token) == continent }
            let page = otherPages[PassportStampKey(kind: .continent, token: continent.rawValue)]
            let total = continent == .antarctica ? 1 : (table.totals[continent] ?? continent.specCountryTotal)
            return ContinentRow(continent: continent, earned: page != nil, total: total,
                                places: Self.sorted(found, language: language), page: page)
        }
        let oceans = AtlasOcean.allCases.compactMap { ocean -> Place? in
            otherPages[PassportStampKey(kind: .ocean, token: ocean.rawValue)].map {
                Place(token: ocean.rawValue, name: name(.ocean(ocean)), pages: [$0])
            }
        }
        self.oceans = Self.sorted(oceans, language: language)
        let seas = otherPages.filter { $0.key.kind == .sea }.map { key, page in
            Place(token: key.token, name: name(.sea(key.token)), pages: [page])
        }
        self.seas = Self.sorted(seas, language: language)
        airports = Self.sorted(airportPages.map { token, pages in
            Place(token: token, name: name(.airport(token, transit: false)), pages: Array(Set(pages)).sorted())
        }, language: language)
        self.flights = Self.flightsRow(book: book, flights: flights)
        countryCount = places.count
    }

    /// The Flights row for `book`'s Flights pages, or nil where it shows none.
    static func flightsRow(book: PassportBookModel, flights: PassportFlightsModel?) -> FlightsRow? {
        guard let flights, let pages = book.flightPageNumbers else { return nil }
        return FlightsRow(count: flights.flightCount, pages: pages, layovers: flights.layoverCount)
    }

    /// `places` A to Z by name in `language` (accents and case ignored), then by token.
    static func sorted(_ places: [Place], language: FernletLanguage) -> [Place] {
        let locale = Locale(identifier: language.rawValue)
        return places.sorted { lhs, rhs in
            let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return order == .orderedSame ? lhs.token < rhs.token : order == .orderedAscending
        }
    }

    /// The row for `continent`.
    func row(_ continent: AtlasContinent) -> ContinentRow? {
        continents.first { $0.continent == continent }
    }
}

/// A continent's countries A to Z (World-Passport-Spec §8): every passport country of the continent in the
/// current language's order, earned or not. An unearned one is never named on screen (its name only places it).
nonisolated struct PassportContinentSheet: Equatable, Sendable {
    /// One country's space.
    struct Cell: Hashable, Sendable {
        /// The passport country's upper-case code (a frozen token; drawn as its stamp, never shown).
        let code: String
        /// Its name in the screen's language, shown only when earned.
        let name: String
        /// Whether a stamp has landed.
        let earned: Bool
        /// How many trips (stamps) it has; 0 when not reached.
        let trips: Int
        /// The page its first stamp landed on.
        let firstPage: Int?
    }

    let continent: AtlasContinent
    /// Every country of the continent, A to Z.
    let cells: [Cell]

    /// How many are earned.
    var earnedCount: Int { cells.filter(\.earned).count }

    /// `continent`'s sheet from `book`, with `table`'s countries and `name` in `language`.
    init(continent: AtlasContinent, book: PassportBookModel, table: PassportCountryTable,
         language: FernletLanguage = .app, name: (String) -> String) {
        var trips: [String: Int] = [:], first: [String: Int] = [:]
        // Bounded: the book holds at most PassportStampEntry.maxEntries.
        for entry in book.ordered where entry.kind == .country {
            guard let code = table.passportCode(for: entry.token), table.continent(of: code) == continent else {
                continue
            }
            trips[code, default: 0] += 1
            if first[code] == nil { first[code] = book.pageNumber(of: entry) }
        }
        let codes = table.continentOf.filter { $0.value == continent }.map(\.key)
        let locale = Locale(identifier: language.rawValue)
        let unsorted = codes.map { code in
            Cell(code: code, name: name(code), earned: trips[code] != nil, trips: trips[code] ?? 0,
                 firstPage: first[code])
        }
        self.continent = continent
        cells = unsorted.sorted { lhs, rhs in
            let order = lhs.name.compare(rhs.name, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return order == .orderedSame ? lhs.code < rhs.code : order == .orderedAscending
        }
    }
}

extension PassportStampKey {
    /// The key of a once-only stamp (continent, ocean, sea, special): trip 1.
    nonisolated init(kind: PassportStampEntry.Kind, token: String) {
        self.kind = kind
        self.token = token
        trip = 1
    }
}
