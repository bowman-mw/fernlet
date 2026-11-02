import Foundation

/// A calendar flight leaving today from one airport (World-Airports-Spec §10.7): only where it goes and when it
/// leaves, for the blue button's "Trip to Honolulu" and the ticket it fills in. Never in a widget or notification.
public nonisolated struct CalendarFlightToday: Equatable, Sendable {
    /// The arrival airport's IATA code.
    public let destination: String
    /// When it leaves (UTC).
    public let departure: Date
}

/// The "Airports and flights" switch's side of the passport (World-Airports-Spec §11): deleting what it keeps,
/// and the calendar's flight for today at an airport.
extension PassportBook {
    /// "Delete what's kept" after the switch goes off: every airport visit, airport trip, layover mark, flight
    /// flown and upcoming flight goes. Countries, cities, landmarks and everything else stay, and so do the
    /// sealed backup's records of kinds this build doesn't know. Returns how many airports and flights went.
    @discardableResult
    public mutating func forgetAirportsAndFlights() -> Int {
        let removed = count(of: .airport) + flightList.count + upcomingList.count
        entries[.airport] = nil
        airportReturns = [:]
        airportLastSeen = [:]
        airportTransit = [:]
        flightList = []
        upcomingList = []
        return removed
    }

    /// Whether the book keeps any airport or flight (the switch asks to delete them only then).
    public var holdsAirportsOrFlights: Bool {
        count(of: .airport) > 0 || !flightList.isEmpty || !upcomingList.isEmpty
    }

    /// The calendar flight that says the person is in the air at `now` when the phone can't (no GPS in the cabin, owner
    /// 2026-11-02): one with sure times that has left and not yet arrived, leaving the airport `lastAirport` (an IATA
    /// code) the person was last known to be at, with no reading heard since it left. People keep the flights of those
    /// they're picking up in their calendars, so a flight from anywhere else, or with the person last seen anywhere
    /// but an airport, says nothing. Any reading since it left overrules it, so a delayed or missed flight goes back to
    /// the map. A flight that has left may already have moved to the flights flown, so both lists are read: the newest
    /// few of each, which is bounded.
    public func calendarFlightInTheAir(now: Date, lastReading: Date?, lastAirport: String?) -> PassportFlight? {
        guard let lastAirport else { return nil }
        return (flightList.suffix(Self.maxFlightsWeighedInTheAir) + upcomingList.prefix(Self.maxFlightsWeighedInTheAir)).first { flight in
            guard flight.from == lastAirport, flight.sources.contains(.calendar), !flight.timesUnsure, let arrival = flight.arrival,
                  flight.departure <= now, now < arrival else { return false }
            return lastReading.map { $0 < flight.departure } ?? true
        }
    }

    /// Whether the calendar has a flight leaving the airport `iata` within ``nextFlightWindow`` after `now`: what makes
    /// a landing there a layover at once. Bounded by ``maxUpcomingFlights``.
    public func calendarFlightLeaves(_ iata: String, now: Date) -> Bool {
        upcomingList.contains { flight in
            flight.from == iata && flight.sources.contains(.calendar) && flight.departure > now
                && flight.departure.timeIntervalSince(now) <= Self.nextFlightWindow
        }
    }

    /// How soon a flight must leave to count as the next one of a layover, not a later trip's.
    public static let nextFlightWindow: TimeInterval = 24 * 60 * 60

    /// How many flights of each list ``calendarFlightInTheAir(now:lastReading:lastAirport:)`` weighs.
    static let maxFlightsWeighedInTheAir = 16

    /// The earliest upcoming calendar flight leaving the airport `iata` later today, today being the day `now`
    /// falls on in `zone` (the departure airport's), or nil. Bounded by ``maxUpcomingFlights``.
    public func calendarFlightToday(from iata: String, now: Date, in zone: TimeZone) -> CalendarFlightToday? {
        let today = FlightDay(now, in: zone)
        let flight = upcomingList.first { flight in
            flight.from == iata && flight.sources.contains(.calendar) && flight.departure > now
                && FlightDay(flight.departure, in: zone) == today
        }
        return flight.map { CalendarFlightToday(destination: $0.to, departure: $0.departure) }
    }
}
