import FernletFoundation
import Foundation
import WorldMapStore

/// The upgrade for calendar flights counted without proof (release review F10; owner 2026-11-19: "no, needs
/// confirmation of a trip. Example is calendar invite from a friend and picking them up from the airport").
///
/// Builds from 2026-11-02 (#130) to this one made every calendar flight whose departure had passed a flight flown:
/// it counted in the Flights page's totals and arcs, made its day a travel day (remembered in the map's vault) and
/// could put its city into Tier-2 memory. From this build a calendar flight is the person's own only once confirmed
/// (Fernlet's own landing, a Flighty record of it, or the first look's "Add N flights"), so the upgrade, once:
///
/// - **moves back to the upcoming flights** every flight flown from the calendar alone that left on or after
///   ``calendarFlightsShipped``: those flights can't be told apart from ones the first look's summary added, so
///   any that may have come in without proof are treated as unconfirmed. Nothing is deleted here; at the next
///   calendar look they lapse like any unconfirmed calendar flight, and a flight from before that day (only the
///   person's "Add" could have brought it) stays;
/// - **forgets the remembered travel days** those flights and the upcoming calendar flights made, unless a
///   confirmed flight or a trip under way still makes the day;
/// - and the passport's totals, arcs, stamps' "found on the ground" and Tier-2's cities follow, since they are all
///   read from the flights flown.
///
/// Never in a decoy, never with the passport closed (the phone locked): it runs again at the next open until the
/// passport takes it.
extension FernletStore {
    /// The day calendar flights first reached a build (#130, 2026-11-02 00:00 UTC).
    nonisolated static let calendarFlightsShipped = Date(timeIntervalSince1970: 1_793_577_600)

    /// Runs the upgrade once (see the extension's notes). Called as the map loads, before Tier-2's travel snapshot.
    func upgradeUnconfirmedCalendarFlights(now: Date = Date(), defaults: UserDefaults = .standard) {
        guard !WorldMapPreferences.calendarFlightsUpgraded(in: defaults), !duressSessionActive,
              !worldFog.atlas.isDecoy else { return }
        let upcoming = worldFog.atlas.book.upcomingFlights
        guard let demoted = worldFog.atlas.demoteUnconfirmedCalendarFlights(since: Self.calendarFlightsShipped) else { return }
        forgetTravelDays(madeBy: demoted + upcoming, now: now)
        WorldMapPreferences.setCalendarFlightsUpgraded(in: defaults)
        guard !demoted.isEmpty else { return }
        FernletAuditLog.log("worldMap.flights.calendarDemoted", context: ["count": String(demoted.count)])
    }
}
