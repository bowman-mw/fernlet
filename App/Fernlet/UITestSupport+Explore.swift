import Foundation
import WorldMapStore

//  The cities-and-landmarks DEBUG screenshot hooks (round 7, World-Exploration-Spec §2), beside `UITestSupport`'s
//  own: wrapped in `#if DEBUG`, with a release no-op, so nothing of it ships.

extension UITestSupport {
    #if DEBUG
    /// `FERNLET_UI_TEST_EXPLORE=landmark:<token>|city:<token>|gallery:<board>` — opens a found landmark's card, a
    /// found city's card, or the art gallery (`skylines`, `famous1`…`famous5`) over Home, for the `ex-landmark`,
    /// `ex-city-card`, `ex-skylines` and `ex-fam-*` screenshots. Consumed by `WorldExplorePresenter`.
    static var exploreScene: String? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_EXPLORE"]
    }

    /// `FERNLET_UI_TEST_EXPLORE_DISTANCE=<metres>` — Home's camera opens at that height (`3400`: zoomed out a
    /// step, `ex-zoomed`). Consumed by `WorldMapHome`'s test scenes.
    static var exploreCameraDistance: Double? {
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_EXPLORE_DISTANCE"].flatMap(Double.init)
    }

    /// `FERNLET_UI_TEST_EXPLORE_DEMO=<landmark token>,…` — Home draws from a demo passport, in memory only (nothing
    /// is read or written), in which each listed landmark is found today and its city was found on 12 October
    /// (the mockup's date); `none` (no known token) is an empty passport, every landmark grey, whatever the
    /// simulator's own passport found. Nil without the variable.
    static func exploreDemoBook(atlas keeper: WorldAtlasKeeper) -> PassportBook? {
        guard let value = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_EXPLORE_DEMO"] else { return nil }
        let list = keeper.landmarks
        let today = Date()
        let october = DateComponents(calendar: Calendar.current, year: Calendar.current.component(.year, from: today),
                                     month: 10, day: 12, hour: 12).date ?? today
        var found: [AtlasDiscovery] = []
        for token in value.split(separator: ",").prefix(64).map(String.init) {
            guard let landmark = list.landmark(token: token) else { continue }
            found.append(AtlasDiscovery(kind: .landmark, token: landmark.token, at: today))
            if !found.contains(where: { $0.kind == .city && $0.token == landmark.cityToken }) {
                found.append(AtlasDiscovery(kind: .city, token: landmark.cityToken, at: october))
            }
        }
        do {
            return try PassportBook(discoveries: found)
        } catch {
            return nil
        }
    }
    #else
    static var exploreScene: String? { nil }
    static var exploreCameraDistance: Double? { nil }
    static func exploreDemoBook(atlas keeper: WorldAtlasKeeper) -> PassportBook? { nil }
    #endif
}
