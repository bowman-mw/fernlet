import SwiftUI
import WorldMapStore

/// The World Home: the live map, full-bleed, with the status plate on top (designs `b1-home-day` and its
/// approved variants, draft 3; World app plan steps 1b and 2b). The item bar is laid over it by the root
/// shell, and the companion, the photos and the blue button arrive in later steps.
///
/// **The map.** Apple's muted map behind the map seam, following the person while location is allowed
/// (the permission screens are step 5c; until then the map follows a permission given earlier, for
/// example for weather). Without a reading there is no place to show, so the plain map stands in.
/// Location updates run only while this map is on screen and the app is active (`WorldLocationSource`).
///
/// **The fog** is the lifted history (`WorldFogKeeper`), or in a decoy session only the decoy's own.
/// The time of day tints the map (`CompanionDayPhase`), and night switches Apple's map to its dark style.
struct WorldMapHome: View {
    @Bindable var store: FernletStore
    /// Whether the map is what the person sees (no panel or sheet over it).
    let isFrontmost: Bool
    let onOpenToday: () -> Void
    @State private var camera = WorldCamera(center: GeoPoint(0, 0), distance: 1_700)
    @State private var hasPlace = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let phase = CompanionDayPhase.current(date: timeline.date)
            ZStack(alignment: .topLeading) {
                WorldMapStack(kind: hasPlace ? .appleMuted : .plain, camera: $camera,
                              ground: WorldGround(lifted: store.worldFog.visibleCells), phase: phase,
                              darkMode: colorScheme == .dark, creditInset: WorldItemBar.height + WorldItemBar.bottomGap + 12) { _, _ in EmptyView() }
                WorldStatusPlate(status: WorldStatus.current(store: store, date: timeline.date), onOpenToday: onOpenToday)
                    .padding(.top, 6)
                    .padding(.leading, 12)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear { updateLocation() }
        .onDisappear { store.worldLocation.stopForeground() }
        .onChange(of: isFrontmost) { updateLocation() }
        .onChange(of: scenePhase) { updateLocation() }
        .onChange(of: store.worldLocation.latest) { _, fix in follow(fix) }
    }

    /// Starts location while the map is in front and the app active; stops it otherwise.
    private func updateLocation() {
        let location = store.worldLocation
        guard isFrontmost, scenePhase == .active else {
            location.stopForeground()
            store.worldFog.flush()
            return
        }
        store.worldFog.load()
        location.startForeground()
        follow(location.latest)
    }

    /// Moves the camera to a new reading while it follows the person.
    private func follow(_ fix: WorldFix?) {
        guard let fix, camera.follows else { return }
        if !hasPlace {
            hasPlace = true
            camera = WorldCamera(center: fix.point, distance: camera.distance)
            return
        }
        camera.move(to: fix.point)
    }
}
