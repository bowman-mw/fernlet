import Foundation
import WorldMapStore

/// The hotel check-in offer on the store (owner, 2026-11-15: "when checking in at a hotel, it should unlock a circle
/// half the diameter of the home circle. And when you show up to a hotel, the option to check in should pop up on the
/// blue button"; "Ask apple maps whats nearby every time a drive ends").
///
/// - **The gate** (``worldHotelLookupAllowed(at:defaults:)``): when a drive ends, the location source's
///   ``WorldHotelOfferKeeper`` asks Apple Maps round where it ended only with no decoy, precise location, a switch on
///   for at least one kind, and the end point not within ``HomeBook/atRadius`` of a home or the current hotel. It
///   asks only for the kinds whose switch is on (``worldDriveEndCategories(defaults:)``): hotels and gyms with
///   "Remember places I stop at", restaurants with "Remember places I eat out" (owner's picks N1-B and N5-B,
///   2026-11-27; the arrival offers are `FernletStore+WorldArrivalOffer`).
/// - **The offer** (``worldHotelOffer``) is held in memory only, never written; the blue button shows "Check in at the
///   Ace". A hotel stayed at before is offered too, and checking in there is a welcome back (``HomeBook/checkingIn(_:)``).
/// - **Checking in** (``checkInAtWorldHotelOffer()``) goes through the person's own hotel book, which keeps the name
///   and point, encrypted on this iPhone; the offer goes with it.
extension FernletStore {
    /// Gives the offer keeper its gate (called with the rides' wiring, before the first reading).
    func wireWorldHotelOffers() {
        worldLocation.hotelOffers.mayLook = { [weak self] point in self?.worldHotelLookupAllowed(at: point) ?? false }
        worldLocation.hotelOffers.categories = { [weak self] in self?.worldDriveEndCategories() ?? [] }
        worldPlaces.onArrival = { [weak self] offer in self?.worldArrivalFound(offer) }
    }

    /// Whether a drive ending at `point` may ask Apple Maps what is round it: never in a decoy, without precise
    /// location, with every kind's switch off, or at a home or the current hotel.
    func worldHotelLookupAllowed(at point: GeoPoint, defaults: UserDefaults = .standard) -> Bool {
        guard !duressSessionActive, worldLocation.isPrecise, !worldDriveEndCategories(defaults: defaults).isEmpty else { return false }
        return worldHomes.base(near: point) == nil
    }

    /// The kinds a drive's end asks Apple Maps for, by the switches now (``WorldArrivalRules/driveEndCategories(remembersPlaces:remembersEatingOut:)``).
    func worldDriveEndCategories(defaults: UserDefaults = .standard) -> [WorldNearbyCategory] {
        WorldArrivalRules.driveEndCategories(remembersPlaces: WorldMapPreferences.remembersPlaces(in: defaults),
                                             remembersEatingOut: WorldMapPreferences.remembersEatingOut(in: defaults))
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
