import SwiftUI
import FernletScoring
import WorldMapStore

/// The World Home: the live map, full-bleed, with the status plate top left, the four photo prints top
/// right, and the companion standing where the person is (designs `b1-home-day` and its approved
/// variants, draft 3; World app plan steps 1b, 2b and 3). The item bar is laid over it by the root
/// shell, and the blue button arrives in a later step.
///
/// **The map.** Apple's muted map behind the map seam, following the person while location is allowed
/// (the permission screens are step 5c; until then the map follows a permission given earlier, for
/// example for weather). Without a reading there is no place to show, so the plain map stands in and
/// the companion stands in its middle. Location updates run only while this map is on screen and the
/// app is active (`WorldLocationSource`).
///
/// **The fog** is the lifted history (`WorldFogKeeper`), or in a decoy session only the decoy's own.
/// The time of day tints the map (`CompanionDayPhase`), and night switches Apple's map to its dark style.
///
/// **The companion** (``WorldMapCompanion``) is Home's: tap to pet, hold (or VoiceOver's "Edit your
/// companion") for the same customize sheet Home opens.
struct WorldMapHome: View {
    @Bindable var store: FernletStore
    /// Whether the map is what the person sees (no panel or sheet over it).
    let isFrontmost: Bool
    /// The opt-in body-signal reading for the companion's feeling, as Home reads it.
    var bodySignal: CompanionBodySignal?
    /// Opens a panel: Today from the status plate, Friends (the shared album) from the photo prints.
    let onOpen: (WorldPanel) -> Void
    @State private var camera = WorldCamera(center: GeoPoint(0, 0), distance: 1_700)
    @State private var hasPlace = false
    @State private var isCustomizing = false
    @State private var customizePetCount = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            let phase = CompanionDayPhase.current(date: timeline.date)
            ZStack(alignment: .topLeading) {
                WorldMapStack(kind: hasPlace ? .appleMuted : .plain, camera: $camera,
                              ground: WorldGround(lifted: store.worldFog.visibleCells), phase: phase,
                              darkMode: colorScheme == .dark, creditInset: WorldItemBar.height + WorldItemBar.bottomGap + 12) { viewport, size in
                    companion(at: companionPoint(viewport: viewport, size: size))
                }
                WorldStatusPlate(status: WorldStatus.current(store: store, date: timeline.date)) { onOpen(.today) }
                    .padding(.top, 6)
                    .padding(.leading, 12)
            }
            .overlay(alignment: .topTrailing) { photoPrints }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isCustomizing) {
            CompanionCustomizationSheet(store: store, petCount: $customizePetCount)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        }
        // Test hook (DEBUG; false in release): open customize directly, as Home's does, since XCUITest
        // and screenshots cannot send the hold.
        .task { if UITestSupport.shouldOpenCustomize { isCustomizing = true } }
        .onAppear { updateLocation() }
        .onDisappear { store.worldLocation.stopForeground() }
        .onChange(of: isFrontmost) { updateLocation() }
        .onChange(of: scenePhase) { updateLocation() }
        .onChange(of: store.worldLocation.latest) { _, fix in follow(fix) }
    }

    /// The companion with its bubble, its feet on `point`.
    private func companion(at point: CGPoint) -> some View {
        WorldMapCompanion(store: store, bodySignal: bodySignal, isActive: isFrontmost && !isCustomizing) {
            isCustomizing = true
        }
        .fixedSize()
        .frame(width: 0, height: 0, alignment: Alignment.bottom)
        .position(point)
    }

    /// Where the companion stands: the latest reading, or the middle of the map without one.
    private func companionPoint(viewport: MapViewport, size: CGSize) -> CGPoint {
        guard hasPlace, let fix = store.worldLocation.latest else {
            return CGPoint(x: size.width / 2, y: size.height * 0.6)
        }
        return viewport.screenPoint(for: fix.point, in: size)
    }

    /// The photo prints, top right; at accessibility sizes they give way, as Home's photo wall does.
    @ViewBuilder
    private var photoPrints: some View {
        if !dynamicTypeSize.isAccessibilitySize {
            WorldPhotoPrints(store: store) { onOpen(.friends) }
                .padding(.top, 6)
                .padding(.trailing, 10)
        }
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
