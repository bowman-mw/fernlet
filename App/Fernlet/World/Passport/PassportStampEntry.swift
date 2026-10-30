import Foundation
import WorldMapStore

/// One stamp as it lands in Sprout's passport (World-Passport-Spec §6): what it is, its frozen token, the moment it
/// was earned (the reading that earned it: a first visit, or a trip's start) and which trip it is.
///
/// The fields line up with the per-trip passport store (`PassportBook.stamps`: kind, token, date, trip number; "a
/// stamp each trip", a country stamped again after at least 7 days away), so the screens feed it in with a one-line
/// adapter; ``firstVisits(in:)`` builds the same list from a book's first visits alone (trip 1 each). Everything
/// here takes a plain list of entries and never reads the store's format.
nonisolated struct PassportStampEntry: Hashable, Sendable {
    /// The kinds of stamp, in the order stamps earned at the same moment land (the store's: country, then
    /// continent, ocean, sea, specials). The rawValues are frozen tokens (never shown).
    enum Kind: String, CaseIterable, Hashable, Sendable {
        case country, continent, ocean, sea, special
    }

    /// The all-continents special's token (frozen).
    static let allContinentsToken = "allContinents"
    /// The all-oceans special's token (frozen).
    static let allOceansToken = "allOceans"

    let kind: Kind
    /// The frozen token: an alpha-2 country code, an `AtlasContinent` or `AtlasOcean` rawValue, a sea's atlas token,
    /// or a special's token.
    let token: String
    /// When it was earned: the reading's own time, so it orders stamps of the same day too. The date box prints
    /// its day.
    let date: Date
    /// Which trip it is, from 1 (only a country has more than one).
    let trip: Int

    /// An entry with every field given; `trip` is at least 1.
    init(kind: Kind, token: String, date: Date, trip: Int = 1) {
        self.kind = kind
        self.token = token
        self.date = date
        self.trip = max(trip, 1)
    }

    /// The stamp this entry draws, or nil for a token that names nothing (an unknown continent or ocean).
    var stampKind: PassportStampKind? {
        switch kind {
        case .country: .country(token)
        case .continent: AtlasContinent(rawValue: token).map(PassportStampKind.continent)
        case .ocean: AtlasOcean(rawValue: token).map(PassportStampKind.ocean)
        case .sea: .sea(token)
        case .special: .special(allOceans: token == Self.allOceansToken)
        }
    }

    // MARK: From a book's first visits

    /// One entry per first visit in `book` (countries, continents, oceans, seas; never cities, landmarks or
    /// terrain), trip 1 each, plus each special dated by its last continent or ocean. Unordered; ``ordered(_:calendar:)``
    /// orders them. Bounded by the book's caps.
    static func firstVisits(in book: PassportBook) -> [PassportStampEntry] {
        let kinds: [(AtlasDiscoveryKind, Kind)] = [(.country, .country), (.continent, .continent), (.ocean, .ocean),
                                                   (.sea, .sea)]
        var entries: [PassportStampEntry] = []
        for (discovery, kind) in kinds {
            for (token, date) in book.visits(of: discovery).prefix(PassportBook.cap(for: discovery)) {
                entries.append(PassportStampEntry(kind: kind, token: token, date: date))
            }
        }
        let continents = book.visits(of: .continent), oceans = book.visits(of: .ocean)
        if continents.count >= AtlasContinent.allCases.count, let last = continents.values.max() {
            entries.append(PassportStampEntry(kind: .special, token: allContinentsToken, date: last))
        }
        if oceans.count >= AtlasOcean.allCases.count, let last = oceans.values.max() {
            entries.append(PassportStampEntry(kind: .special, token: allOceansToken, date: last))
        }
        return entries
    }

    // MARK: Order and pages

    /// How many stamps a page holds: two across, three down.
    static let perPage = 6
    /// The most entries ordered (a lifetime of trips, with room).
    static let maxEntries = 20_000

    /// `entries` in visit order (World-Passport-Spec §6, owner: "Mixed in"): by the day each was earned in
    /// `calendar`, then by its reading time; at the same moment a country, then its continent, ocean, sea and the
    /// specials (the store's own tie order); then by token and trip, so the order never depends on the input's.
    static func ordered(_ entries: [PassportStampEntry], calendar: Calendar = .current) -> [PassportStampEntry] {
        let kept = entries.prefix(maxEntries).map { (entry: $0, day: calendar.startOfDay(for: $0.date)) }
        return kept.sorted { lhs, rhs in
            if lhs.day != rhs.day { return lhs.day < rhs.day }
            if lhs.entry.date != rhs.entry.date { return lhs.entry.date < rhs.entry.date }
            let left = rank(lhs.entry.kind), right = rank(rhs.entry.kind)
            if left != right { return left < right }
            if lhs.entry.token != rhs.entry.token { return lhs.entry.token < rhs.entry.token }
            return lhs.entry.trip < rhs.entry.trip
        }.map(\.entry)
    }

    /// The stamp pages: `entries` in visit order, ``perPage`` to a page. Empty for no entries.
    static func pages(_ entries: [PassportStampEntry], calendar: Calendar = .current) -> [[PassportStampEntry]] {
        let ordered = ordered(entries, calendar: calendar)
        return stride(from: 0, to: ordered.count, by: perPage).map {
            Array(ordered[$0 ..< min($0 + perPage, ordered.count)])
        }
    }

    /// A kind's place among stamps earned at the same moment.
    private static func rank(_ kind: Kind) -> Int {
        Kind.allCases.firstIndex(of: kind) ?? Kind.allCases.count
    }
}
