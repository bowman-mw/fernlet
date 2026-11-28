import Foundation
import WorldMapStore

/// The hotel check-in offer (owner, 2026-11-15: "when you show up to a hotel, the option to check in should pop up
/// on the blue button"; "Ask apple maps whats nearby every time a drive ends"). Owned by ``WorldLocationSource``
/// (`hotelOffers`), which tells it when a drive starts and ends and hands it every reading; in memory only, nothing
/// on disk.
///
/// - **When a drive ends** (``driveEnded(at:)``) and the store's gate allows it (``mayLook``: no decoy, precise
///   location, and not at a home or the current hotel), one lookup asks the finder for the kinds whose switch is on
///   (``categories``: hotels and gyms with "Remember places I stop at", restaurants with "Remember places I eat out";
///   owner's picks N1-B and N5-B, 2026-11-27) within ``HomeBook/sameHotelRadius`` of where the drive ended. Only that
///   point and the kinds go out, in the one request.
/// - **The offer** (``offer``) is the nearest hotel it returned within that radius: its name and point, held here
///   only, never written. A hotel stayed at before gets it too; checking in there is a welcome back.
/// - **The arrival offer** (``arrival``) is the nearest restaurant or gym it returned (``WorldArrivalOffer``), or the
///   one the foreground stop lookup handed in (``arrive(_:)``): held here only, never written. A hotel outranks it on
///   the blue button.
/// - **They go** once the person leaves (a reading more than ``HomeBook/atRadius`` from both the place and where
///   the drive ended), when a new drive starts, once they check in (``clear()``), or once the arrival offer is
///   used (``clearArrival()``).
@MainActor
@Observable
final class WorldHotelOfferKeeper {
    /// The hotel to offer a check-in at, while the person is there; nil otherwise.
    private(set) var offer: WorldHotelOffer?
    /// The restaurant or gym the person arrived at, while they are there; nil otherwise.
    private(set) var arrival: WorldArrivalOffer?

    /// Where the places come from (Apple Maps on the phone; tests stand in a fake).
    @ObservationIgnored var finder: any WorldNearbyFinding = AppleNearbyFinder()
    /// Whether a lookup may run round the drive's end point now (the store's gate); never until the store sets it.
    @ObservationIgnored var mayLook: (GeoPoint) -> Bool = { _ in false }
    /// The kinds a drive's end asks for now (the store's switches); hotels alone until the store sets it.
    @ObservationIgnored var categories: () -> [WorldNearbyCategory] = { [.hotel] }
    /// The lookup in flight, if any (tests await it).
    @ObservationIgnored private(set) var lookup: Task<Void, Never>?
    /// Where the drive that found the offer ended.
    @ObservationIgnored private var anchor: GeoPoint?

    /// How far round the drive's end the lookup reaches, in metres: as near as the same hotel counts.
    static let lookupRadius = HomeBook.sameHotelRadius

    /// A drive started: any offer and lookup go.
    func driveStarted() {
        clear()
    }

    /// A drive ended at `point` (the latest reading; nil with none): one lookup round it when the gate allows.
    func driveEnded(at point: GeoPoint?, now: Date = Date()) {
        clear()
        let kinds = categories()
        guard let point, point.isValid, !kinds.isEmpty, mayLook(point) else { return }
        lookup = Task { [weak self] in
            guard let finder = self?.finder else { return }
            let found = await finder.places(around: point, radius: Self.lookupRadius, categories: kinds)
            guard !Task.isCancelled else { return }
            self?.took(found ?? [], around: point, now: now)
        }
    }

    /// Keeps the nearest hotel the lookup found round `point`, and the nearest restaurant or gym, if any is near enough.
    private func took(_ found: [WorldNearbyPlace], around point: GeoPoint, now: Date) {
        lookup = nil
        arrival = WorldArrivalRules.nearestArrival(in: found, to: point, radius: Self.lookupRadius, now: now)
        guard let hotel = Self.nearestHotel(in: found, to: point) else { return }
        anchor = point
        offer = WorldHotelOffer(name: hotel.name, point: hotel.point)
    }

    /// The foreground stop lookup found the person stopped at a restaurant or gym (the store's gate already
    /// passed): it becomes the arrival offer, in place of any other.
    func arrive(_ offer: WorldArrivalOffer) {
        arrival = offer
    }

    /// The arrival offer goes (a meal logged or a workout started from it); a hotel's offer stays.
    func clearArrival() {
        if arrival != nil { arrival = nil }
    }

    /// The hotel nearest `point` among `places`, within ``lookupRadius``; nil for none.
    static func nearestHotel(in places: [WorldNearbyPlace], to point: GeoPoint) -> WorldNearbyPlace? {
        places.filter { $0.category == .hotel && !$0.name.isEmpty && $0.point.distance(to: point) <= lookupRadius }
            .min { $0.point.distance(to: point) < $1.point.distance(to: point) }
    }

    /// A reading at `point`: more than ``HomeBook/atRadius`` from both the hotel and the drive's end, the person
    /// has left, and the offer goes.
    func noteReading(_ point: GeoPoint) {
        if let arrival, arrival.isLeft(at: point) { clearArrival() }
        guard let offer else { return }
        let fromHotel = offer.point.distance(to: point)
        let fromEnd = anchor?.distance(to: point) ?? fromHotel
        guard min(fromHotel, fromEnd) > HomeBook.atRadius else { return }
        clear()
    }

    /// The offers and any lookup go (checked in, a new drive, the person left, a wipe).
    func clear() {
        lookup?.cancel()
        lookup = nil
        anchor = nil
        if offer != nil { offer = nil }
        clearArrival()
    }

    /// The lookup ends with the keeper (the memory wall's ML1); it captures the keeper weakly, so this only stops a
    /// task outliving it.
    isolated deinit {
        lookup?.cancel()
    }
}
