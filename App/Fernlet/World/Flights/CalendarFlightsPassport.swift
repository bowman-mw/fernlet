import Foundation
import WorldMapStore

/// The calendar's and the "Airports and flights" switch's changes to the passport (World-Airports-Spec §10.5,
/// §10.6, §11), through the keeper's one saving path: nothing in a decoy, nothing while the passport can't be
/// read, and the passport's sealed backup marked owed after a change.
extension WorldAtlasKeeper {
    /// Keeps a calendar look (spec §10.6, amended by the owner 2026-11-19: a calendar flight needs confirmation of
    /// the trip): `flown` (the window's flights that have left; empty for the first look, whose past flights wait
    /// for the summary's confirm) and `upcoming` are never flown on their own. One that is a flight already flown
    /// joins it; the rest replace the upcoming flights, a departed one waiting there for Fernlet's own landing
    /// (`PassportBook/keepCalendarFlights(_:)`). Whether the passport took it.
    @discardableResult
    func keepCalendarLook(flown: [PassportFlight], upcoming: [PassportFlight]) -> Bool {
        apply { $0.keepCalendarFlights(flown + upcoming) }
    }

    /// The upgrade from builds that made every passed calendar flight a flight flown (owner 2026-11-19): moves each
    /// flight flown from the calendar alone that left on or after `since` back to the upcoming flights
    /// (`PassportBook/demoteCalendarOnlyFlights(since:)`). The flights moved, or nil when the passport couldn't take
    /// it (a decoy, or the phone locked).
    func demoteUnconfirmedCalendarFlights(since: Date) -> [PassportFlight]? {
        var demoted: [PassportFlight] = []
        let taken = apply { book in
            demoted = book.demoteCalendarOnlyFlights(since: since)
            return true
        }
        return taken ? demoted : nil
    }

    /// "Delete" after "Airports and flights" goes off (spec §11): every airport visit, layover and flight, flown
    /// or upcoming, leaves the passport; countries and everything else stay. How many went, or nil when the
    /// passport couldn't take it.
    func forgetAirportsAndFlights() -> Int? {
        var removed = 0
        let taken = apply { book in
            removed = book.forgetAirportsAndFlights()
            return removed > 0
        }
        return taken ? removed : nil
    }
}
