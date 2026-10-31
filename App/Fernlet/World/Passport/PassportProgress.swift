import Foundation
import WorldMapStore

/// How far a passport has come, read from one ``PassportBook`` against the bundled atlas (World-Exploration-Spec §3):
/// countries N of 194 (each one of the passport's countries, a territory counting toward its sovereign state, as
/// the atlas's `CTRY` table says), continents N of 7, oceans N of 5, the seas (no fixed total), the two specials,
/// the airports found (no total, World-Airports-Spec §4.2: "6 airports"), and each continent's countries, in
/// first-visit order.
///
/// A value built from the book its caller hands it (the screens hand it `store.worldFog.atlas.book`: the person's,
/// or an empty one in a decoy, so a decoy counts nothing) and the atlas's country table (``PassportCountryTable``,
/// built once). It only adds up: every count is what the book holds, never a rate or a streak. Bounded by the book's
/// caps.
nonisolated struct PassportProgress: Equatable, Sendable {
    /// The earned passport countries (upper-case alpha-2), earliest first visit first.
    let countries: [String]
    /// The continents reached.
    let continents: Set<AtlasContinent>
    /// The oceans reached.
    let oceans: Set<AtlasOcean>
    /// The seas reached (their frozen tokens), earliest first visit first.
    let seas: [String]
    /// The airports found (their frozen tokens), earliest first trip first; each once however many trips.
    let airports: [String]
    /// Each earned country's continent (from the atlas).
    private let continentOfEarned: [String: AtlasContinent]
    /// Each continent's number of passport countries.
    private let totals: [AtlasContinent: Int]

    /// The total the progress line counts countries against: 194 (North Korea out).
    static let countryTotal = WorldAtlas.passportCountryTotal
    /// Seven continents.
    static let continentTotal = AtlasContinent.allCases.count
    /// Five oceans.
    static let oceanTotal = AtlasOcean.allCases.count

    /// The passport `book` holds (its first visits, ``PassportStampEntry/firstVisits(in:)``), counted with `table`.
    init(book: PassportBook, table: PassportCountryTable) {
        self.init(entries: PassportStampEntry.firstVisits(in: book), table: table)
    }

    /// The stamps `entries` hold, counted with `table` (the atlas's countries; ``PassportCountryTable/empty`` when
    /// the atlas is missing, which counts every country token as itself and uses the spec's totals). Each country,
    /// continent, ocean and sea counts once however many stamps it has (a stamp each trip); the specials' own
    /// entries are not counted, they follow from the continents and oceans.
    init(entries: [PassportStampEntry], table: PassportCountryTable) {
        var earned: [String] = [], seen = Set<String>(), continentOf: [String: AtlasContinent] = [:]
        var continents = Set<AtlasContinent>(), oceans = Set<AtlasOcean>(), seas: [String] = [], seenSeas = Set<String>()
        var airports: [String] = [], seenAirports = Set<String>()
        // Bounded: the ordering function keeps at most PassportStampEntry.maxEntries.
        for entry in PassportStampEntry.ordered(entries) {
            switch entry.kind {
            case .country:
                guard let code = table.passportCode(for: entry.token), seen.insert(code).inserted else { continue }
                earned.append(code)
                continentOf[code] = table.continent(of: code)
            case .continent: if let continent = AtlasContinent(rawValue: entry.token) { continents.insert(continent) }
            case .ocean: if let ocean = AtlasOcean(rawValue: entry.token) { oceans.insert(ocean) }
            case .sea: if seenSeas.insert(entry.token).inserted { seas.append(entry.token) }
            case .airport: if seenAirports.insert(entry.token).inserted { airports.append(entry.token) }
            case .special: continue
            }
        }
        countries = earned
        continentOfEarned = continentOf
        self.continents = continents
        self.oceans = oceans
        self.seas = seas
        self.airports = airports
        totals = table.totals
    }

    /// How many passport countries `continent` has (the atlas's count; the spec's with no atlas).
    func total(in continent: AtlasContinent) -> Int {
        totals[continent] ?? continent.specCountryTotal
    }

    /// The earned countries of `continent`, earliest first.
    func earned(in continent: AtlasContinent) -> [String] {
        countries.filter { continentOfEarned[$0] == continent }
    }

    /// "N of 194 countries".
    var countryCount: Int { countries.count }
    /// "N of 7 continents".
    var continentCount: Int { continents.count }
    /// "N of 5 oceans".
    var oceanCount: Int { oceans.count }
    /// The seas found (each its own stamp; no total).
    var seaCount: Int { seas.count }
    /// The airports found ("6 airports"; no total).
    var airportCount: Int { airports.count }
    /// How many of the two specials are earned.
    var specialsEarned: Int { (hasAllContinents ? 1 : 0) + (hasAllOceans ? 1 : 0) }

    /// Whether all seven continents are reached (the first special).
    var hasAllContinents: Bool { continents.count >= Self.continentTotal }
    /// Whether all five oceans are reached (the second special).
    var hasAllOceans: Bool { oceans.count >= Self.oceanTotal }
}

/// The atlas's passport countries, read once: each of the 194 with its continent, each territory's sovereign, and
/// every continent's count, so ``PassportProgress`` is a few dictionary reads per render. Public data from the
/// bundled pack. Bounded by the pack's country table (``WorldAtlas/countries``).
nonisolated struct PassportCountryTable: Equatable, Sendable {
    /// Each passport country's continent.
    let continentOf: [String: AtlasContinent]
    /// Each territory or country code to the passport country it counts toward (itself, or its sovereign).
    let countsToward: [String: String]
    /// Each continent's number of passport countries.
    let totals: [AtlasContinent: Int]

    /// A table with no atlas: a country token counts as itself and has no continent; totals are the spec's.
    static let empty = PassportCountryTable(continentOf: [:], countsToward: [:], totals: [:])

    /// The table for `atlas`.
    init(atlas: WorldAtlas) {
        var continentOf: [String: AtlasContinent] = [:], totals: [AtlasContinent: Int] = [:]
        let counted = Set(atlas.countries.filter(\.countsInPassport).map(\.code))
        // Bounded: one pass over the pack's capped country table.
        for country in atlas.countries where country.countsInPassport && continentOf[country.code] == nil {
            guard let continent = country.continent else { continue }
            continentOf[country.code] = continent
            totals[continent, default: 0] += 1
        }
        var toward: [String: String] = [:]
        for country in atlas.countries where !WorldAtlas.excludedFromPassport.contains(country.code) {
            if counted.contains(country.code) {
                toward[country.code] = country.code
            } else if counted.contains(country.sovereignCode) {
                toward[country.code] = country.sovereignCode
            }
        }
        self.init(continentOf: continentOf, countsToward: toward, totals: totals)
    }

    /// A table with every part given (tests, and ``empty``).
    init(continentOf: [String: AtlasContinent], countsToward: [String: String], totals: [AtlasContinent: Int]) {
        self.continentOf = continentOf
        self.countsToward = countsToward
        self.totals = totals
    }

    /// The passport country `token` counts toward, or nil when it counts toward none (a territory of no passport
    /// country, or an excluded one). With no atlas every token but the excluded counts as itself.
    func passportCode(for token: String) -> String? {
        let code = token.uppercased()
        guard !WorldAtlas.excludedFromPassport.contains(code) else { return nil }
        guard !countsToward.isEmpty else { return code }
        return countsToward[code]
    }

    /// The continent of passport country `code`, or nil (no atlas).
    func continent(of code: String) -> AtlasContinent? {
        continentOf[code]
    }
}
