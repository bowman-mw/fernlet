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
