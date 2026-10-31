import Foundation

/// An import planned from flights already made (World-Airports-Spec §10.5): the calendar's look hands over
/// passport flights carrying their event hashes, which ``FlightImportPlan/init(records:source:airports:book:)``
/// (records only) would drop.
extension FlightImportPlan {
    /// The plan for `flights` from `source`, against `book`: the same counts and Undo list as a file's plan. At
    /// most ``PassportBook/maxFlights`` flights are taken.
    public init(flights: [PassportFlight], source: PassportFlight.Sources, book: PassportBook) {
        let taken = Array(flights.prefix(PassportBook.maxFlights))
        let byRoute = Self.byRoute(book.flights)
        var seen = 0, imported = 0, undo: [PassportFlight] = []
        // Bounded: at most maxFlights flights; each looks only through its own route's.
        for flight in taken {
            guard let held = byRoute[flight.route]?.first(where: { $0.isSameFlight(as: flight) }) else {
                undo.append(flight)
                continue
            }
            if held.sources.contains(.fernlet) { seen += 1 } else { imported += 1 }
            if !held.sources.contains(source) { undo.append(flight) }
        }
        self.flights = taken
        self.source = source
        alreadySeen = seen
        alreadyImported = imported
        undoFlights = undo
    }

    /// `flights` grouped by route (``PassportFlight/route``), at most ``PassportBook/maxFlights``.
    static func byRoute(_ flights: [PassportFlight]) -> [String: [PassportFlight]] {
        var byRoute: [String: [PassportFlight]] = [:]
        // Bounded: at most maxFlights flights.
        for flight in flights.prefix(PassportBook.maxFlights) { byRoute[flight.route, default: []].append(flight) }
        return byRoute
    }
}
