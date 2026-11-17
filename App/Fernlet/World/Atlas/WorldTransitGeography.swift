import FernletFoundation
import Foundation
import WorldMapStore

/// The ground under a trip, from the three bundled packs, for telling a ferry or a train from a drive
/// (Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3; `WornTransitGeography`):
/// - land and water from the shore mask (`WorldShore.pack`), or the atlas's own `LAND` where there is no shore mask;
/// - major roads from the atlas (`WorldAtlas.pack`'s `ROAD` section);
/// - rail lines and ferry routes from the rail pack (`WorldRail.pack`).
///
/// Immutable and `Sendable`: the fog keeper hands it to the detached task that classifies a finished trip. Built by
/// ``WorldAtlasKeeper`` once all three packs are open (``WorldAtlasKeeper/onTransitGeography``). Public data only.
nonisolated struct WorldTransitGeography: WornTransitGeography {
    let atlas: WorldAtlas
    let shore: WorldShoreMask?
    let rail: WorldRail

    func isWater(_ point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        if let shore { return !shore.isLand(at: point) }
        return atlas.isWater(at: point)
    }

    func isNearMajorRoad(_ point: GeoPoint, within metres: Double) -> Bool {
        atlas.isNearMajorRoad(point, within: metres)
    }

    func isNearRail(_ point: GeoPoint, within metres: Double) -> Bool {
        rail.isNearRail(point, within: metres)
    }

    func isNearFerryRoute(_ point: GeoPoint, within metres: Double) -> Bool {
        rail.isNearFerryRoute(point, within: metres)
    }
}

/// Opens the bundled `WorldRail.pack` (Docs/World-Rail-Pack.md) off the main actor, as ``WorldAtlasKeeper`` opens the
/// atlas and the shore mask. A missing or unreadable pack is logged once and means no transit geography this session:
/// every trip is then a road.
nonisolated enum WorldRailShelf {
    /// The bundled rail pack's resource name (a frozen file name: `WorldRail.pack`).
    static let resource = "WorldRail"
    /// Its extension.
    static let resourceExtension = "pack"

    /// The opener for the rail pack bundled in `bundle`. Safe off the main actor.
    static func bundled(in bundle: Bundle = .main) -> @Sendable () -> WorldRail? {
        let found = bundle.url(forResource: resource, withExtension: resourceExtension)
        return {
            guard let url = found else {
                FernletAuditLog.log("worldMap.rail.packMissing")
                return nil
            }
            do {
                if let rail = WorldRail.decode(try Data(contentsOf: url, options: .mappedIfSafe)) { return rail }
            } catch {
                // Unreadable: logged below, like a refused pack.
            }
            FernletAuditLog.log("worldMap.rail.packUnreadable")
            return nil
        }
    }
}
