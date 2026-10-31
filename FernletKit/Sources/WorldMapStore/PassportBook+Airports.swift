import Foundation

/// Airports in the passport (World-Airports-Spec §3, §4.2, §5): found by the app's own rules, stamped once a trip
/// under the passport's 7-day rule, and a trip that was a layover marked as transit.
extension PassportBook {
    /// How the app found the person at an airport (spec §3). Any of them finds a new airport; after that only a
    /// landing can start a new trip, so the home airport gets a stamp each time the person flies home, and just
    /// being at an airport (working there, living beside it) never fills the passport.
    public enum AirportFind: Sendable {
        /// Ten minutes inside a large airport's approved outline: finds it once, and then adds nothing.
        case dwell
        /// A ticket (Take a trip, spec §7) at the airport: finds it, and otherwise only moves its clock (leaving
        /// from an airport is not a trip to it).
        case ticket
        /// The first reading at an airport after a flight (spec §6.3): finds it, or starts a new trip after
        /// ``PassportBook/tripGap`` or more since its clock.
        case landing
    }

    // MARK: Reading

    /// Every trip through the airport `token`, earliest first: its first find, then each landing after
    /// ``tripGap`` or more away. Empty when it hasn't been found.
    public func trips(atAirport token: String) -> [Date] {
        tripStarts(.airport, token: token, later: \.airportReturns)
    }

    /// The airport's clock (its latest ticket or landing), or nil when it hasn't been found.
    public func lastSeen(atAirport token: String) -> Date? {
        airportLastSeen[token]
    }

    /// How many trips there are after the airports' first ones, in all.
    public var airportReturnCount: Int {
        airportReturns.values.reduce(0) { $0 + $1.count }
    }

    /// Every trip after an airport's first, as an airport discovery at the trip's start, earliest first (the
    /// sealed backup carries these beside ``discoveries``). Bounded by ``maxAirportReturns``.
    public var airportReturnVisits: [AtlasDiscovery] {
        var all: [AtlasDiscovery] = []
        // Bounded: at most maxAirportReturns trips in all.
        for (token, dates) in airportReturns {
            for date in dates.prefix(Self.maxAirportReturns) {
                all.append(AtlasDiscovery(kind: .airport, token: token, at: date))
            }
        }
        return all.sorted { ($0.at, $0.token) < ($1.at, $1.token) }
    }

    /// Whether the airport trip that began at `start` was a layover (its stamp says TRANSIT).
    public func isTransit(atAirport token: String, trip start: Date) -> Bool {
        airportTransit[token]?.contains(start) ?? false
    }

    /// How many airport trips are marked as layovers, in all.
    public var transitCount: Int {
        airportTransit.values.reduce(0) { $0 + $1.count }
    }

    /// Every layover, as an airport discovery at its trip's start, earliest first (the sealed backup carries
    /// these). Bounded by ``maxTransits``.
    public var transitVisits: [AtlasDiscovery] {
        var all: [AtlasDiscovery] = []
        // Bounded: at most maxTransits in all.
        for (token, dates) in airportTransit {
            for date in dates.prefix(Self.maxTransits) {
                all.append(AtlasDiscovery(kind: .airport, token: token, at: date))
            }
        }
        return all.sorted { ($0.at, $0.token) < ($1.at, $1.token) }
    }

    /// An airport stamp for each trip through each found airport, a layover's marked transit (unordered;
    /// ``stamps`` orders them). Bounded by the airport cap and ``maxAirportReturns``.
    var airportStamps: [PassportStamp] {
        var all: [PassportStamp] = []
        // Bounded: at most cap(for: .airport) airports and maxAirportReturns later trips in all.
        for (token, first) in visits(of: .airport) {
            let marks = Set(airportTransit[token] ?? [])
            let trips = [first] + (airportReturns[token] ?? []).prefix(Self.maxAirportReturns)
            for (index, date) in trips.enumerated() {
                all.append(PassportStamp(kind: .airport, token: token, date: date, trip: index + 1,
                                         isTransit: marks.contains(date)))
            }
        }
        return all
    }

    // MARK: Recording

    /// Records the person at the airport `token` (a ``WorldAirport/token``) at `date`, found by `find`, and
    /// returns what the passport announces, if anything: the airport's first visit when it is new (any `find`;
    /// refused and counted past the airport cap), or a new trip when a `landing` comes ``tripGap`` or more after
    /// the airport's clock (refused and counted past ``maxAirportReturns``). A ticket or a landing moves the clock
    /// on, never back; a dwell at an airport already found adds nothing (spec §3). A token that isn't an airport
    /// token, or a date that isn't finite, records nothing.
    ///
    /// A landing stamps only the airport (spec §4.2): the country and continent come from the visits once the
    /// person leaves the grounds, and nothing flown over is recorded at all (spec §6.1). Both are the app's rules.
    public mutating func recordAirport(token: String, at date: Date, by find: AirportFind) -> PassportEvent? {
        guard Self.isValidToken(token, of: .airport), date.timeIntervalSince1970.isFinite else { return nil }
        guard let first = entries[.airport]?[token] else {
            guard count(of: .airport) < Self.cap(for: .airport) else {
                refusedCount += 1
                return nil
            }
            entries[.airport, default: [:]][token] = date
            airportLastSeen[token] = date
            return .firstVisit(AtlasDiscovery(kind: .airport, token: token, at: date))
        }
        guard find != .dwell else { return nil }
        let last = airportLastSeen[token] ?? airportReturns[token]?.last ?? first
        defer { airportLastSeen[token] = max(last, date) }
        guard find == .landing, date.timeIntervalSince(last) >= Self.tripGap else { return nil }
        guard airportReturnCount < Self.maxAirportReturns else {
            refusedCount += 1
            return nil
        }
        airportReturns[token, default: []].append(date)
        let number = 1 + (airportReturns[token]?.count ?? 0)
        return .newTrip(PassportStamp(kind: .airport, token: token, date: date, trip: number))
    }

    /// Marks the airport trip that began at `start` as a layover (spec §4.2, §5: the person flew on without
    /// leaving the grounds), or clears the mark (they left after all). Returns whether anything changed: nothing
    /// does for a trip the book doesn't hold, and a new mark past ``maxTransits`` is refused and counted.
    @discardableResult
    public mutating func setTransit(_ isTransit: Bool, atAirport token: String, trip start: Date) -> Bool {
        guard trips(atAirport: token).contains(start) else { return false }
        var marks = airportTransit[token] ?? []
        if isTransit {
            guard !marks.contains(start) else { return false }
            guard transitCount < Self.maxTransits else {
                refusedCount += 1
                return false
            }
            marks.append(start)
            marks.sort()
        } else {
            guard let index = marks.firstIndex(of: start) else { return false }
            marks.remove(at: index)
        }
        airportTransit[token] = marks.isEmpty ? nil : marks
        return true
    }

    // MARK: Restoring

    /// The layover marks among `marks` whose trip stands in this book (each once, earliest first), at most
    /// ``maxTransits`` in all (airports in token order, so the cap keeps the same ones every time), and how many
    /// were left out by the cap. Bounded by the airport cap and ``maxTransits``.
    func standingTransits(_ marks: [String: [Date]]) -> (marks: [String: [Date]], dropped: Int) {
        var kept: [String: [Date]] = [:], total = 0, dropped = 0
        // Bounded: at most cap(for: .airport) airports, each mark list read once.
        for (token, dates) in marks.sorted(by: { $0.key < $1.key }).prefix(Self.cap(for: .airport)) {
            let starts = Set(trips(atAirport: token))
            let standing = Set(dates.prefix(Self.maxTransits)).filter { starts.contains($0) }.sorted()
            let room = max(Self.maxTransits - total, 0)
            dropped += max(standing.count - room, 0)
            let taken = Array(standing.prefix(room))
            guard !taken.isEmpty else { continue }
            kept[token] = taken
            total += taken.count
        }
        return (kept, dropped)
    }

    /// Merges `other`'s layover marks once the trips are merged: a mark either side holds is kept where its trip
    /// stands. How many marks were added.
    mutating func mergeTransits(_ other: PassportBook) -> Int {
        var union = airportTransit
        // Bounded: at most cap(for: .airport) airports.
        for (token, dates) in other.airportTransit.prefix(Self.cap(for: .airport)) {
            union[token, default: []] += dates.prefix(Self.maxTransits)
        }
        let merged = standingTransits(union)
        var added = 0
        // Bounded: at most maxTransits marks.
        for (token, dates) in merged.marks {
            let held = Set(airportTransit[token] ?? [])
            added += dates.filter { !held.contains($0) }.count
        }
        airportTransit = merged.marks
        refusedCount += merged.dropped
        return added
    }
}
