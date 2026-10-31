import Foundation

/// One stamp of the passport book, in visit order (World-Passport-Spec §6, owner 2026-10-29: "Mixed in" and
/// "Stamp each trip"): a country stamp for each trip, an airport stamp for each trip through it
/// (World-Airports-Spec §4.2), and one stamp for each continent, ocean and sea and for each of the two specials
/// (all seven continents, all five oceans), on the day it was earned. Cities, landmarks and terrain classes are
/// passport entries, not stamps. ``PassportBook/stamps`` lists them.
public nonisolated struct PassportStamp: Hashable, Sendable {
    /// What the stamp is for (frozen rawValues). The order is the order of stamps earned at the same moment, so a
    /// landing's airport stamp comes before the country's.
    public enum Kind: String, CaseIterable, Sendable {
        /// One trip through an airport (World-Airports-Spec §4.2); a layover's says TRANSIT (``isTransit``).
        case airport
        /// One trip to a country or territory.
        case country
        /// A continent, at its first visit.
        case continent
        /// An ocean, at its first visit.
        case ocean
        /// A sea, at its first visit.
        case sea
        /// The special for all seven continents, on the day the seventh was reached.
        case allContinents
        /// The special for all five oceans, on the day the fifth was reached.
        case allOceans
    }

    /// What the stamp is for.
    public let kind: Kind
    /// The frozen token: an airport's ``WorldAirport/token``, an alpha-2 country code, an ``AtlasContinent`` or
    /// ``AtlasOcean`` rawValue, a sea's ``AtlasSea/token``, or the kind's own rawValue for a special.
    public let token: String
    /// When it was earned: the start of a country's or an airport's trip, or the first visit.
    public let date: Date
    /// Which trip, from 1: a country's or an airport's first trip is 1, its next 2, and every other stamp is 1.
    public let trip: Int
    /// Whether an airport's trip was a layover (flown on without leaving the grounds): its stamp says TRANSIT
    /// where the city goes (World-Airports-Spec §4.2). Always false for every other kind.
    public let isTransit: Bool

    /// A stamp of `kind` for `token` earned at `date` on trip `trip`, a layover when `isTransit`.
    public init(kind: Kind, token: String, date: Date, trip: Int = 1, isTransit: Bool = false) {
        self.kind = kind
        self.token = token
        self.date = date
        self.trip = trip
        self.isTransit = isTransit
    }
}

/// One thing the passport announces once it is saved (the app's `WorldAtlasKeeper` stream, for Sprout's lines and
/// the passport opening on a new stamp, World-Passport-Spec §6): a first visit, or a new trip to a country that
/// was visited before (owner 2026-10-29, "Stamp each trip": a return trip is a new stamp). An airport announces
/// the same two (World-Airports-Spec §3, §4.2), from ``PassportBook/recordAirport(token:at:by:)``.
public nonisolated enum PassportEvent: Hashable, Sendable {
    /// A place visited for the first time (a country's first visit is its first trip, announced here only).
    case firstVisit(AtlasDiscovery)
    /// A new trip to a country or through an airport after 7 or more days away: kind `country` or `airport`, its
    /// token, the trip's start and its trip number (2 or more).
    case newTrip(PassportStamp)

    /// The first visit, or nil for a new trip.
    public var discovery: AtlasDiscovery? {
        guard case .firstVisit(let discovery) = self else { return nil }
        return discovery
    }

    /// The new trip's stamp, or nil for a first visit.
    public var trip: PassportStamp? {
        guard case .newTrip(let stamp) = self else { return nil }
        return stamp
    }
}

/// The World passport's contents (round 7, idea 4; owner 2026-10-29): every country or territory, continent,
/// ocean, sea, city, landmark, terrain class and airport the person has been to, each by its frozen token
/// (``AtlasDiscovery/token``) with the date of the first visit, every trip to each country and through each
/// airport, and every flight (World-Airports-Spec §8–§10). A value type with no display strings. A found
/// landmark is kept by its token alone; its city comes from the bundled list (``WorldLandmarks``), so the
/// city card counts it with ``foundLandmarkCount(inCity:of:)``.
///
/// **Versioned bytes.** ``encoded()`` and ``init(data:)`` are the one format of the sealed file on the iPhone
/// (``PassportStore``); Fernlet's sealed iCloud backup carries the same entries one record each and rebuilds a
/// restored book with ``init(discoveries:)`` under the same rules. The bytes are JSON with a
/// `version` field (``currentVersion``) and one object per kind, token to first date in seconds since 1970.
/// A version this build does not know, a kind over its cap, or a token that is not a token is refused whole.
/// Landmarks joined version 1 as one more kind key (`landmark`), and airports and flights as more keys (below); a
/// build from before them reads such a book with those keys left out.
///
/// **Trips** (owner 2026-10-29, "Stamp each trip"). A country earns a new stamp each time the person comes back
/// after ``tripGap`` (7 days) or more away from it, their own country included: an accepted fix in a country at
/// least ``tripGap`` after the last accepted fix there (``lastSeen(inCountry:)``) starts a trip on that fix's
/// date. The first visit is the first trip; the later ones are kept in the `returns` key (token to trip starts,
/// earliest first) and the clock in `lastSeen` (token to the last fix's date). The counts still count each country
/// once (``count(of:)``), and continents, oceans, seas and the two specials stay one stamp each. A book written
/// before trips reads as one trip per country, last seen on that trip's date.
///
/// **Airports** (World-Airports-Spec §3, §4.2). Kind `airport`, by the airport's frozen ``WorldAirport/token``.
/// An airport is never found from a visit: the app decides (ten minutes inside its outline, a ticket or a landing)
/// and calls ``recordAirport(token:at:by:)``. Its trips follow the same 7-day rule, so the home airport gets a stamp
/// each time the person flies home; they are kept in their OWN keys, `airportReturns` (token to later trip starts)
/// and `airportLastSeen` (token to the clock), never in `returns` or `lastSeen`: a build from before airports
/// refuses any token there that isn't a country, and would then remove the whole passport. A layover marks its
/// trip's start in `airportTransit` (token to trip starts).
///
/// **Flights** (World-Airports-Spec §8–§10): `flights` (flown, Fernlet's own and imported, one flight once) and
/// `upcomingFlights` (from the calendar, kept for their day), each a list of ``PassportFlight``.
///
/// **Across builds** (World-Airports-Spec §11). A key this build does not know is kept as it was read
/// (``PassportJSONValue``, at most ``maxUnknownKeys``, one nested too deep left out) and written back by
/// ``encoded()``, so a newer Fernlet's data survives a round trip through this build; equality counts it. The
/// sealed backup's records of a kind this build does not know are kept too, under `keptBackupRecords`
/// (``keptBackupRecords``), and carried again in every backup this build writes.
///
/// **Bounded** (Power of 10): at most ``cap(for:)`` entries per kind (300 countries and territories,
/// 7 continents, 5 oceans, 250 seas, 20,000 cities, 5,000 landmarks, 20 terrain classes, 10,000 airports), tokens
/// of at most ``maxTokenBytes`` bytes (an airport's at most ``maxAirportTokenBytes``), at most ``maxReturns`` later
/// country trips and ``maxAirportReturns`` later airport trips in all, ``maxTransits`` layovers, ``maxFlights``
/// flights, ``maxUpcomingFlights`` upcoming flights, ``maxKeptBackupRecords`` kept records, and at most
/// ``maxEncodedBytes`` of encoding. Past a cap a new entry, trip or flight is refused and counted
/// (``refusedCount``), never an eviction of an earlier one.
public nonisolated struct PassportBook: Codable, Equatable, Sendable {
    /// The format version this build writes and reads.
    public static let currentVersion = 1
    /// The longest token kept, in UTF-8 bytes.
    public static let maxTokenBytes = 64
    /// The largest encoding read (a full book is about 1.6 MB).
    public static let maxEncodedBytes = 4 * 1_024 * 1_024
    /// The least time away from a country before coming back starts a new trip: 7 days (owner 2026-10-29).
    public static let tripGap: TimeInterval = 7 * 24 * 60 * 60
    /// The most trips kept after the countries' first ones, in all (a weekly crossing for 380 years).
    public static let maxReturns = 20_000
    /// The most first visits one visit can add: one of each kind a visit names but landmarks, plus up to
    /// ``AtlasVisit/maxLandmarks`` landmarks.
    public static let maxDiscoveriesPerVisit = AtlasDiscoveryKind.visitKinds.count - 1 + AtlasVisit.maxLandmarks
    /// The longest airport token kept, in UTF-8 bytes.
    public static let maxAirportTokenBytes = 16
    /// The most trips kept after the airports' first ones, in all (a flight home every week for 96 years).
    public static let maxAirportReturns = 5_000
    /// The most airport trips marked as layovers, in all.
    public static let maxTransits = 5_000
    /// The most flights kept (spec §8: a long imported history runs over many pages).
    public static let maxFlights = 20_000
    /// The most upcoming flights kept (spec §10.6 looks 60 days ahead).
    public static let maxUpcomingFlights = 500
    /// The most sealed-backup records of unknown kinds kept (spec §11).
    public static let maxKeptBackupRecords = 5_000
    /// The most top-level keys this build does not know that are kept (spec §11).
    public static let maxUnknownKeys = 64

    /// Why bytes were refused as a passport.
    public enum BookError: Error, Equatable {
        /// The bytes are larger than any passport this build writes.
        case tooLarge
        /// The bytes are not a passport at all.
        case malformed
        /// A passport from a format version this build does not read.
        case unsupportedVersion(Int)
        /// More entries of a kind than its cap allows.
        case overCap(AtlasDiscoveryKind)
        /// An entry whose token is empty, too long, or not a token of its kind.
        case badToken(AtlasDiscoveryKind)
        /// A flight that breaks one of ``PassportFlight``'s rules.
        case badFlight
        /// More flights, or upcoming flights, than their cap allows.
        case tooManyFlights
    }

    /// The format version of this book (always ``currentVersion`` once read).
    public let version: Int
    /// Token to first-visit date, by kind; a kind with no entries has no key.
    var entries: [AtlasDiscoveryKind: [String: Date]]
    /// Each country's trips after its first: token to the trip starts, earliest first; a country with one trip
    /// has no key.
    var returns: [String: [Date]]
    /// The last accepted fix in each visited country (the trip rule's clock), never before its latest trip.
    var lastSeen: [String: Date]
    /// Each airport's trips after its first, like ``returns`` (key `airportReturns`; never in `returns`).
    var airportReturns: [String: [Date]]
    /// Each found airport's clock, like ``lastSeen`` (key `airportLastSeen`; never in `lastSeen`).
    var airportLastSeen: [String: Date]
    /// The airport trips that were layovers: token to the trip starts, earliest first (key `airportTransit`).
    var airportTransit: [String: [Date]]
    /// The flights flown, sorted (``PassportFlight/precedes(_:_:)``), one flight once.
    var flightList: [PassportFlight]
    /// The upcoming flights, sorted, one flight once.
    var upcomingList: [PassportFlight]
    /// The sealed backup's records of kinds this build does not know, each an object without its `id`.
    var keptRecords: [PassportJSONValue]
    /// Every top-level key this build does not know, as it was read.
    var unknownKeys: [String: PassportJSONValue]
    /// Entries refused because a cap was reached (an audit count; never encoded, never shown). A refusal
    /// inside a save that failed is counted again on the next try.
    public internal(set) var refusedCount = 0

    /// An empty passport.
    public init() {
        version = Self.currentVersion
        entries = [:]
        returns = [:]
        lastSeen = [:]
        airportReturns = [:]
        airportLastSeen = [:]
        airportTransit = [:]
        flightList = []
        upcomingList = []
        keptRecords = []
        unknownKeys = [:]
    }

    /// The most entries of `kind` a book keeps.
    public static func cap(for kind: AtlasDiscoveryKind) -> Int {
        switch kind {
        case .country: 300
        case .continent: 7
        case .ocean: 5
        case .sea: 250
        case .city: 20_000
        case .landmark: 5_000
        case .terrain: 20
        case .airport: 10_000
        }
    }

    // MARK: Reading

    /// Whether nothing has been visited yet (flights and kept records aside: ``holdsNothing``).
    public var isEmpty: Bool { entries.isEmpty }

    /// Whether the book holds nothing at all: no entry, no flight, no upcoming flight, no kept record and no key
    /// this build does not know.
    public var holdsNothing: Bool {
        entries.isEmpty && flightList.isEmpty && upcomingList.isEmpty && keptRecords.isEmpty && unknownKeys.isEmpty
    }

    /// When `token` of `kind` was first visited, or nil when it hasn't been.
    public func firstVisit(_ kind: AtlasDiscoveryKind, token: String) -> Date? {
        entries[kind]?[token]
    }

    /// How many of `kind` have been visited.
    public func count(of kind: AtlasDiscoveryKind) -> Int {
        entries[kind]?.count ?? 0
    }

    /// Every visited token of `kind`, with its first date.
    public func visits(of kind: AtlasDiscoveryKind) -> [String: Date] {
        entries[kind] ?? [:]
    }

    /// Every trip to the country `token`, earliest first: its first visit, then each return after
    /// ``tripGap`` or more away. Empty when it hasn't been visited.
    public func trips(inCountry token: String) -> [Date] {
        guard let first = entries[.country]?[token] else { return [] }
        return [first] + (returns[token] ?? [])
    }

    /// How many trips there are after the countries' first ones, in all.
    public var returnCount: Int {
        returns.values.reduce(0) { $0 + $1.count }
    }

    /// The last accepted fix in the country `token` (the trip rule's clock), or nil when it hasn't been visited.
    public func lastSeen(inCountry token: String) -> Date? {
        lastSeen[token]
    }

    /// Every trip after a country's first, as a country discovery at the trip's start, earliest first (the sealed
    /// backup carries these beside ``discoveries``). Bounded by ``maxReturns``.
    public var returnVisits: [AtlasDiscovery] {
        var all: [AtlasDiscovery] = []
        for (token, dates) in returns {
            for date in dates.prefix(Self.maxReturns) {
                all.append(AtlasDiscovery(kind: .country, token: token, at: date))
            }
        }
        return all.sorted { Self.precedes($0, $1) }
    }

    /// The book's stamps in visit order (World-Passport-Spec §6): an airport stamp for each trip through it (a
    /// layover's marked ``PassportStamp/isTransit``, World-Airports-Spec §4.2), a country stamp for each trip, one
    /// for each continent, ocean and sea at its first visit, and each special on the day its last continent or
    /// ocean was reached. Earliest first; on the same date in kind order (airport, country, continent, ocean, sea,
    /// the specials), then by token and trip, so a landing stamps the airport before the country and a first day
    /// in a continent stamps the country, then the continent. Bounded by the caps, ``maxReturns`` and
    /// ``maxAirportReturns``.
    public var stamps: [PassportStamp] {
        var all: [PassportStamp] = []
        for (token, first) in visits(of: .country) {
            all.append(PassportStamp(kind: .country, token: token, date: first))
            for (index, date) in (returns[token] ?? []).prefix(Self.maxReturns).enumerated() {
                all.append(PassportStamp(kind: .country, token: token, date: date, trip: index + 2))
            }
        }
        let once: [(AtlasDiscoveryKind, PassportStamp.Kind)] = [(.continent, .continent), (.ocean, .ocean), (.sea, .sea)]
        for (kind, stampKind) in once {
            for (token, date) in visits(of: kind) {
                all.append(PassportStamp(kind: stampKind, token: token, date: date))
            }
        }
        if let date = Self.completion(visits(of: .continent), of: AtlasContinent.allCases.map(\.rawValue)) {
            all.append(PassportStamp(kind: .allContinents, token: PassportStamp.Kind.allContinents.rawValue, date: date))
        }
        if let date = Self.completion(visits(of: .ocean), of: AtlasOcean.allCases.map(\.rawValue)) {
            all.append(PassportStamp(kind: .allOceans, token: PassportStamp.Kind.allOceans.rawValue, date: date))
        }
        all += airportStamps
        return all.sorted { Self.precedes($0, $1) }
    }

    /// Every entry as a discovery, earliest first (ties by kind, in ``AtlasDiscoveryKind`` order, then token).
    /// Bounded by the caps' sum.
    public var discoveries: [AtlasDiscovery] {
        var all: [AtlasDiscovery] = []
        for kind in AtlasDiscoveryKind.allCases {
            for (token, date) in visits(of: kind).prefix(Self.cap(for: kind)) {
                all.append(AtlasDiscovery(kind: kind, token: token, at: date))
            }
        }
        return all.sorted { Self.precedes($0, $1) }
    }

    // MARK: First visits

    /// The kind and token of each place `visit` names, in the fixed order of ``AtlasDiscoveryKind``
    /// (country, continent, ocean, sea, city, landmark, terrain): one of each kind but landmarks, of which the
    /// first ``AtlasVisit/maxLandmarks`` are taken in the visit's order. Tokens unchecked.
    public static func places(in visit: AtlasVisit) -> [(kind: AtlasDiscoveryKind, token: String)] {
        let before: [(AtlasDiscoveryKind, String?)] = [
            (.country, visit.countryCode), (.continent, visit.continent?.rawValue), (.ocean, visit.ocean?.rawValue),
            (.sea, visit.sea?.token), (.city, visit.city?.token)
        ]
        let landmarks: [(AtlasDiscoveryKind, String?)] = visit.landmarks.prefix(AtlasVisit.maxLandmarks)
            .map { (.landmark, $0) }
        let named = before + landmarks + [(.terrain, visit.terrain.rawValue)]
        return named.compactMap { kind, token in token.map { (kind: kind, token: $0) } }
    }

    /// The first visits `visit` would add at `date`, in the fixed order, without changing the book: the places
    /// it names with a valid token that the book does not hold yet, each once even when the visit names it
    /// twice (caps are applied by ``record(_:at:)``). At most ``maxDiscoveriesPerVisit``.
    public func newDiscoveries(in visit: AtlasVisit, at date: Date) -> [AtlasDiscovery] {
        guard date.timeIntervalSince1970.isFinite else { return [] }
        var seen = Set<String>(), found: [AtlasDiscovery] = []
        // Bounded: places(in:) names at most maxDiscoveriesPerVisit places.
        for place in Self.places(in: visit).prefix(Self.maxDiscoveriesPerVisit)
        where Self.isValidToken(place.token, of: place.kind) && firstVisit(place.kind, token: place.token) == nil {
            guard seen.insert(place.kind.rawValue + "/" + place.token).inserted else { continue }
            found.append(AtlasDiscovery(kind: place.kind, token: place.token, at: date))
        }
        return found
    }

    /// Records `visit` at `date` and returns only its first visits, in the fixed order (country, continent,
    /// ocean, sea, city, landmark, terrain). A first visit past its kind's cap is refused and counted. At most
    /// ``maxDiscoveriesPerVisit``. The visit's country also gets the trip rule: a fix ``tripGap`` or more after
    /// the last one there starts a trip (``trips(inCountry:)``), and every fix moves its clock on.
    public mutating func record(_ visit: AtlasVisit, at date: Date) -> [AtlasDiscovery] {
        let kept = recordFirstVisits(visit, at: date)
        if let code = visit.countryCode { noteTrip(inCountry: code, at: date) }
        return kept
    }

    /// The first-visit half of ``record(_:at:)``.
    private mutating func recordFirstVisits(_ visit: AtlasVisit, at date: Date) -> [AtlasDiscovery] {
        let candidates = newDiscoveries(in: visit, at: date)
        guard !candidates.isEmpty else { return [] }
        var kept: [AtlasDiscovery] = []
        for discovery in candidates.prefix(Self.maxDiscoveriesPerVisit) {
            guard count(of: discovery.kind) < Self.cap(for: discovery.kind) else {
                refusedCount += 1
                continue
            }
            entries[discovery.kind, default: [:]][discovery.token] = discovery.at
            kept.append(discovery)
        }
        return kept
    }

    /// The trip rule for one accepted fix in the country `code` at `date` (already in the book: a country refused
    /// at its cap has no trips). A fix ``tripGap`` or more after the last one there starts a trip, refused and
    /// counted past ``maxReturns``; every fix moves the clock on, never back.
    private mutating func noteTrip(inCountry code: String, at date: Date) {
        guard date.timeIntervalSince1970.isFinite, let first = entries[.country]?[code] else { return }
        let last = lastSeen[code] ?? returns[code]?.last ?? first
        if date.timeIntervalSince(last) >= Self.tripGap {
            if returnCount < Self.maxReturns {
                returns[code, default: []].append(date)
            } else {
                refusedCount += 1
            }
        }
        lastSeen[code] = max(last, date)
    }

    // MARK: Landmarks

    /// Whether `landmark` has been found.
    public func isFound(_ landmark: AtlasLandmark) -> Bool {
        firstVisit(.landmark, token: landmark.token) != nil
    }

    /// The landmarks of the city whose atlas token is `cityToken` that have been found, in `list`'s order
    /// (the city card's icons with names; the rest stay question marks).
    public func foundLandmarks(inCity cityToken: String, of list: WorldLandmarks) -> [AtlasLandmark] {
        guard count(of: .landmark) > 0 else { return [] }
        return list.landmarks(inCity: cityToken).filter { isFound($0) }
    }

    /// How many of the city's landmarks have been found ("2 of 6 found": the 6 is
    /// `list.landmarks(inCity:).count`).
    public func foundLandmarkCount(inCity cityToken: String, of list: WorldLandmarks) -> Int {
        foundLandmarks(inCity: cityToken, of: list).count
    }

    // MARK: Restoring

    /// The most entries a book holds: the caps' sum.
    public static var maxEntries: Int {
        AtlasDiscoveryKind.allCases.reduce(0) { $0 + cap(for: $1) }
    }

    /// A passport holding exactly `discoveries` (the entries the passport's sealed iCloud backup carried, one
    /// record each: a country and an airport one per trip), with `seen` the last fix in each country and
    /// `airportSeen` each airport's clock where the backup knew them, `transits` the airport trips that were
    /// layovers (kind `airport`, at the trip's start), the flights and upcoming flights, and `kept` the backup's
    /// records of kinds this build does not know (each an object without its `id`). Every token but a country's or
    /// an airport's is kept once with its earliest date; a country's or an airport's dates are its trips, each once,
    /// under the trip rule (``tripGap``), and an old backup's one date per country reads as one trip. A layover
    /// whose trip did not stand is left out, and the flights are kept one flight once. The list is refused whole,
    /// never trimmed, under the rules ``init(data:)`` applies to the same entries: more than ``maxEntries`` plus the
    /// trip caps is ``BookError/tooLarge``, a token that is not a token of its kind (or a date that is not finite, a
    /// clock or a layover for a place with no trip) is ``BookError/badToken(_:)``, more of a kind than its cap, or
    /// more trips or layovers than theirs, is ``BookError/overCap(_:)``, more flights than theirs is
    /// ``BookError/tooManyFlights``, and more kept records than ``maxKeptBackupRecords``, or one that is not an
    /// object, is ``BookError/tooLarge`` or ``BookError/malformed``. Bounded by the caps.
    public init(discoveries: [AtlasDiscovery], lastSeen seen: [String: Date] = [:],
                airportLastSeen airportSeen: [String: Date] = [:], transits: [AtlasDiscovery] = [],
                flights: [PassportFlight] = [], upcomingFlights: [PassportFlight] = [],
                keptBackupRecords kept: [PassportJSONValue] = []) throws {
        let most = Self.maxEntries + Self.maxReturns + Self.maxAirportReturns
        guard discoveries.count <= most else { throw BookError.tooLarge }
        var read: [AtlasDiscoveryKind: [String: Date]] = [:]
        var tripDates: [AtlasDiscoveryKind: [String: Set<Date>]] = [:]
        // Bounded: at most `most` discoveries (checked above).
        for discovery in discoveries.prefix(most) {
            let kind = discovery.kind
            guard Self.isValidToken(discovery.token, of: kind), discovery.at.timeIntervalSince1970.isFinite else {
                throw BookError.badToken(kind)
            }
            if Self.hasTrips(kind) {
                tripDates[kind, default: [:]][discovery.token, default: []].insert(discovery.at)
                guard (tripDates[kind]?.count ?? 0) <= Self.cap(for: kind) else { throw BookError.overCap(kind) }
                continue
            }
            var list = read[kind] ?? [:]
            list[discovery.token] = list[discovery.token].map { min($0, discovery.at) } ?? discovery.at
            guard list.count <= Self.cap(for: kind) else { throw BookError.overCap(kind) }
            read[kind] = list
        }
        let countryDates = tripDates[.country] ?? [:], airportDates = tripDates[.airport] ?? [:]
        guard seen.allSatisfy({ countryDates[$0.key] != nil && $0.value.timeIntervalSince1970.isFinite }) else {
            throw BookError.badToken(.country)
        }
        guard airportSeen.allSatisfy({ airportDates[$0.key] != nil && $0.value.timeIntervalSince1970.isFinite }) else {
            throw BookError.badToken(.airport)
        }
        guard transits.count <= Self.maxTransits else { throw BookError.overCap(.airport) }
        var marks: [String: [Date]] = [:]
        // Bounded: at most maxTransits (checked above).
        for transit in transits.prefix(Self.maxTransits) {
            guard transit.kind == .airport, airportDates[transit.token] != nil,
                  transit.at.timeIntervalSince1970.isFinite else { throw BookError.badToken(.airport) }
            marks[transit.token, default: []].append(transit.at)
        }
        guard flights.count <= Self.maxFlights, upcomingFlights.count <= Self.maxUpcomingFlights else {
            throw BookError.tooManyFlights
        }
        guard kept.count <= Self.maxKeptBackupRecords else { throw BookError.tooLarge }
        guard kept.allSatisfy({ $0.objectValue != nil }) else { throw BookError.malformed }
        let countries = try Self.tripLists(countryDates, seen: seen, kind: .country, maxLater: Self.maxReturns)
        let airports = try Self.tripLists(airportDates, seen: airportSeen, kind: .airport,
                                          maxLater: Self.maxAirportReturns)
        self.init()
        if !countries.firsts.isEmpty { read[.country] = countries.firsts }
        if !airports.firsts.isEmpty { read[.airport] = airports.firsts }
        (entries, returns, lastSeen) = (read, countries.later, countries.clocks)
        (airportReturns, airportLastSeen) = (airports.later, airports.clocks)
        airportTransit = standingTransits(marks).marks
        flightList = Self.merging(flights, into: [], cap: Self.maxFlights).list
        upcomingList = Self.merging(upcomingFlights, into: [], cap: Self.maxUpcomingFlights).list
        keptRecords = Self.keptOnce(kept)
    }

    /// Whether `kind` has trips (the 7-day rule): countries and airports.
    static func hasTrips(_ kind: AtlasDiscoveryKind) -> Bool {
        kind == .country || kind == .airport
    }

    /// The trips of the places `dates` holds (token to trip starts) under the trip rule: each one's first trip,
    /// its later trips, and its clock (`seen` where known, never before its latest trip). Throws
    /// ``BookError/overCap(_:)`` for more later trips than `maxLater`. Bounded by `kind`'s cap.
    static func tripLists(_ dates: [String: Set<Date>], seen: [String: Date], kind: AtlasDiscoveryKind,
                          maxLater: Int) throws
        -> (firsts: [String: Date], later: [String: [Date]], clocks: [String: Date]) {
        var firsts: [String: Date] = [:], later: [String: [Date]] = [:], clocks: [String: Date] = [:], total = 0
        // Bounded: at most cap(for: kind) places.
        for (token, starts) in dates.prefix(cap(for: kind)) {
            let trips = Self.trips(from: starts, presence: seen[token].map { [$0] } ?? [])
            guard let first = trips.first, let latest = trips.last else { continue }
            firsts[token] = first
            if trips.count > 1 { later[token] = Array(trips.dropFirst()) }
            total += trips.count - 1
            guard total <= maxLater else { throw BookError.overCap(kind) }
            clocks[token] = max(seen[token] ?? latest, latest)
        }
        return (firsts, later, clocks)
    }

    /// The trips that stand among `starts` (each date once, earliest first): a start stands unless a known
    /// presence (another start, or a last fix in `presence`) falls less than ``tripGap`` before it, since a
    /// fix then means the person had not been away. The earliest start always stands (a presence before it is
    /// ignored). Bounded by `starts` and `presence`.
    static func trips(from starts: Set<Date>, presence: [Date]) -> [Date] {
        let sorted = starts.sorted()
        guard let earliest = sorted.first else { return [] }
        let points = (sorted + presence.filter { $0 >= earliest }).sorted()
        var kept: [Date] = [], index = 0, previous: Date?
        // Bounded: by `starts`; the inner walk moves `index` through `points` once in all.
        for start in sorted {
            while index < points.count, points[index] < start {
                previous = points[index]
                index += 1
            }
            if let previous, start.timeIntervalSince(previous) < tripGap { continue }
            kept.append(start)
        }
        return kept
    }

    /// Merges `other` (a passport restored from the sealed backup) into this one by token, keeping the earliest
    /// date of each; a country's or an airport's trips are merged by date, each kept once, under the trip rule
    /// (``tripGap``: a trip either side shows began less than 7 days after a fix there is one trip, not two), and
    /// its clock is the later of the two. Layovers are kept where their trip stands; flights and upcoming flights
    /// are merged one flight once (``PassportFlight/isSameFlight(as:)``); kept records are kept once each; and a key
    /// this build does not know is added where this book has none. Returns how many entries, trips, layovers,
    /// flights or kept records were added or changed. New ones past a cap are refused and counted, earliest kept
    /// first. Bounded by the caps of `other`.
    public mutating func merge(_ other: PassportBook) -> Int {
        var changed = 0
        // Bounded: the kinds.
        for kind in AtlasDiscoveryKind.allCases where !Self.hasTrips(kind) {
            let incoming = other.visits(of: kind)
            guard !incoming.isEmpty else { continue }
            changed += merge(incoming, of: kind)
        }
        changed += mergeTrips(other, of: .country, later: \.returns, clocks: \.lastSeen, maxLater: Self.maxReturns)
        changed += mergeTrips(other, of: .airport, later: \.airportReturns, clocks: \.airportLastSeen,
                              maxLater: Self.maxAirportReturns)
        changed += mergeTransits(other)
        changed += mergeFlights(other)
        changed += mergeKept(other)
        // Bounded: at most maxUnknownKeys keys on each side.
        for (key, value) in other.unknownKeys.sorted(by: { $0.key < $1.key }).prefix(Self.maxUnknownKeys)
        where unknownKeys[key] == nil && unknownKeys.count < Self.maxUnknownKeys {
            unknownKeys[key] = value
        }
        return changed
    }

    /// Every trip of `token` of `kind` (a country or an airport), earliest first: its first visit, then the later
    /// trips `later` holds. Empty when it hasn't been visited.
    func tripStarts(_ kind: AtlasDiscoveryKind, token: String, later: KeyPath<PassportBook, [String: [Date]]>) -> [Date] {
        guard let first = entries[kind]?[token] else { return [] }
        return [first] + (self[keyPath: later][token] ?? [])
    }

    /// Merges `other`'s places of `kind` (a country or an airport) and their trips, kept at `later` and `clocks`;
    /// how many trips were added or moved earlier.
    private mutating func mergeTrips(_ other: PassportBook, of kind: AtlasDiscoveryKind,
                                     later: WritableKeyPath<PassportBook, [String: [Date]]>,
                                     clocks: WritableKeyPath<PassportBook, [String: Date]>, maxLater: Int) -> Int {
        let incoming = other.visits(of: kind), cap = Self.cap(for: kind)
        guard !incoming.isEmpty else { return 0 }
        var current = visits(of: kind), changed = 0
        var total = self[keyPath: later].values.reduce(0) { $0 + $1.count }
        let ordered = incoming.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        // Bounded: at most cap(for: kind) places.
        for (token, _) in ordered.prefix(cap) where Self.isValidToken(token, of: kind) {
            let mine = tripStarts(kind, token: token, later: later)
            guard !mine.isEmpty || current.count < cap else {
                refusedCount += 1
                continue
            }
            let clockList = [self[keyPath: clocks][token], other[keyPath: clocks][token]].compactMap { $0 }
            let theirs = other.tripStarts(kind, token: token, later: later)
            var merged = Self.trips(from: Set(mine).union(theirs), presence: clockList)
            let mineReturns = max(mine.count - 1, 0), room = maxLater - (total - mineReturns)
            if merged.count - 1 > room {
                refusedCount += merged.count - 1 - room
                merged = Array(merged.prefix(room + 1))
            }
            guard let first = merged.first, let latest = merged.last else { continue }
            total += merged.count - 1 - mineReturns
            let held = Set(mine)
            changed += merged.reduce(0) { $0 + (held.contains($1) ? 0 : 1) }
            current[token] = first
            self[keyPath: later][token] = merged.count > 1 ? Array(merged.dropFirst()) : nil
            self[keyPath: clocks][token] = (clockList + [latest]).max()
        }
        entries[kind] = current.isEmpty ? nil : current
        return changed
    }

    /// Merges one kind's entries; how many changed.
    private mutating func merge(_ incoming: [String: Date], of kind: AtlasDiscoveryKind) -> Int {
        let cap = Self.cap(for: kind)
        guard cap > 0 else { return 0 }
        var current = visits(of: kind), changed = 0
        let ordered = incoming.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        // Bounded: at most cap(for: kind) entries.
        for (token, date) in ordered.prefix(cap) where Self.isValidToken(token, of: kind) {
            if let existing = current[token] {
                guard date < existing else { continue }
                current[token] = date
                changed += 1
            } else if current.count < cap {
                current[token] = date
                changed += 1
            } else {
                refusedCount += 1
            }
        }
        entries[kind] = current.isEmpty ? nil : current
        return changed
    }

    // MARK: Bytes

    /// The versioned bytes (sorted keys, so the same book always encodes the same).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(self)
        guard data.count <= Self.maxEncodedBytes else { throw BookError.tooLarge }
        return data
    }

    /// The passport in `data`; throws a ``BookError`` when the bytes are not a passport this build reads.
    public init(data: Data) throws {
        guard data.count <= Self.maxEncodedBytes else { throw BookError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            self = try decoder.decode(PassportBook.self, from: data)
        } catch let error as BookError {
            throw error
        } catch {
            throw BookError.malformed
        }
    }

    /// The keys this build reads; every other top-level key is kept as it was read.
    static let knownKeys: Set<String> = Set(AtlasDiscoveryKind.allCases.map(\.rawValue)).union([
        "version", "returns", "lastSeen", "airportReturns", "airportLastSeen", "airportTransit", "flights",
        "upcomingFlights", "keptBackupRecords"
    ])

    /// Reads a book, refusing an unknown version, a kind over its cap, a bad token and a bad flight, and keeping
    /// every key it does not know (at most ``maxUnknownKeys``, in key order; one nested deeper than
    /// ``PassportJSONValue/maxDepth`` is left out).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let version = try container.decode(Int.self, forKey: Key("version"))
        guard version == Self.currentVersion else { throw BookError.unsupportedVersion(version) }
        var read: [AtlasDiscoveryKind: [String: Date]] = [:]
        // Bounded: the kinds.
        for kind in AtlasDiscoveryKind.allCases {
            let list = try container.decodeIfPresent([String: Date].self, forKey: Key(kind.rawValue)) ?? [:]
            guard list.count <= Self.cap(for: kind) else { throw BookError.overCap(kind) }
            guard list.keys.allSatisfy({ Self.isValidToken($0, of: kind) }) else { throw BookError.badToken(kind) }
            if !list.isEmpty { read[kind] = list }
        }
        let later = try container.decodeIfPresent([String: [Date]].self, forKey: Key("returns")) ?? [:]
        let seen = try container.decodeIfPresent([String: Date].self, forKey: Key("lastSeen")) ?? [:]
        let countries = read[.country] ?? [:]
        guard later.values.reduce(0, { $0 + $1.count }) <= Self.maxReturns else { throw BookError.overCap(.country) }
        guard later.keys.allSatisfy({ countries[$0] != nil }), seen.keys.allSatisfy({ countries[$0] != nil }) else {
            throw BookError.badToken(.country)
        }
        let airportLater = try container.decodeIfPresent([String: [Date]].self, forKey: Key("airportReturns")) ?? [:]
        let airportSeen = try container.decodeIfPresent([String: Date].self, forKey: Key("airportLastSeen")) ?? [:]
        let transit = try container.decodeIfPresent([String: [Date]].self, forKey: Key("airportTransit")) ?? [:]
        let airports = read[.airport] ?? [:]
        guard airportLater.values.reduce(0, { $0 + $1.count }) <= Self.maxAirportReturns,
              transit.values.reduce(0, { $0 + $1.count }) <= Self.maxTransits else { throw BookError.overCap(.airport) }
        guard airportLater.keys.allSatisfy({ airports[$0] != nil }), airportSeen.keys.allSatisfy({ airports[$0] != nil }),
              transit.keys.allSatisfy({ airports[$0] != nil }) else { throw BookError.badToken(.airport) }
        let flights = try container.decodeIfPresent([PassportFlight].self, forKey: Key("flights")) ?? []
        let upcoming = try container.decodeIfPresent([PassportFlight].self, forKey: Key("upcomingFlights")) ?? []
        guard flights.count <= Self.maxFlights, upcoming.count <= Self.maxUpcomingFlights else {
            throw BookError.tooManyFlights
        }
        let kept = try container.decodeIfPresent([PassportJSONValue].self, forKey: Key("keptBackupRecords")) ?? []
        guard kept.count <= Self.maxKeptBackupRecords else { throw BookError.tooLarge }
        guard kept.allSatisfy({ $0.objectValue != nil }) else { throw BookError.malformed }
        var unknown: [String: PassportJSONValue] = [:]
        let names = container.allKeys.filter { !Self.knownKeys.contains($0.stringValue) }
        // Bounded: at most maxUnknownKeys are read.
        for key in names.sorted(by: { $0.stringValue < $1.stringValue }).prefix(Self.maxUnknownKeys) {
            guard let value = try? container.decode(PassportJSONValue.self, forKey: key) else { continue }
            unknown[key.stringValue] = value
        }
        var dates: [String: Set<Date>] = [:], airportDates: [String: Set<Date>] = [:]
        // Bounded: by the country and airport caps (checked above).
        for (token, first) in countries {
            dates[token] = Set([first] + (later[token] ?? []))
        }
        for (token, first) in airports {
            airportDates[token] = Set([first] + (airportLater[token] ?? []))
        }
        let countryTrips = try Self.tripLists(dates, seen: seen, kind: .country, maxLater: Self.maxReturns)
        let airportTrips = try Self.tripLists(airportDates, seen: airportSeen, kind: .airport,
                                              maxLater: Self.maxAirportReturns)
        read[.country] = countryTrips.firsts.isEmpty ? nil : countryTrips.firsts
        read[.airport] = airportTrips.firsts.isEmpty ? nil : airportTrips.firsts
        self.init()
        (entries, returns, lastSeen) = (read, countryTrips.later, countryTrips.clocks)
        (airportReturns, airportLastSeen) = (airportTrips.later, airportTrips.clocks)
        airportTransit = standingTransits(transit).marks
        flightList = flights.sorted(by: PassportFlight.precedes)
        upcomingList = upcoming.sorted(by: PassportFlight.precedes)
        keptRecords = Self.keptOnce(kept)
        unknownKeys = unknown
    }

    /// Writes the version, each kind that has entries, the trips, layovers, flights and kept records that are
    /// there, and every key this build does not know, as it was read.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Self.currentVersion, forKey: Key("version"))
        // Bounded: the kinds.
        for kind in AtlasDiscoveryKind.allCases {
            guard let list = entries[kind], !list.isEmpty else { continue }
            try container.encode(list, forKey: Key(kind.rawValue))
        }
        if !returns.isEmpty { try container.encode(returns, forKey: Key("returns")) }
        if !lastSeen.isEmpty { try container.encode(lastSeen, forKey: Key("lastSeen")) }
        if !airportReturns.isEmpty { try container.encode(airportReturns, forKey: Key("airportReturns")) }
        if !airportLastSeen.isEmpty { try container.encode(airportLastSeen, forKey: Key("airportLastSeen")) }
        if !airportTransit.isEmpty { try container.encode(airportTransit, forKey: Key("airportTransit")) }
        if !flightList.isEmpty { try container.encode(flightList, forKey: Key("flights")) }
        if !upcomingList.isEmpty { try container.encode(upcomingList, forKey: Key("upcomingFlights")) }
        if !keptRecords.isEmpty { try container.encode(keptRecords, forKey: Key("keptBackupRecords")) }
        // Bounded: at most maxUnknownKeys.
        for (key, value) in unknownKeys where !Self.knownKeys.contains(key) {
            try container.encode(value, forKey: Key(key))
        }
    }

    /// Two books are equal when they hold the same entries, trips, clocks, layovers, flights, kept records and
    /// keys this build does not know (the refusal count is an audit, not content).
    public static func == (lhs: PassportBook, rhs: PassportBook) -> Bool {
        lhs.version == rhs.version && lhs.entries == rhs.entries && lhs.returns == rhs.returns
            && lhs.lastSeen == rhs.lastSeen && lhs.airportReturns == rhs.airportReturns
            && lhs.airportLastSeen == rhs.airportLastSeen && lhs.airportTransit == rhs.airportTransit
            && lhs.flightList == rhs.flightList && lhs.upcomingList == rhs.upcomingList
            && lhs.keptRecords == rhs.keptRecords && lhs.unknownKeys == rhs.unknownKeys
    }

    // MARK: Rules

    /// Whether `token` may be kept as a `kind`: not empty, at most ``maxTokenBytes``, a known rawValue for a
    /// continent, ocean or terrain, lowerCamel ASCII for a landmark (``AtlasLandmark/isValidToken(_:)``),
    /// printable ASCII without spaces for a country, sea or city, and the same of at most ``maxAirportTokenBytes``
    /// for an airport.
    public static func isValidToken(_ token: String, of kind: AtlasDiscoveryKind) -> Bool {
        guard !token.isEmpty, token.utf8.count <= maxTokenBytes else { return false }
        switch kind {
        case .continent: return AtlasContinent(rawValue: token) != nil
        case .ocean: return AtlasOcean(rawValue: token) != nil
        case .terrain: return AtlasTerrain(rawValue: token) != nil
        case .landmark: return AtlasLandmark.isValidToken(token)
        case .country, .sea, .city: return token.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
        case .airport:
            return token.utf8.count <= maxAirportTokenBytes && token.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F }
        }
    }

    /// The date `visits` held every one of `tokens`: the latest of their first visits, or nil while one is missing.
    private static func completion(_ visits: [String: Date], of tokens: [String]) -> Date? {
        var latest: Date?
        for token in tokens {
            guard let date = visits[token] else { return nil }
            latest = max(latest ?? date, date)
        }
        return latest
    }

    /// Earliest first, then kind order, then token, then trip.
    private static func precedes(_ lhs: PassportStamp, _ rhs: PassportStamp) -> Bool {
        guard lhs.date == rhs.date else { return lhs.date < rhs.date }
        let order = PassportStamp.Kind.allCases
        let left = order.firstIndex(of: lhs.kind) ?? 0, right = order.firstIndex(of: rhs.kind) ?? 0
        guard left == right else { return left < right }
        guard lhs.token == rhs.token else { return lhs.token < rhs.token }
        return lhs.trip < rhs.trip
    }

    /// Earliest first, then kind order, then token.
    private static func precedes(_ lhs: AtlasDiscovery, _ rhs: AtlasDiscovery) -> Bool {
        guard lhs.at == rhs.at else { return lhs.at < rhs.at }
        let order = AtlasDiscoveryKind.allCases
        let left = order.firstIndex(of: lhs.kind) ?? 0, right = order.firstIndex(of: rhs.kind) ?? 0
        guard left == right else { return left < right }
        return lhs.token < rhs.token
    }

    /// A coding key spelled by its string (the version and the kinds' frozen rawValues).
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
