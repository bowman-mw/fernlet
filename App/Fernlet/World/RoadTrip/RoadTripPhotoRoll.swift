import FernletFoundation
import Foundation
import Observation
import PrivateMediaStore
import WorldMapStore

/// The road trips' photo roll on this iPhone (World-RoadTrip-Spec PR 3, owner-approved 2026-11-10: `rt-photos`,
/// `rt-map`): a thin owner over the sealed corpus (``RoadTripPhotoStore``, the photos with who took them, when and
/// whether they are hidden) and the photos' places in the map's vault (a `PhotoPlaceStore` over
/// `road-trip-photo-places.bin`, deleted with map history). The store's rules (`FernletStore+RoadTripPhotos.swift`)
/// decide what goes in; this keeps it.
///
/// - **Decoy:** while a decoy shows (``setDecoy(_:)``) nothing is read or written and nothing is handed out: no
///   trip is on in a decoy, so the camera never shoots onto this roll there, and a received photo is refused.
/// - **Places** go with their photos: deleting one deletes its place, and the hidden flag lives in the sealed index.
/// - **Wipes:** ``purgeForDeleteAll()`` removes the whole corpus (the vault's own wipe takes the places).
///
/// ``revision`` moves on every change, so Home reads the prints again. Main actor, like the store that owns it.
@MainActor
@Observable
final class RoadTripPhotoRoll {
    @ObservationIgnored private let store: RoadTripPhotoStore
    @ObservationIgnored private let places: PhotoPlaceStore
    /// Whether a decoy shows: nothing real is read or written.
    private(set) var isDecoy: Bool
    /// Moves on every photo kept, hidden or deleted, and every place kept.
    private(set) var revision = 0
    /// The line's point count the last time unplaced photos were looked for on it (memory only).
    @ObservationIgnored var placesTriedAtLineCount: Int?

    /// A roll over `store` and `places`.
    init(store: RoadTripPhotoStore, places: PhotoPlaceStore, isDecoy: Bool) {
        self.store = store
        self.places = places
        self.isDecoy = isDecoy
    }

    /// The index now; nil in a decoy and when it can't be read right now.
    func index() -> RoadTripPhotoIndex? {
        guard !isDecoy else { return nil }
        switch store.load() {
        case .loaded(let index): return index
        case .unrecoverable(purged: true): return .empty
        case .unrecoverable(purged: false), .deferred: return nil
        }
    }

    /// Keeps `photo` with `bytes` (already normalized), within the trip roll's bounds. Refused in a decoy.
    func add(_ photo: RoadTripPhoto, bytes: Data) -> RoadTripPhotoStore.Add {
        guard !isDecoy else { return .notPersisted }
        let outcome = store.add(photo, imageData: bytes, perAuthor: RoadTripPhotoRules.perMember, perTrip: RoadTripPhotoRules.perTrip)
        if case .added = outcome { revision &+= 1 }
        return outcome
    }

    /// Every photo's place, by its id on this iPhone; empty in a decoy and when the vault can't be read right now.
    func allPlaces() -> [UUID: GeoPoint] {
        guard !isDecoy else { return [:] }
        do {
            return try places.all()
        } catch {
            FernletAuditLog.log("worldMap.roadTripPhotoPlaces.readDeferred")
            return [:]
        }
    }

    /// Keeps `found` as where those photos were taken, in one write. How many were kept.
    func setPlaces(_ found: [UUID: GeoPoint]) -> Int {
        guard !isDecoy, !found.isEmpty else { return 0 }
        do {
            let kept = try places.setPlaces(found)
            if kept > 0 { revision &+= 1 }
            return kept
        } catch {
            FernletAuditLog.log("worldMap.roadTripPhotoPlaces.saveFailed")
            return 0
        }
    }

    /// "Hide from the map": photo `id` leaves the map (its place and the photo stay). Whether it is hidden.
    func hide(_ id: UUID) -> Bool {
        guard !isDecoy, store.setHidden(id, true) else { return false }
        revision &+= 1
        return true
    }

    /// Deletes the photos in `ids` and their places. Whether they are gone.
    func delete(_ ids: Set<UUID>) -> Bool {
        guard !isDecoy, store.delete(ids) else { return false }
        do {
            try places.remove(ids)
        } catch {
            FernletAuditLog.log("worldMap.roadTripPhotoPlaces.removeFailed")
        }
        revision &+= 1
        return true
    }

    /// A photo's full-size bytes; nil in a decoy, and when it can't be read.
    func imageData(for id: UUID) -> Data? {
        isDecoy ? nil : store.imageData(for: id)
    }

    /// A photo's thumbnail; nil in a decoy, and when it can't be read.
    func thumbnailData(for id: UUID) -> Data? {
        isDecoy ? nil : store.thumbnailData(for: id)
    }

    /// Map history was deleted (the places went with the vault): Home reads the prints again, and the trip's photos
    /// are looked for on the line afresh.
    func mapHistoryDeleted() {
        placesTriedAtLineCount = nil
        revision &+= 1
    }

    /// Follows the duress decoy.
    func setDecoy(_ on: Bool) {
        guard on != isDecoy else { return }
        isDecoy = on
        placesTriedAtLineCount = nil
        revision &+= 1
    }

    /// Delete everything's leg: the whole sealed corpus (every photo, thumbnail and hidden flag), then the cached
    /// key. Runs in a decoy too (the silent wipe's purge does). Whether the corpus is gone.
    func purgeForDeleteAll() -> Bool {
        let purged = store.purgeAll()
        store.invalidateEncryptionKeyCache()
        placesTriedAtLineCount = nil
        revision &+= 1
        return purged
    }
}
