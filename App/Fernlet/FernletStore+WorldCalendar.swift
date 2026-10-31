import FernletFoundation
import Foundation
import WorldMapStore

/// The "Airports and flights" switch and the calendar's flights on the store (World-Airports-Spec §10, §11).
///
/// - **The switch** (``setWorldAirportsAndFlights(_:defaults:)``, on by default): off keeps no new airport
///   stamps, flights or layovers (``recordWorldFlightEvents(_:defaults:)`` drops what the gate finds, the Flighty
///   import refuses) and turns "Flights from Calendar" off with it. Whether to delete what's kept is the person's
///   answer (``forgetWorldAirportsAndFlights()``).
/// - **Today's calendar flight** (``worldCalendarFlightToday(atAirport:now:defaults:)``, spec §10.7): the small
///   read-only answer the blue button's "Trip to Honolulu" and the ticket read. Nil in a decoy, with either
///   switch off, or with no airport list.
/// - **Watching** is the app root's (`worldCalendarFlights(store:isReady:)`, ``CalendarFlightWatcher``); the
///   gates are ``mayReadWorldCalendar(defaults:)``.
extension FernletStore {
    /// Whether "Airports and flights" is on.
    func keepsWorldAirportsAndFlights(defaults: UserDefaults = .standard) -> Bool {
        WorldMapPreferences.keepsAirportsAndFlights(in: defaults)
    }

    /// Turns "Airports and flights" on or off; off turns "Flights from Calendar" off too (its look stops).
    func setWorldAirportsAndFlights(_ on: Bool, defaults: UserDefaults = .standard) {
        WorldMapPreferences.setKeepsAirportsAndFlights(on, in: defaults)
        if !on { WorldMapPreferences.setReadsCalendarFlights(false, in: defaults) }
    }

    /// Deletes every airport visit, layover and flight from the passport (spec §11, asked after the switch goes
    /// off). How many went, or nil when the passport couldn't take it now (or in a decoy, which keeps none).
    func forgetWorldAirportsAndFlights() -> Int? {
        guard !duressSessionActive else { return nil }
        let removed = worldFog.atlas.forgetAirportsAndFlights()
        if removed != nil { FernletAuditLog.log("worldMap.flights.forgotten") }
        return removed
    }

    /// Today's calendar flight leaving the airport `iata` (spec §10.7): its destination's IATA code and departure,
    /// for the blue button's label and the ticket. Today is the day `now` falls on at that airport. Nil in a
    /// decoy, with either switch off, with no airport list, or with no such flight.
    func worldCalendarFlightToday(atAirport iata: String, now: Date = Date(),
                                  defaults: UserDefaults = .standard) -> CalendarFlightToday? {
        guard mayReadWorldCalendar(defaults: defaults),
              let zone = worldLocation.flights.airportsShelf.pack()?.timeZone(iata: iata) else { return nil }
        return worldFog.atlas.book.calendarFlightToday(from: iata, now: now, in: zone)
    }
}
