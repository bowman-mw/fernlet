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
/// - **Never lost to a locked phone:** an airport the gate counts as found (landed at, or inside on a trip) and the
///   passport doesn't have is handed again with each reading until the passport takes it.
/// - **A decoy** records nothing (the passport keeps nothing in one) and writes no gate state; the gate still
///   refuses readings in the air.
/// - **"Airports and flights" off** (spec §11, Privacy & data) records no airport, flight or layover: what the
///   gate found is dropped, never kept for later. The gate itself still refuses every reading in the air.
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
        flights.onEvents = { [weak self] events in self?.recordWorldFlightEvents(events) ?? true }
        flights.passportHolds = { [weak self] token in self?.worldPassportHoldsAirport(token) ?? true }
    }

    /// Records what the gate found in the passport (at most ``maxFlightEvents`` at once). False when the passport
    /// can't take them now (the phone is locked, so it can't be read or saved), and the gate hands them all again
    /// later; a second recording changes nothing. With "Airports and flights" off, or in a decoy, nothing is
    /// recorded and the events are taken (true), so none comes back.
    @discardableResult
    func recordWorldFlightEvents(_ events: [FlightEvent], defaults: UserDefaults = .standard) -> Bool {
        guard WorldMapPreferences.keepsAirportsAndFlights(in: defaults) else { return true }
        return Self.record(events, in: worldFog.atlas, flights: worldLocation.flights)
    }

    /// Records `events` in `atlas`, stopping at the first the passport can't take; whether it took them all.
    static func record(_ events: [FlightEvent], in atlas: WorldAtlasKeeper, flights: WorldFlightKeeper) -> Bool {
        guard !atlas.isDecoy else { return true }
        guard atlas.opensForFlights() else { return false }
        return events.prefix(maxFlightEvents).allSatisfy { record($0, in: atlas, flights: flights) }
    }

    /// Records one event; whether the passport took it (an event it keeps nothing of is taken).
    private static func record(_ event: FlightEvent, in atlas: WorldAtlasKeeper, flights: WorldFlightKeeper) -> Bool {
        switch event {
        case .airportFound(let token, let how, let at):
            return atlas.recordAirport(token: token, at: at, by: passportFind(how))
        case .landed(let token, let from, let departed, let at):
            guard let flight = flights.flight(from: from, to: token, departed: departed, arrived: at) else { return true }
            return atlas.recordFlight(flight)
        case .layoverBecameTransit(let token, _):
            return atlas.markTransit(atAirport: token)
        case .flightStarted, .endedWithoutAirport, .arrived, .tripStarted, .tripEnded:
            return true
        }
    }

    /// Whether the passport already has the airport `token`, or nothing should be added to it (a decoy, or "Airports
    /// and flights" off), so the gate has nothing to hand again.
    private func worldPassportHoldsAirport(_ token: String, defaults: UserDefaults = .standard) -> Bool {
        guard !duressSessionActive, !worldFog.atlas.isDecoy, WorldMapPreferences.keepsAirportsAndFlights(in: defaults) else { return true }
        return worldFog.atlas.book.visits(of: .airport)[token] != nil
    }

    /// The most events read at once (a bound: one reading makes at most a few, after at most the gate's waiting ones).
    static let maxFlightEvents = WorldFlightKeeper.maxPendingEvents + 16

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
