import Foundation
import WorldMapStore

/// The hotel check-in offer on the store (owner, 2026-11-15: "when checking in at a hotel, it should unlock a circle
/// half the diameter of the home circle. And when you show up to a hotel, the option to check in should pop up on the
/// blue button"; "Ask apple maps whats nearby every time a drive ends").
///
/// - **The gate** (``worldHotelLookupAllowed(at:defaults:)``): when a drive ends, the location source's
///   ``WorldHotelOfferKeeper`` asks Apple Maps for hotels round where it ended only with no decoy, precise location,
///   "Remember places I stop at" on (off asks no lookup, as for the places themselves), and the end point not within
///   ``HomeBook/atRadius`` of a home or the current hotel.
/// - **The offer** (``worldHotelOffer``) is held in memory only, never written; the blue button shows "Check in at the
///   Ace". A hotel stayed at before is offered too, and checking in there is a welcome back (``HomeBook/checkingIn(_:)``).
/// - **Checking in** (``checkInAtWorldHotelOffer()``) goes through the person's own hotel book, which keeps the name
///   and point, encrypted on this iPhone; the offer goes with it.
extension FernletStore {
    /// Gives the offer keeper its gate (called with the rides' wiring, before the first reading).
    func wireWorldHotelOffers() {
        worldLocation.hotelOffers.mayLook = { [weak self] point in self?.worldHotelLookupAllowed(at: point) ?? false }
    }

    /// Whether a drive ending at `point` may ask Apple Maps for hotels round it: never in a decoy, without precise
    /// location, with "Remember places I stop at" off, or at a home or the current hotel.
    func worldHotelLookupAllowed(at point: GeoPoint, defaults: UserDefaults = .standard) -> Bool {
        guard !duressSessionActive, worldLocation.isPrecise, WorldMapPreferences.remembersPlaces(in: defaults) else { return false }
        return worldHomes.base(near: point) == nil
    }

    /// The hotel to offer a check-in at now: none in a decoy, nor once the current stay is at that hotel.
    var worldHotelOffer: WorldHotelOffer? {
        guard !duressSessionActive, let offer = worldLocation.hotelOffers.offer else { return nil }
        if let stay = worldHomes.hotel, stay.point.distance(to: offer.point) <= HomeBook.sameHotelRadius { return nil }
        return offer
    }

    /// "Check in at the Ace": starts the stay at the offered hotel, by its name and point, and the offer goes.
    /// Whether it checked in (false with no offer).
    @discardableResult
    func checkInAtWorldHotelOffer() -> Bool {
        guard let offer = worldHotelOffer else { return false }
        let checkedIn = checkInWorldHotel(HomePlace(kind: .hotel, label: offer.name, point: offer.point))
        if checkedIn { worldLocation.hotelOffers.clear() }
        return checkedIn
    }
}
