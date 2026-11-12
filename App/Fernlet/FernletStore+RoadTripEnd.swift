import FernletFoundation
import Foundation
import PrivateMediaStore
import WorldMapStore

/// The end of a road trip, the store's side (World-RoadTrip-Spec PR 4, `rt-end`, owner-approved 2026-11-10): "The trip
/// ends when someone taps End the road trip, when everyone has left, or by itself after 7 days without a catch-up. A
/// summary card shows once on Home … The trip is also added to the passport's trips … kept on each phone like a walk's
/// line: sealed, never synced, deleted with map history."
///
/// - **The three ends:** End the road trip is PR 1's and PR 2's (`endRoadTrip(now:)`). Seven days without a catch-up
///   end the trip on this iPhone's own clock at the mark (``RoadTripKeeper/endIfQuiet(now:)``), checked at launch, on
///   every load of the map (each foreground, the locked launch) and when Home appears; no timer, no background work.
///   Everyone has left: a member who leaves says so in a Not this time (`RoadTripJoinPayload/left`), to the members
///   linked then and in answer to any later catch-up, and the trip ends here once every other member has
///   (`receiveRoadTripAnswer(_:from:now:)`).
/// - **The numbers** (``roadTripSummary(of:calendar:)``): worked out once, the first time Home is in front after the
///   trip stopped being on here with everything they need readable (the line, the map, the photo roll, the atlas not
///   still opening, no catch-up's photos still landing), then kept in the trip's sealed record. A trip this iPhone left
///   is over for it too: it gets its numbers and its card, dated to the leave.
/// - **The card** (``roadTripSummaryCard``, ``markRoadTripSummaryShown(_:)``): the newest trip no longer on, once,
///   while Home is in front; the shown flag is in the sealed record (no `UserDefaults` key).
/// - **Decoy and wipes:** a decoy ends nothing, works out nothing and shows no card (the keeper's book is empty there);
///   the numbers and the flag go with the record (`road-trips.bin`) in every wipe and Delete map history.
extension FernletStore {
    /// The end's checks (launch, foreground, Home appearing): a trip seven days without a catch-up ends at its mark,
    /// and each trip no longer on whose numbers aren't in yet gets them when they can be read now. Nothing in a decoy.
    func refreshRoadTripEnd(now: Date = Date()) {
        guard !duressSessionActive else { return }
        let keeper = worldFog.roadTrip
        keeper.endIfQuiet(now: now)
        // A catch-up's photos still landing would be missed: the numbers wait for them to settle.
        guard !roadTripMesh.isSettling else { return }
        // R2: bounded by the book's trips.
        for trip in keeper.book.closed.prefix(RoadTripBook.maxTrips) where trip.summary == nil {
            guard let summary = roadTripSummary(of: trip) else { continue }
            guard keeper.change(trip.id, { $0.summary = summary }) else {
                FernletAuditLog.log("worldMap.roadTrip.summaryUnsaved")
                continue
            }
            FernletAuditLog.log("worldMap.roadTrip.summarised")
        }
    }

    /// `trip`'s numbers now (``RoadTripEndRules/summary(of:line:uncovered:photos:towns:calendar:)``): its line on this
    /// iPhone to its end, the tiles uncovered since its start, the photos on the roll, and the towns by the bundled
    /// atlas's city rule (left out without an atlas). Nil while it is on, in a decoy, and while something it needs
    /// can't be read yet (the line or the roll locked away, the map not read, the atlas still opening).
    func roadTripSummary(of trip: RoadTrip, calendar: Calendar = .current) -> RoadTripSummary? {
        guard !duressSessionActive, let end = trip.closedAt else { return nil }
        let fog = worldFog
        let uncovered = fog.uncoveredCellCount
        guard trip.cellsAtStart == nil || uncovered != nil, !fog.atlas.isOpeningAtlas,
              let index = roadTripPhotos.index(),
              let line = fog.roadTrip.linePoints(of: trip, after: .distantPast, through: end) else { return nil }
        let towns: ((GeoPoint) -> String?)? = fog.atlas.openedAtlas.map { atlas in { atlas.city(at: $0)?.token } }
        return RoadTripEndRules.summary(of: trip, line: line, uncovered: uncovered, photos: index.photos(of: trip.id).count,
                                        towns: towns, calendar: calendar)
    }

    /// The summary card Home shows now: the newest trip no longer on, its numbers in, not yet shown (nor closed this
    /// session); nil with none and in a decoy.
    var roadTripSummaryCard: RoadTripSummaryCard? {
        guard !duressSessionActive, let trip = worldFog.roadTrip.book.summaryToShow, let summary = trip.summary,
              !roadTripMesh.closedSummaries.contains(trip.id) else { return nil }
        return RoadTripSummaryCard(id: trip.id, title: RoadTripCopy.name(of: trip), summary: summary)
    }

    /// Done on the card of trip `id`: it has shown, and won't again (in the sealed record; when that can't be written,
    /// for the rest of this session). Whether the flag was written; nothing in a decoy.
    @discardableResult
    func markRoadTripSummaryShown(_ id: UUID) -> Bool {
        guard !duressSessionActive else { return false }
        guard worldFog.roadTrip.change(id, { $0.summaryShown = true }) else {
            roadTripMesh.closeSummary(id)
            return false
        }
        return true
    }
}
