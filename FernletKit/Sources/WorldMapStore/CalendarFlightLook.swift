import CryptoKit
import Foundation

/// One look through the calendar for flights (World-Airports-Spec §10.4–§10.6), on values alone: the events a
/// reader handed over, read by ``CalendarFlightParser`` and sorted into flights already flown and flights still
/// to come. Nothing from an event that isn't a flight is kept, and a flight keeps only its airports, its times,
/// the calendar as its source and the salted hash of the event's identifier (``PassportFlight/eventHash``).
///
/// - **The first look** (§10.5) reads from ``firstLookYear`` to ``watchAhead`` from now
///   (``firstLookWindow(now:)``); its past flights are an import (``plan(against:)``, the same summary and
///   confirm as a Flighty file) and its upcoming ones go to ``PassportBook/setUpcomingFlights(_:)``.
/// - **Each later look** (§10.6, "keep watching; option a") reads from ``watchBehind`` ago to ``watchAhead``
///   from now (``watchWindow(now:)``).
/// - **The windows** are cut into pieces of at most ``maxPredicateSpan`` (EventKit's predicates span at most four
///   years; ``chunks(of:)``), and a look reads at most ``maxEvents`` events in all.
///
/// A flight departing at or before `now` is flown; one departing later is upcoming. An all-day event's flight
/// leaves at noon at its departure airport, its times marked unsure (``FlightImportPlan``'s rule).
public nonisolated struct CalendarFlightLook: Equatable, Sendable {
    /// The most events one look reads (spec §10.6).
    public static let maxEvents = 50_000
    /// The longest span one EventKit predicate may cover: four years (less a day, so a leap day never pushes a
    /// piece past EventKit's own limit).
    public static let maxPredicateSpan: TimeInterval = (4 * 365 - 1) * 24 * 60 * 60
    /// The year the first look reads back to (the summary's "Looked back to 2019").
    public static let firstLookYear = 2019
    /// How far back each later look reads (spec §10.6: 2 days ago).
    public static let watchBehind: TimeInterval = 2 * 24 * 60 * 60
    /// How far ahead every look reads (spec §10.6: 60 days ahead).
    public static let watchAhead: TimeInterval = 60 * 24 * 60 * 60
    /// The most pieces a window is cut into (a bound: 2019 to 60 days from now is three).
    static let maxChunks = 16

    /// The flights already flown, from the calendar, one flight once, earliest first.
    public let flown: [PassportFlight]
    /// The flights still to come, from the calendar, one flight once, earliest first.
    public let upcoming: [PassportFlight]
    /// The flight events whose airports couldn't be read (the summary's "3 flight events with no airport codes").
    public let noAirportCodes: Int
    /// How many airports the flights touch.
    public let airportCount: Int
    /// The first and last year the flights leave in (local to each departure airport), or nil with none.
    public let years: ClosedRange<Int>?

    /// Reads `events` (at most ``maxEvents``) with `airports`, hashing each event's identifier under `salt`;
    /// `now` splits flown from upcoming, and `deviceTimeZone` is the zone EventKit used for floating and all-day
    /// events.
    public init(events: [CalendarFlightEvent], airports: some FlightAirportLookup, salt: SymmetricKey, now: Date,
                deviceTimeZone: TimeZone = .current) {
        var found: [PassportFlight] = [], noCodes = 0, years: [Int] = []
        // Bounded: at most maxEvents events.
        for event in events.prefix(Self.maxEvents) {
            switch CalendarFlightParser.read(event, airports: airports, salt: salt, deviceTimeZone: deviceTimeZone) {
            case .flight(let calendar):
                guard let flight = Self.passportFlight(calendar, airports: airports) else { continue }
                found.append(flight)
                years.append(calendar.flight.day.year)
            case .skipped(.noRoute):
                noCodes += 1
            case .skipped(.notAFlight), .skipped(.noFlightNumber):
                continue
            }
        }
        let once = PassportBook.merging(found, into: [], cap: PassportBook.maxFlights).list
        flown = once.filter { $0.departure <= now }
        upcoming = Array(once.filter { $0.departure > now }.prefix(PassportBook.maxUpcomingFlights))
        noAirportCodes = noCodes
        airportCount = Set(once.flatMap { [$0.from, $0.to] }).count
        self.years = years.min().flatMap { first in years.max().map { first...$0 } }
    }

    /// `calendar` as a passport flight from the calendar, carrying its event hash; nil where it breaks
    /// ``PassportFlight``'s rules.
    static func passportFlight(_ calendar: CalendarFlight, airports: some FlightAirportLookup) -> PassportFlight? {
        let record = calendar.flight
        let departure = record.departure
            ?? FlightImportPlan.noon(of: record.day, in: airports.timeZone(iata: record.from))
        guard let departure else { return nil }
        return PassportFlight(from: record.from, to: record.to, departure: departure, arrival: record.arrival,
                              sources: .calendar, timesUnsure: record.timesUnsure || record.departure == nil,
                              eventHash: calendar.eventHash)
    }

    // MARK: The summary (§10.5)

    /// The flown flights as an import against `book` (what the passport already holds, and what Undo takes back).
    public func plan(against book: PassportBook) -> FlightImportPlan {
        FlightImportPlan(flights: flown, source: .calendar, book: book)
    }

    /// How many flown flights the passport already holds from a Flighty file, and how many only as flights
    /// Fernlet saw (the summary's "9 from your Flighty file and 2 Fernlet saw"). A flight held from both counts
    /// as Flighty's. Bounded by ``PassportBook/maxFlights``.
    public func alreadyHeld(in book: PassportBook) -> (fromFlighty: Int, fernletSaw: Int) {
        let byRoute = FlightImportPlan.byRoute(book.flights)
        var fromFlighty = 0, fernletSaw = 0
        // Bounded: at most maxFlights flown flights; each looks only through its own route's.
        for flight in flown {
            guard let held = byRoute[flight.route]?.first(where: { $0.isSameFlight(as: flight) }) else { continue }
            if held.sources.contains(.flighty) {
                fromFlighty += 1
            } else if held.sources.contains(.fernlet) {
                fernletSaw += 1
            }
        }
        return (fromFlighty, fernletSaw)
    }

    // MARK: Windows

    /// The first look's window: 1 January ``firstLookYear`` (UTC) to ``watchAhead`` from `now`.
    public static func firstLookWindow(now: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        let start = calendar.date(from: DateComponents(year: firstLookYear, month: 1, day: 1)) ?? now
        return DateInterval(start: min(start, now), end: now.addingTimeInterval(watchAhead))
    }

    /// Each later look's window: ``watchBehind`` ago to ``watchAhead`` from `now`.
    public static func watchWindow(now: Date) -> DateInterval {
        DateInterval(start: now.addingTimeInterval(-watchBehind), end: now.addingTimeInterval(watchAhead))
    }

    /// `window` cut into back-to-back pieces of at most ``maxPredicateSpan``, earliest first (at most
    /// ``maxChunks``; a longer window is cut short at its start's end).
    public static func chunks(of window: DateInterval) -> [DateInterval] {
        var pieces: [DateInterval] = [], start = window.start
        // Bounded: at most maxChunks pieces.
        while start < window.end, pieces.count < maxChunks {
            let end = min(start.addingTimeInterval(maxPredicateSpan), window.end)
            pieces.append(DateInterval(start: start, end: end))
            start = end
        }
        return pieces
    }
}
