import Foundation

/// What adding one file's flights would do to the passport (World-Airports-Spec §9.4, §9.5): the flights as
/// passport records, how many of them the passport already holds, and what Undo takes back.
///
/// Worked out before anything is written, so the summary sheet can say "3 flights Fernlet saw, kept once"; the
/// app adds ``flights`` with ``PassportBook/addFlights(_:)`` and Undo calls
/// ``PassportBook/removeSource(_:fromFlightsMatching:)`` with ``undoFlights``. Imported flights never stamp an
/// airport or a country and never lift fog (§9.5): they are records only.
public nonisolated struct FlightImportPlan: Equatable, Sendable {
    /// The file's flights as passport records, from `source`.
    public let flights: [PassportFlight]
    /// The source they come from (Flighty, or the calendar's look back).
    public let source: PassportFlight.Sources
    /// How many of them are flights Fernlet saw itself (kept once, with the file as a second source).
    public let alreadySeen: Int
    /// How many of them were already imported (an earlier file or the calendar), kept once.
    public let alreadyImported: Int
    /// The flights whose record in the passport doesn't carry `source` yet: Undo takes `source` off exactly these,
    /// so a flight the passport held before keeps the sources it had.
    public let undoFlights: [PassportFlight]

    /// The plan for `records` read from `source`, against `book`. A record with no departure time (a date only)
    /// leaves at noon, local to its departure airport, with its times marked unsure; a record whose codes or times
    /// break ``PassportFlight``'s rules is left out. Bounded by ``PassportBook/maxFlights``.
    public init(records: [FlightRecord], source: PassportFlight.Sources, airports: some FlightAirportLookup,
                book: PassportBook) {
        let flights = records.prefix(PassportBook.maxFlights).compactMap {
            Self.flight(from: $0, source: source, airports: airports)
        }
        var byRoute: [String: [PassportFlight]] = [:]
        // Bounded: at most maxFlights flights in the book.
        for held in book.flights { byRoute[held.route, default: []].append(held) }
        var seen = 0, imported = 0, undo: [PassportFlight] = []
        // Bounded: at most maxFlights flights; each looks only through its own route's.
        for flight in flights {
            guard let held = byRoute[flight.route]?.first(where: { $0.isSameFlight(as: flight) }) else {
                undo.append(flight)
                continue
            }
            if held.sources.contains(.fernlet) { seen += 1 } else { imported += 1 }
            if !held.sources.contains(source) { undo.append(flight) }
        }
        self.flights = flights
        self.source = source
        alreadySeen = seen
        alreadyImported = imported
        undoFlights = undo
    }

    /// The flights the passport doesn't hold yet.
    public var newFlights: Int { flights.count - alreadySeen - alreadyImported }

    /// `record` as a passport flight from `source`, or nil where it breaks the rules.
    static func flight(from record: FlightRecord, source: PassportFlight.Sources,
                       airports: some FlightAirportLookup) -> PassportFlight? {
        let departure = record.departure ?? noon(of: record.day, in: airports.timeZone(iata: record.from))
        guard let departure else { return nil }
        return PassportFlight(from: record.from, to: record.to, departure: departure, arrival: record.arrival,
                              sources: source, timesUnsure: record.timesUnsure || record.departure == nil)
    }

    /// Noon on `day` in `zone` (UTC with no zone).
    static func noon(of day: FlightDay, in zone: TimeZone?) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))
    }
}

extension PassportBook {
    /// Takes `sources` off every flown flight that is the same flight as one of `flights` (an import's Undo,
    /// spec §9.4): a flight left with no source is removed, and one another source also has keeps that source
    /// alone. Returns how many flights were removed. Bounded by ``maxFlights``.
    @discardableResult
    public mutating func removeSource(_ sources: PassportFlight.Sources,
                                      fromFlightsMatching flights: [PassportFlight]) -> Int {
        var byRoute: [String: [PassportFlight]] = [:]
        // Bounded: at most maxFlights flights.
        for flight in flights.prefix(Self.maxFlights) { byRoute[flight.route, default: []].append(flight) }
        let before = flightList.count
        flightList = flightList.compactMap { held in
            guard byRoute[held.route]?.contains(where: { $0.isSameFlight(as: held) }) == true else { return held }
            return held.removing(sources)
        }
        return before - flightList.count
    }
}
