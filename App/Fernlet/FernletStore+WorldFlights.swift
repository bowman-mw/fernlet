import Foundation
import WorldMapStore

/// The flight gate on the store (World-Airports-Spec §3, §4.2, §6; owner 2026-10-31: "Don't track anything that the
/// user flies over"): the map's location source weighs every reading in its ``WorldFlightKeeper`` before anything
/// keeps it, and what the gate finds goes to the passport here.
///
/// - **Airports found** (ten minutes inside a large airport's approved outline, a trip's first reading there, a
///   take-off or a landing) are recorded in the passport, which stamps a new one and a landing's new trip.
/// - **A landing** keeps the flight as its two airports' IATA codes and times, nothing else; a layover flown on
///   from marks the airport's stamp TRANSIT. The country and continent come later, when the person leaves the
///   grounds (``WorldFix/atLandedAirport``).
/// - **A decoy** records nothing (the passport keeps nothing in one) and writes no gate state; the gate still
///   refuses readings in the air.
extension FernletStore {
    /// Gives the gate the map's vault, the person's homes and the passport (called with the rides' wiring,
    /// before the first reading).
    func wireWorldFlights() {
        let flights = worldLocation.flights
        flights.attach(vault: worldMapVault)
        flights.mayWrite = { [weak self] in !(self?.duressSessionActive ?? true) }
        flights.isHome = { [weak self] point in
            self?.worldHomes.homes.contains { $0.point.distance(to: point) <= HomeBook.atRadius } ?? false
        }
        flights.onEvents = { [weak self] events in self?.recordWorldFlightEvents(events) }
    }

    /// Records what the gate found in the passport (at most ``maxFlightEvents`` from one reading).
    func recordWorldFlightEvents(_ events: [FlightEvent]) {
        let atlas = worldFog.atlas
        for event in events.prefix(Self.maxFlightEvents) {
            switch event {
            case .airportFound(let token, let how, let at):
                atlas.recordAirport(token: token, at: at, by: Self.passportFind(how))
            case .landed(let token, let from, let departed, let at):
                if let flight = worldLocation.flights.flight(from: from, to: token, departed: departed, arrived: at) {
                    atlas.recordFlight(flight)
                }
            case .layoverBecameTransit(let token, _):
                atlas.markTransit(atAirport: token)
            case .flightStarted, .endedWithoutAirport, .arrived, .tripStarted, .tripEnded:
                continue
            }
        }
    }

    /// The most events one reading's changes are read for (a bound; a reading makes at most a few).
    static let maxFlightEvents = 16

    /// The passport's reading of how the gate found an airport: a take-off from an airport no trip had found is
    /// what a ticket would have done (§7, "a flight found by its speed does everything a ticket does").
    static func passportFind(_ finding: FlightFinding) -> PassportBook.AirportFind {
        switch finding {
        case .dwell: .dwell
        case .ticket, .takeOff: .ticket
        case .landing: .landing
        }
    }
}
