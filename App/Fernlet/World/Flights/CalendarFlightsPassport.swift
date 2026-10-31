import Foundation
import WorldMapStore

/// The calendar's and the "Airports and flights" switch's changes to the passport (World-Airports-Spec §10.5,
/// §10.6, §11), through the keeper's one saving path: nothing in a decoy, nothing while the passport can't be
/// read, and the passport's sealed backup marked owed after a change.
extension WorldAtlasKeeper {
    /// Keeps a calendar look (spec §10.6): first every upcoming flight whose departure has passed joins the
    /// flights flown (``PassportBook/promoteUpcomingFlights(asOf:)``, before anything replaces the list), then
    /// `flown` (the window's flights already flown; empty for the first look, whose past flights wait for the
    /// summary's confirm) is added one flight once, then the upcoming flights become `upcoming`. Whether the
    /// passport took it.
    @discardableResult
    func keepCalendarLook(flown: [PassportFlight], upcoming: [PassportFlight], now: Date) -> Bool {
        apply { book in
            let promoted = book.promoteUpcomingFlights(asOf: now)
            let added = book.addFlights(flown)
            let replaced = book.setUpcomingFlights(upcoming)
            return promoted > 0 || added > 0 || replaced
        }
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
