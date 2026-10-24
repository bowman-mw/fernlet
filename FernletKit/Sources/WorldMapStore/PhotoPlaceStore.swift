import FernletFoundation
import Foundation

/// Where each photo taken with the disposable camera on your own was taken (owner's Q24 and the approved
/// policy sentence, 2026-10-24; World build step 5c): one point per photo id, so the photo can sit on the
/// person's map once it has shown. A photo taken at a refused place (medical, legal, therapy;
/// ``PlaceClassifier/photoMayKeepPlace(_:)``) has no point here at all, and neither has a friend's photo:
/// nothing ever writes one for them.
///
/// One small sealed file in the map's vault (`AEAD.worldMapPhotoPlacesV1`, the when-unlocked store key),
/// read afresh on every use, so nothing held in memory outlives a wipe. Deleting a photo deletes its point;
/// Delete everything, the silent wipe and the recovery lock remove it with the vault; a decoy never reads
/// or writes it. Bounded: at most ``maxPlaces`` points, a new one past it refused.
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

    /// A store over `vault`.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// Every photo's point, by photo id.
    public func all() throws -> [UUID: GeoPoint] {
        let file = WorldMapVault.File.photoPlaces
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
            return Dictionary(rows.prefix(Self.maxPlaces).filter { $0.point.isValid }.map { ($0.id, $0.point) },
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
        guard point.isValid, current[id] != nil || current.count < Self.maxPlaces else { return false }
        current[id] = point
        try save(current)
        return true
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
        vault.remove(WorldMapVault.File.photoPlaces)
    }

    /// Seals `places` as the file.
    private func save(_ places: [UUID: GeoPoint]) throws {
        let rows = places.map { Row(id: $0.key, point: $0.value) }.sorted { $0.id.uuidString < $1.id.uuidString }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try vault.write(try encoder.encode(rows), to: WorldMapVault.File.photoPlaces)
    }
}
