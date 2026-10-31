import Foundation
import WorldMapStore

/// Take a trip on the store (World-Airports-Spec §5, §7, §10.7): what the blue button's trip row and the airport's
/// card read, the ticket's suggestions and starting values, Sprout's boarding pass, and today's calendar flight at
/// the airport. Everything is read on this iPhone; the destination is kept only in the flight keeper's sealed
/// vault state (``WorldFlightKeeper/tripFile``). **A decoy** offers no trip, opens no ticket or pass, and reads no
/// calendar flight; with "Airports and flights" off there is no trip row either.
extension FernletStore {
    /// Whether Take a trip is offered: never in a decoy, nor with "Airports and flights" off.
    var worldMayTakeTrip: Bool {
        !duressSessionActive && keepsWorldAirportsAndFlights()
    }

    /// The airport whose grounds hold the person, by name, for the blue button's card (nil while flying or in a decoy).
    var worldQuickStartAirportName: String? {
        worldCurrentAirport.map { WorldAirportCopy.name($0) }
    }

    /// The airport whose grounds hold the person, from the bundled list.
    var worldCurrentAirport: WorldAirport? {
        let flights = worldLocation.flights
        guard !duressSessionActive, !flights.isFlying, let token = flights.currentAirport else { return nil }
        return flights.airportsShelf.pack()?.airport(token: token)
    }

    /// The trip row: "Take a trip", or "End trip · London" while one is on; nil where it isn't offered.
    var worldQuickStartTripOption: WorldQuickStartOption? {
        guard worldMayTakeTrip else { return nil }
        let flights = worldLocation.flights
        guard flights.isOnTrip else { return .takeATrip(companion: WorldRecenterCopy.companionName(self)) }
        return .endTrip(city: flights.tripDestination.map(worldTripCity))
    }

    /// A destination's city in the app's language ("London"), or its code.
    func worldTripCity(_ destination: WorldTripDestination) -> String {
        WorldBoardingPassRule.city(of: destination, airports: worldLocation.flights.airportsShelf.pack(),
                                   spanish: WorldExploreCopy.showsSpanish)
    }

    /// The ticket's suggestions for `text` from the bundled list, at most `limit` (none in a decoy).
    func worldTripSuggestions(_ text: String, limit: Int) -> [WorldTripSuggestion] {
        guard !duressSessionActive, let pack = worldLocation.flights.airportsShelf.pack() else { return [] }
        return WorldTripSuggestions.search(text, in: pack.airports, spanish: WorldExploreCopy.showsSpanish, limit: limit)
    }

    /// The ticket as it opens: From the airport the person is at (or blank), today, and what today's calendar flight
    /// fills in (`today`: To and the departure time).
    func worldTicketRequest(today: WorldTripToday?, now: Date = Date()) -> WorldTripTicketRequest {
        let from = worldCurrentAirport.map { WorldBoardingPass.Stop(code: $0.code, place: WorldAirportCopy.city($0)) }
        var request = WorldTripTicketRequest(from: from, date: now)
        if let today {
            request.destination = .airport(today.destination)
            request.text = today.city
            request.departure = today.departure
        }
        return request
    }

    /// "Start trip": starts the trip, sealing its destination. False in a decoy, with the switch off, or on a trip.
    @discardableResult
    func startWorldTrip(to destination: WorldTripDestination?, at date: Date = Date()) -> Bool {
        guard worldMayTakeTrip else { return false }
        return worldLocation.flights.startTrip(to: destination, at: date)
    }

    /// "End trip".
    func endWorldTrip(at date: Date = Date()) {
        worldLocation.flights.endTrip(at: date)
    }

    /// Sprout's boarding pass for the tower of `airport` (§5); nil in a decoy.
    func worldBoardingPass(at airport: WorldAirport, now: Date = Date()) -> WorldBoardingPass? {
        guard !duressSessionActive else { return nil }
        let flights = worldLocation.flights
        return WorldBoardingPassRule.pass(at: airport, isOnTrip: flights.isOnTrip, destination: flights.tripDestination,
                                          tripStartedAt: flights.tripStartedAt, flights: WorldExploreState.book(self).flights,
                                          airports: flights.airportsShelf.pack(), spanish: WorldExploreCopy.showsSpanish, now: now)
    }

    /// Today's calendar flight from the airport the person is at (§10.7), while no trip is on: where it goes, its
    /// city and its departure. Nil elsewhere, in a decoy, with either switch off, or with none. DEBUG
    /// `FERNLET_UI_TEST_TRIP=today` stands a made-up one in.
    func worldTripToday(now: Date = Date()) -> WorldTripToday? {
        let flights = worldLocation.flights
        guard !duressSessionActive, !flights.isOnTrip, let airport = worldCurrentAirport else { return nil }
        let pack = flights.airportsShelf.pack()
        let city = { (code: String) in pack?.airport(code: code).map { WorldAirportCopy.city($0) } ?? code }
        if let staged = UITestSupport.tripSceneToday(now: now) {
            return WorldTripToday(destination: staged.destination, departure: staged.departure, city: city(staged.destination))
        }
        guard let iata = airport.iata, let today = worldCalendarFlightToday(atAirport: iata, now: now) else { return nil }
        return WorldTripToday(destination: today.destination, departure: today.departure, city: city(today.destination))
    }
}

/// Today's calendar flight from the airport the person is at (§10.7): its destination's IATA code, that city's name
/// in the app's language, and its departure. In memory only, never in a widget or notification.
nonisolated struct WorldTripToday: Equatable, Sendable {
    let destination: String
    let departure: Date
    let city: String
}
