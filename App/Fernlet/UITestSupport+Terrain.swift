import Foundation
import WorldMapStore

//  The terrain's DEBUG screenshot hook (round 7, World-Exploration-Spec §1 "Seasons"), beside
//  `UITestSupport`'s own: wrapped in `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_TERRAIN_SEASON=spring|summer|autumn|winter` — every seasonal hex of Home's terrain
    /// (grassland, temperate forest, cropland) shows that season instead of today's in its hemisphere, for the
    /// `ex-home-winter` screenshot. Consumed by `WorldTerrain.home(_:)`.
    static var terrainSeasonOverride: AtlasSeason? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_TERRAIN_SEASON"].flatMap(AtlasSeason.init(rawValue:))
    }
    #else
    static var terrainSeasonOverride: AtlasSeason? { nil }
    #endif
}
