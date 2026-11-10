import FernletFoundation
import Foundation

/// Where each photo taken with the disposable camera on your own was taken (owner's Q24 and the approved
/// policy sentence, 2026-10-24; World build step 5c): one point per photo id, so the photo can sit on the
/// person's map once it has shown. Only a photo taken at an everyday place or inside a park, beach or
/// campground has one (``PlaceClassifier/photoMayKeepPlace(_:)``; owner, round 5); a photo taken anywhere
/// else, offline, or by a friend has no point here at all: nothing ever writes one for them.
///
/// **The road trip exception** (World-RoadTrip-Spec §1, owner-approved 2026-11-10): a second store of this type,
/// over its own file (``WorldMapVault/File/roadTripPhotoPlaces``), keeps where each road trip photo was taken,
/// friends' trip photos included, because the owner decided "photos anyone takes on the trip may sit on each
/// member's map where they were taken". Only trip photos: a friend's hangout or wall photo still has no point in
/// either file. A trip photo's point is the trip's road at its capture time, so it may be anywhere on that road
/// (the everyday-places rule is for solo photos only). The solo file is never written for a trip photo, nor the
/// trip file for a solo one.
///
/// One small sealed file in the map's vault (`AEAD.worldMapPhotoPlacesV1`, the when-unlocked store key; the trip
/// file bound to its own context), read afresh on every use, so nothing held in memory outlives a wipe. Deleting a
/// photo deletes its point; Delete everything, the silent wipe, Delete map history and the recovery lock remove it
/// with the vault; a decoy never reads or writes it. Bounded: at most ``maxPlaces`` points, a new one past it
/// refused.
@MainActor
public final class PhotoPlaceStore {
    /// The most photo points kept (the solo corpus's own cap).
    public static let maxPlaces = 3_650

    /// One photo's point at rest. Frozen field names.
    private struct Row: Codable {
        let id: UUID
        let point: GeoPoint
    }

    private let vault: WorldMapVault
    /// The sealed file the points live in.
    private let file: WorldMapVault.File
    /// This store's own bound (at most ``maxPlaces``).
    private let limit: Int

    /// A store over `vault`: the solo photos' places (`photo-places.bin`), or, given `file` and `limit`, another
    /// photo corpus's (the road trip photos', ``WorldMapVault/File/roadTripPhotoPlaces``).
    public init(vault: WorldMapVault, file: WorldMapVault.File = .photoPlaces, limit: Int = PhotoPlaceStore.maxPlaces) {
        self.vault = vault
        self.file = file
        self.limit = max(0, min(limit, Self.maxPlaces))
    }

    /// Every photo's point, by photo id.
    public func all() throws -> [UUID: GeoPoint] {
        let file = self.file
        let data: Data?
        do {
            data = try vault.read(file)
        } catch WorldMapVault.VaultError.unopenable {
            vault.remove(file)
            return [:]
        }
        guard let data else { return [:] }
        do {
            let rows = try JSONDecoder().decode([Row].self, from: data)
            return Dictionary(rows.prefix(limit).filter { $0.point.isValid }.map { ($0.id, $0.point) },
                              uniquingKeysWith: { first, _ in first })
        } catch {
            FernletAuditLog.log("worldMap.photoPlaces.unreadable")
            vault.remove(file)
            return [:]
        }
    }

    /// The point of photo `id`, or nil.
    public func place(for id: UUID) throws -> GeoPoint? {
        try all()[id]
    }

    /// Keeps `point` as where photo `id` was taken. Whether it was kept.
    public func setPlace(_ point: GeoPoint, for id: UUID) throws -> Bool {
        var current = try all()
        guard point.isValid, current[id] != nil || current.count < limit else { return false }
        current[id] = point
        try save(current)
        return true
    }

    /// Keeps each of `found` as where its photo was taken, in one write (the trip photos placed by one catch-up's
    /// road). An invalid point, or a new one past the bound, is left out. How many were kept.
    public func setPlaces(_ found: [UUID: GeoPoint]) throws -> Int {
        var current = try all()
        var kept = 0
        // R2: bounded by this store's bound (a found place past it is refused).
        for (id, point) in found.prefix(limit) where point.isValid && (current[id] != nil || current.count < limit) {
            current[id] = point
            kept += 1
        }
        guard kept > 0 else { return 0 }
        try save(current)
        return kept
    }

    /// Removes the points of the photos in `ids` (deleting a photo deletes its place).
    public func remove(_ ids: Set<UUID>) throws {
        var current = try all()
        let before = current.count
        for id in ids { current.removeValue(forKey: id) }
        guard current.count != before else { return }
        try save(current)
    }

    /// Removes every photo's point. Keyless. Whether the file is gone.
    public func removeAll() -> Bool {
        vault.remove(file)
    }

    /// Seals `places` as the file.
    private func save(_ places: [UUID: GeoPoint]) throws {
        let rows = places.map { Row(id: $0.key, point: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try vault.write(try encoder.encode(rows), to: file)
    }
}
