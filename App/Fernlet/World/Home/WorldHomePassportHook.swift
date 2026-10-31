import SwiftUI
import WorldMapStore

/// Home's side of Sprout's passport (round 7, World-Passport-Spec §1, §6; World-Exploration-Spec §2's city view):
///
/// - **New stamps.** Home's discovery reader (``WorldDiscoveryRouter``, the passport's one listener) hands every
///   stamp a discovery earns to the presenter's `noteNewStamp(_:)`: the next open lands it on its page, and the
///   root shows the new-stamp banner meanwhile (``PassportNewStampBanner``). The router hears nothing in a decoy.
/// - **A city from the world view.** `WorldYourWorldPage`'s city tap closes the passport and asks Home to show the
///   city (`WorldPassportPresenter.openCity(_:)`): the camera centres on the city's point at ``cityDistance``,
///   following off, where the city view (its plate and big landmarks) draws. A city far away works the same way:
///   MapKit flies there, the fog covers what the person hasn't walked, and the city view draws as at home. The
///   visit holds (no ten seconds' re-follow) until the person moves the map or goes Back to Sprout.
struct WorldHomePassportHook: ViewModifier {
    let store: FernletStore
    let passport: WorldPassportPresenter?
    let router: WorldDiscoveryRouter
    @Binding var camera: WorldCamera
    @Binding var cityVisit: WorldCamera?

    /// The camera height a world-view city opens at: Home's own street view, under the 2,400 m step where the
    /// city markers take over from the city view (``WorldExploreSelection``).
    static let cityDistance = 1_700.0
    /// How far the map may drift from a visit (MapKit settling the camera) before it counts as the person's move.
    static let visitDriftMetres = 60.0

    func body(content: Content) -> some View {
        content
            .onAppear(perform: attachNewStamps)
            .onChange(of: passport?.cityRequest) { _, request in if let request { showCity(request.token) } }
            // DEBUG `FERNLET_UI_TEST_HOME_HOOK` (`new`, `newTap`, `city`); nothing in Release.
            .task { await UITestSupport.playHomeHook(passport: passport, store: store) }
    }

    /// Every new stamp goes to the passport (its landing and the root's banner); never in a decoy (the router
    /// routes nothing in one, and this checks again).
    private func attachNewStamps() {
        guard let passport else { return }
        let store = store
        router.onNewStamp = { [weak passport] stamp in
            Self.forward(stamp, to: passport, isDecoy: store.duressSessionActive)
        }
    }

    /// Hands one new stamp to the passport (its landing and the banner); nothing in a decoy.
    static func forward(_ stamp: PassportStamp, to passport: WorldPassportPresenter?, isDecoy: Bool) {
        guard !isDecoy, let entry = PassportStampEntry(stamp: stamp) else { return }
        passport?.noteNewStamp(entry)
    }

    /// Moves the camera to the world view's city `token` (following off).
    private func showCity(_ token: String) {
        guard let city = store.worldFog.atlas.openedAtlas?.city(token: token) else { return }
        let visit = WorldCamera(center: city.point, distance: Self.cityDistance, revision: camera.revision &+ 1, follows: false)
        camera = visit
        cityVisit = visit
    }

    /// Whether the map still shows the city `visit` put it on: the person hasn't moved it (beyond MapKit's own
    /// settling), so the ten seconds' re-follow waits.
    static func isStillVisiting(_ visit: WorldCamera?, camera: WorldCamera) -> Bool {
        guard let visit, !camera.follows else { return false }
        return camera.center.distance(to: visit.center) <= visitDriftMetres
            && abs(camera.distance - visit.distance) <= visit.distance * 0.1
    }
}
