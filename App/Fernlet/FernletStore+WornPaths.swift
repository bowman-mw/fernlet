import FernletDomainModel
import FernletFoundation
import Foundation
import WorldMapStore

/// The store's side of worn paths and frequent roads (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §8, owner
/// 2026-11-15).
///
/// - **Footpaths** come from the saved walk, run and ride lines (``WorldRouteStore``), each dated by its workout's
///   `completedAt`. Exactly as Home's saved lines (``worldHomeSavedLines(now:defaults:)``): **only while "Save new
///   routes" is on**, and **none in a decoy**.
/// - **Roads** come from the fog keeper's sealed counter (`WorldFogKeeper.wornWays`, empty in a decoy).
/// - **"Show worn paths"** (``WorldMapPreferences/showWornPaths(in:)``, on by default) hides both everywhere when off.
///
/// Nothing here is stored: the map works its drawing out in memory (``WornWaysModel``).
extension FernletStore {
    /// What Home's worn ways are worked out from now: the switch, the saved lines' workouts, the road counter, today,
    /// and Home's `trails` (read under `trailStamp`) to cut where a footpath shows.
    func wornWaysRequest(trails: [[GeoPoint]], trailStamp: Int, now: Date = Date(),
                         defaults: UserDefaults = .standard) -> WornWaysRequest {
        let shows = WorldMapPreferences.showWornPaths(in: defaults) && !duressSessionActive
        return WornWaysRequest(shows: shows, routeIDs: shows ? wornFootpathRouteIDs(defaults: defaults) : [],
                               roads: shows ? wornRoadTallies : [:], today: WornDay.number(for: now),
                               trails: trails, trailStamp: trailStamp)
    }

    /// The workouts whose saved line can wear a footpath: every stored line while Save new routes is on, none in a
    /// decoy or while the folder can't be listed. One listing of the vault's folder, no file opened.
    func wornFootpathRouteIDs(defaults: UserDefaults = .standard) -> Set<UUID> {
        guard !duressSessionActive, WorldMapPreferences.saveNewRoutes(in: defaults) else { return [] }
        do {
            return try worldRoutes.workoutIDs()
        } catch {
            return []
        }
    }

    /// The road counter the map draws: the fog keeper's, none in a decoy.
    var wornRoadTallies: [WornWayKey: WornTally] {
        duressSessionActive ? [:] : worldFog.wornWays
    }

    /// The day (``WornDay``) each of `ids`' workouts was completed on, for those found in the diary: today's day
    /// first, then the whole history in one read (`loadDays()`, as the silly stats read it) only when some are still
    /// missing. Bounded: the days' workouts.
    func wornRouteDays(for ids: Set<UUID>) -> [UUID: UInt16] {
        guard !ids.isEmpty else { return [:] }
        var found: [UUID: UInt16] = [:]
        for workout in day.workouts where ids.contains(workout.id) {
            found[workout.id] = WornDay.number(for: workout.completedAt)
        }
        guard found.count < ids.count else { return found }
        for stored in loadDays().values {
            for workout in stored.workouts where ids.contains(workout.id) && found[workout.id] == nil {
                found[workout.id] = WornDay.number(for: workout.completedAt)
            }
        }
        return found
    }

    /// The passport's Your world road counter: the fog keeper's while "Show worn paths" is on, none in a decoy.
    func wornYourWorldTallies(defaults: UserDefaults = .standard) -> [WornWayKey: WornTally] {
        guard WorldMapPreferences.showWornPaths(in: defaults), !duressSessionActive, !worldFog.isDecoy else { return [:] }
        return worldFog.wornWays
    }
}
