import Foundation
import SwiftUI
import WorldMapStore

// Home's passport hook's DEBUG screenshot hook (round 7, lane explore-ui, piece `hook`):
// `FERNLET_UI_TEST_HOME_HOOK=<scene>` acts on Home once the map settles, through the same paths a person's touch
// takes. Scenes: `tap` (Sprout's tap: the passport opens on page 1, rising from Sprout, `ps-open`), `new` (a new
// stamp, the mockup's Sea of Japan, noted on the demo passport: Home's banner shows and stays up), `newTap` (the
// same, then the banner's tap: the book opens on the stamp's page), `city` (the passport opens on page 2, then the
// world view's city tap for the city where the person stands: the book closes and Home goes to the city view).
// The demo passport is in memory only, never written. Absent in Release.

extension UITestSupport {
    #if DEBUG
    /// The Home hook scene to play at launch (`FERNLET_UI_TEST_HOME_HOOK`), or nil.
    static var homeHookScene: String? { ProcessInfo.processInfo.environment["FERNLET_UI_TEST_HOME_HOOK"] }
    /// Whether the new-stamp banner stays up for its screenshot (`new`).
    static var homeHookHoldsBanner: Bool { homeHookScene == "new" }
    #else
    static var homeHookScene: String? { nil }
    static var homeHookHoldsBanner: Bool { false }
    #endif
}

#if DEBUG
extension UITestSupport {
    /// `tap`: waits for the map to settle, then says Sprout's tap is due, once per launch.
    static func homeHookTapsSprout() async -> Bool {
        guard homeHookScene == "tap", !HomeHookOnce.shared.tapped else { return false }
        do {
            try await Task.sleep(for: .seconds(9))
        } catch {
            return false
        }
        // Marked only once the tap is sent: a companion view replaced while waiting leaves it to the new one.
        guard !HomeHookOnce.shared.tapped else { return false }
        HomeHookOnce.shared.tapped = true
        return true
    }

    /// `new`, `newTap`, `city`: plays the scene on `passport` once the map settles.
    static func playHomeHook(passport: WorldPassportPresenter?, store: FernletStore) async {
        guard let passport, let scene = homeHookScene, ["new", "newTap", "city"].contains(scene), !HomeHookOnce.shared.played else {
            return
        }
        HomeHookOnce.shared.played = true
        guard await pause(seconds: 8) else { return }
        if scene == "city" {
            passport.open(page: 2)
            guard await pause(seconds: 4) else { return }
            let atlas = store.worldFog.atlas.openedAtlas
            guard let fix = store.worldLocation.latest, let city = atlas?.city(at: fix.point) else { return }
            passport.openCity(city.token)
            return
        }
        let atlas = store.worldFog.atlas.openedAtlas
        passport.demo = PassportBookDemo(entries: PassportBookDemoScenes.sample, world: WorldAtlasMapDemo.content(atlas: atlas))
        guard let newest = PassportStampEntry.ordered(PassportBookDemoScenes.sample).last else { return }
        passport.noteNewStamp(newest)
        guard scene == "newTap", await pause(seconds: 4) else { return }
        // The banner's tap, as `PassportNewStampBanner` sends it.
        passport.bannerShown()
        passport.open()
    }

    /// Sleeps `seconds`; false when cancelled.
    private static func pause(seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            return false
        }
        return true
    }
}

/// What the hook has played this launch (each scene plays once).
@MainActor
private final class HomeHookOnce {
    static let shared = HomeHookOnce()
    var tapped = false
    var played = false
}
#else
extension UITestSupport {
    /// The Home hook: nothing in Release.
    static func homeHookTapsSprout() async -> Bool { false }
    /// The Home hook: nothing in Release.
    static func playHomeHook(passport: WorldPassportPresenter?, store: FernletStore) async {}
}
#endif
