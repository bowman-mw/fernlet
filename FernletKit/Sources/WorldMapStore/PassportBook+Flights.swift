import Foundation

/// Flights in the passport (World-Airports-Spec §8–§10): every flight flown, Fernlet's own and imported, one
/// flight once; the calendar's upcoming flights, kept for their day; and the sealed backup's records of kinds this
/// build does not know (§11). Flights never stamp an airport or a country and never lift fog (§9.5): they are only
/// records.
extension PassportBook {
    /// Every flight flown, earliest departure first.
    public var flights: [PassportFlight] { flightList }

    /// Every upcoming flight (from the calendar, spec §10.6), earliest departure first.
    public var upcomingFlights: [PassportFlight] { upcomingList }

    /// The sealed backup's records of kinds this build does not know, each an object without its `id`, kept so
    /// every backup this build writes carries them again (spec §11). Never read for their meaning.
    public var keptBackupRecords: [PassportJSONValue] { keptRecords }

    /// The flown flight that is the same flight as `flight` (``PassportFlight/isSameFlight(as:)``), or nil.
    /// Bounded by ``maxFlights``.
    public func flight(matching flight: PassportFlight) -> PassportFlight? {
        flightList.first { $0.isSameFlight(as: flight) }
    }

    /// Adds `incoming` to the flights flown under the one-flight rule (spec §9.3): a flight already held (same
    /// airports, departures within ``PassportFlight/sameFlightWindow``) is merged with it (every source, the
    /// richer record's times), and any other is added, refused and counted past ``maxFlights``. An upcoming
    /// calendar flight that is the same flight as one of `incoming` leaves the upcoming list and joins it: Fernlet
    /// saw it land, or the person added it, which is the trip's confirmation (owner 2026-11-19). Returns how many
    /// flights were added or changed. Bounded by ``maxFlights``.
    @discardableResult
    public mutating func addFlights(_ incoming: [PassportFlight]) -> Int {
        let result = Self.merging(incoming + takeUpcoming(matching: incoming), into: flightList, cap: Self.maxFlights)
        flightList = result.list
        refusedCount += result.refused
        return result.changed
    }

    /// Removes and returns every upcoming flight that is the same flight as one of `flights`. Bounded by
    /// ``maxUpcomingFlights`` upcoming flights, each looking only through its own route's.
    private mutating func takeUpcoming(matching flights: [PassportFlight]) -> [PassportFlight] {
        guard !upcomingList.isEmpty, !flights.isEmpty else { return [] }
        let byRoute = Dictionary(grouping: flights.prefix(Self.maxFlights), by: \.route)
        let taken = upcomingList.filter { planned in
            byRoute[planned.route]?.contains { $0.isSameFlight(as: planned) } ?? false
        }
        guard !taken.isEmpty else { return [] }
        upcomingList.removeAll { taken.contains($0) }
        return taken
    }

    /// Removes `sources` from every flight and upcoming flight ("Remove imported flights", spec §9.5): a flight
    /// left with no source is removed, and one another source also has is kept with that source alone. Returns
    /// how many flights were removed.
    @discardableResult
    public mutating func removeSource(_ sources: PassportFlight.Sources) -> Int {
        let before = flightList.count + upcomingList.count
        flightList = flightList.compactMap { $0.removing(sources) }.sorted(by: PassportFlight.precedes)
        upcomingList = upcomingList.compactMap { $0.removing(sources) }.sorted(by: PassportFlight.precedes)
        return before - flightList.count - upcomingList.count
    }

    /// Replaces the upcoming flights with `flights` (a calendar look's, spec §10.6), one flight once, refused and
    /// counted past ``maxUpcomingFlights``. Returns whether the list changed.
    @discardableResult
    public mutating func setUpcomingFlights(_ flights: [PassportFlight]) -> Bool {
        let result = Self.merging(flights, into: [], cap: Self.maxUpcomingFlights)
        refusedCount += result.refused
        guard result.list != upcomingList else { return false }
        upcomingList = result.list
        return true
    }

    /// Keeps a calendar look's flights (spec §10.6, amended by the owner 2026-11-19: "needs confirmation of a trip";
    /// a calendar flight may be a friend's, kept to pick them up). A calendar flight is never flown on its own: one
    /// that is the same flight as a flight already flown joins it (the calendar among its sources), and every other
    /// one replaces the upcoming list, including those that left inside the look's window, which wait there for
    /// the trip's confirmation (``addFlights(_:)``, from Fernlet's own landing) and lapse when a later look's window
    /// has passed them. Returns whether anything changed. Bounded by ``maxFlights``.
    @discardableResult
    public mutating func keepCalendarFlights(_ flights: [PassportFlight]) -> Bool {
        let byRoute = Dictionary(grouping: flightList, by: \.route)
        let isFlown: (PassportFlight) -> Bool = { flight in
            byRoute[flight.route]?.contains { $0.isSameFlight(as: flight) } ?? false
        }
        let window = flights.prefix(Self.maxFlights)
        let joined = Self.merging(window.filter(isFlown), into: flightList, cap: Self.maxFlights)
        flightList = joined.list
        refusedCount += joined.refused
        let replaced = setUpcomingFlights(window.filter { !isFlown($0) })
        return joined.changed > 0 || replaced
    }

    /// Moves every flight flown that came from the calendar alone (``PassportFlight/isCalendarOnly``) and left at or
    /// after `since` to the upcoming list, where it waits like any unconfirmed calendar flight and lapses at the
    /// next look: the upgrade from builds that counted calendar flights as flown without proof (owner 2026-11-19).
    /// Nothing is deleted here (past ``maxUpcomingFlights`` a flight is refused and counted, as any upcoming one).
    /// Returns the flights moved. Bounded by ``maxFlights``.
    @discardableResult
    public mutating func demoteCalendarOnlyFlights(since: Date) -> [PassportFlight] {
        let demoted = flightList.filter { $0.isCalendarOnly && $0.departure >= since }
        guard !demoted.isEmpty else { return [] }
        flightList.removeAll { $0.isCalendarOnly && $0.departure >= since }
        let result = Self.merging(demoted, into: upcomingList, cap: Self.maxUpcomingFlights)
        upcomingList = result.list
        refusedCount += result.refused
        return demoted
    }

    // MARK: Merging

    /// `list` with `incoming` merged in under the one-flight rule, sorted; how many were added or changed, and how
    /// many were refused past `cap`. Incoming flights are taken earliest first, so the same ones are kept at the
    /// cap every time. Bounded by `cap` and ``maxFlights``.
    static func merging(_ incoming: [PassportFlight], into list: [PassportFlight], cap: Int)
        -> (list: [PassportFlight], changed: Int, refused: Int) {
        guard !incoming.isEmpty else { return (list, 0, 0) }
        var list = Array(list.prefix(cap)), changed = 0, refused = 0
        var byRoute: [String: [Int]] = [:]
        // Bounded: at most `cap` flights.
        for (index, flight) in list.enumerated() {
            byRoute[flight.route, default: []].append(index)
        }
        // Bounded: at most maxFlights incoming; each looks only through its own route's flights.
        for flight in incoming.prefix(maxFlights).sorted(by: PassportFlight.precedes) {
            if let index = byRoute[flight.route]?.first(where: { list[$0].isSameFlight(as: flight) }) {
                let merged = list[index].merged(with: flight)
                guard merged != list[index] else { continue }
                list[index] = merged
                changed += 1
            } else if list.count < cap {
                byRoute[flight.route, default: []].append(list.count)
                list.append(flight)
                changed += 1
            } else {
                refused += 1
            }
        }
        return (list.sorted(by: PassportFlight.precedes), changed, refused)
    }

    /// Merges `other`'s flights and upcoming flights; how many were added or changed.
    mutating func mergeFlights(_ other: PassportBook) -> Int {
        let flown = Self.merging(other.flightList, into: flightList, cap: Self.maxFlights)
        let upcoming = Self.merging(other.upcomingList, into: upcomingList, cap: Self.maxUpcomingFlights)
        flightList = flown.list
        upcomingList = upcoming.list
        refusedCount += flown.refused + upcoming.refused
        return flown.changed + upcoming.changed
    }

    // MARK: Kept records

    /// Merges `other`'s kept records, each once; how many were added (refused and counted past
    /// ``maxKeptBackupRecords``).
    mutating func mergeKept(_ other: PassportBook) -> Int {
        guard !other.keptRecords.isEmpty else { return 0 }
        var held = Set(keptRecords), added: [PassportJSONValue] = []
        // Bounded: at most maxKeptBackupRecords.
        for record in other.keptRecords.prefix(Self.maxKeptBackupRecords)
        where record.objectValue != nil && !held.contains(record) {
            guard keptRecords.count + added.count < Self.maxKeptBackupRecords else {
                refusedCount += 1
                continue
            }
            held.insert(record)
            added.append(record)
        }
        guard !added.isEmpty else { return 0 }
        keptRecords = Self.keptOnce(keptRecords + added)
        return added.count
    }

    /// `records` each once, at most ``maxKeptBackupRecords``, in the order of their sorted-key JSON, so the same
    /// records always encode the same.
    static func keptOnce(_ records: [PassportJSONValue]) -> [PassportJSONValue] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var seen = Set<PassportJSONValue>(), keyed: [(key: String, record: PassportJSONValue)] = []
        // Bounded: at most maxKeptBackupRecords.
        for record in records.prefix(maxKeptBackupRecords) where seen.insert(record).inserted {
            let key = (try? encoder.encode(record)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            keyed.append((key, record))
        }
        return keyed.sorted { $0.key < $1.key }.map(\.record)
    }
}
