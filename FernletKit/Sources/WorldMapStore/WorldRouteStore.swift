import FernletCrypto
import Foundation

/// The World build's saved walk lines, one sealed file per workout (World app plan step 5b), shaped like
/// the watch build's planned `DeviceRouteStore`: keyed by the workout's id, device-only, never synced,
/// exported, shared, given to the AI or written to Apple Health. Only the workout's summary (its duration
/// and distance) goes into the synced diary.
///
/// When main gains the watch build's `DeviceRouteStore` and it is merged into `world-ui`, a short step
/// copies these lines across (the same codec shape) and retires this store.
///
/// Each line is sealed under the vault's store key with `AEAD.worldMapRouteV1`, and the workout id is part
/// of the authenticated data, so one workout's file renamed to another's never opens. Bounded: at most
/// ``maxRoutes`` lines (past it the oldest file is not evicted; a new line is refused and counted).
@MainActor
public final class WorldRouteStore {
    /// The most saved lines.
    public static let maxRoutes = 2_000
    /// Lines refused because the store was full (an audit count; never shown).
    public private(set) var refusedCount = 0

    private let vault: WorldMapVault

    /// A store over `vault`.
    public init(vault: WorldMapVault) {
        self.vault = vault
    }

    /// The sealed file for the workout `id`.
    static func file(for id: UUID) -> WorldMapVault.File {
        WorldMapVault.File(name: "route-\(id.uuidString).bin", purpose: FernletCryptoPurpose.AEAD.worldMapRouteV1,
                           role: .store, context: Data(id.uuidString.utf8))
    }

    /// Saves `points` as the line of workout `id` (replacing any line it had). Whether it was kept.
    @discardableResult
    public func save(_ points: [RoutePoint], for id: UUID) throws -> Bool {
        guard !points.isEmpty else { return false }
        let existing = try workoutIDs()
        guard existing.contains(id) || existing.count < Self.maxRoutes else {
            refusedCount += 1
            return false
        }
        try vault.write(WorldRouteCodec.encode(points), to: Self.file(for: id))
        return true
    }

    /// The line of workout `id`, or nil when it has none (or its file can't be opened, which removes it).
    public func route(for id: UUID) throws -> [RoutePoint]? {
        do {
            guard let data = try vault.read(Self.file(for: id)) else { return nil }
            guard let points = WorldRouteCodec.decode(data) else {
                vault.remove(Self.file(for: id))
                return nil
            }
            return points
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(Self.file(for: id))
            return nil
        }
    }

    /// Deletes the line of workout `id` (deleting a workout deletes its line). Whether it is gone.
    @discardableResult
    public func delete(for id: UUID) -> Bool {
        vault.remove(Self.file(for: id))
    }

    /// The workouts that have a saved line on this iPhone ("Routes stored on this iPhone: N").
    public func workoutIDs() throws -> Set<UUID> {
        let names = try vault.fileNames(withPrefix: "route-", limit: Self.maxRoutes + 1)
        return Set(names.compactMap { name in
            UUID(uuidString: String(name.dropFirst("route-".count).dropLast(".bin".count)))
        })
    }

    /// Deletes every saved line ("Delete all stored routes"); the fog and its keys stay. Whether all went.
    @discardableResult
    public func deleteAll() throws -> Bool {
        var removed = true
        for id in try workoutIDs() where !delete(for: id) { removed = false }
        return removed
    }
}
