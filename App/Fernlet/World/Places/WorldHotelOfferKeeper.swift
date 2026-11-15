import Foundation
import WorldMapStore

/// The hotel check-in offer (owner, 2026-11-15: "when you show up to a hotel, the option to check in should pop up
/// on the blue button"; "Ask apple maps whats nearby every time a drive ends"). Owned by ``WorldLocationSource``
/// (`hotelOffers`), which tells it when a drive starts and ends and hands it every reading; in memory only, nothing
/// on disk.
///
/// - **When a drive ends** (``driveEnded(at:)``) and the store's gate allows it (``mayLook``: no decoy, precise
///   location, "Remember places I stop at" on, and not at a home or the current hotel), one lookup asks the finder
///   for hotels within ``HomeBook/sameHotelRadius`` of where the drive ended. Only that point goes out.
/// - **The offer** (``offer``) is the nearest hotel it returned within that radius: its name and point, held here
///   only, never written. A hotel stayed at before gets it too; checking in there is a welcome back.
/// - **It goes** once the person leaves (a reading more than ``HomeBook/atRadius`` from both the hotel and where
///   the drive ended), when a new drive starts, or once they check in (``clear()``).
@MainActor
@Observable
final class WorldHotelOfferKeeper {
    /// The hotel to offer a check-in at, while the person is there; nil otherwise.
    private(set) var offer: WorldHotelOffer?

    /// Where the places come from (Apple Maps on the phone; tests stand in a fake).
    @ObservationIgnored var finder: any WorldNearbyFinding = AppleNearbyFinder()
    /// Whether a lookup may run round the drive's end point now (the store's gate); never until the store sets it.
    @ObservationIgnored var mayLook: (GeoPoint) -> Bool = { _ in false }
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
    func driveEnded(at point: GeoPoint?) {
        clear()
        guard let point, point.isValid, mayLook(point) else { return }
        lookup = Task { [weak self] in
            guard let finder = self?.finder else { return }
            let found = await finder.places(around: point, radius: Self.lookupRadius, categories: [.hotel])
            guard !Task.isCancelled else { return }
            self?.took(found ?? [], around: point)
        }
    }

    /// Keeps the nearest hotel the lookup found round `point`, if any is near enough.
    private func took(_ found: [WorldNearbyPlace], around point: GeoPoint) {
        lookup = nil
        guard let hotel = Self.nearestHotel(in: found, to: point) else { return }
        anchor = point
        offer = WorldHotelOffer(name: hotel.name, point: hotel.point)
    }

    /// The hotel nearest `point` among `places`, within ``lookupRadius``; nil for none.
    static func nearestHotel(in places: [WorldNearbyPlace], to point: GeoPoint) -> WorldNearbyPlace? {
        places.filter { $0.category == .hotel && !$0.name.isEmpty && $0.point.distance(to: point) <= lookupRadius }
            .min { $0.point.distance(to: point) < $1.point.distance(to: point) }
    }

    /// A reading at `point`: more than ``HomeBook/atRadius`` from both the hotel and the drive's end, the person
    /// has left, and the offer goes.
    func noteReading(_ point: GeoPoint) {
        guard let offer else { return }
        let fromHotel = offer.point.distance(to: point)
        let fromEnd = anchor?.distance(to: point) ?? fromHotel
        guard min(fromHotel, fromEnd) > HomeBook.atRadius else { return }
        clear()
    }

    /// The offer and any lookup go (checked in, a new drive, the person left, a wipe).
    func clear() {
        lookup?.cancel()
        lookup = nil
        anchor = nil
        if offer != nil { offer = nil }
    }

    /// The lookup ends with the keeper (the memory wall's ML1); it captures the keeper weakly, so this only stops a
    /// task outliving it.
    isolated deinit {
        lookup?.cancel()
    }
}
