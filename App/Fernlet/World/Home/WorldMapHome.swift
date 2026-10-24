import AppServices
import FernletDomainModel
import FernletFoundation
import FernletScoring
import FernletUI
import SwiftUI
import UIKit
import WorldMapStore

/// The World Home: the live map, full-bleed, with the status plate top left, the four photo prints top
/// right, the companion standing where the person is, and the blue quick-start button bottom right
/// (designs `b1-home-day` draft 3 and its approved states; World app plan steps 1b, 2b, 3 and 6b). The
/// item bar is laid over it by the root shell. The bottom-left corner stays free for the session
/// button a friend session puts there.
///
/// **The map.** Apple's muted map behind the map seam, following the person while location is allowed
/// (the permission screens are step 5c; until then the map follows a permission given earlier, for
/// example for weather). Without a reading yet the plain map stands in, the companion in its middle.
/// With location off (or not asked) there is no map: the open scene (``WorldOffMapHome``,
/// `b1-home-denied` draft 4). With approximate location the map zooms out to the area. With no
/// signal, parchment covers Apple's map and the fog and lines draw on it. Location updates run only
/// while this map is on screen and the app is active (`WorldLocationSource`), or while a walk records.
///
/// **On the map:** the fog (`WorldFogKeeper`, in a decoy only the decoy's own), the walk's line as it
/// records, the person's pinned workout spaces (``WorldMapMarker``), a friend the presence radio hears
/// nearby (first name only, never where they are), rain or snow (``WorldWeatherLayer``), and the time of
/// day's tint (`CompanionDayPhase`; night dims the light map under a navy tint, and only Dark Mode turns it dark).
///
/// **The companion** (``WorldMapCompanion``) is Home's: tap to pet, hold (or VoiceOver's "Edit your
/// companion") for the customize sheet. Its line is the map's own when it has one (``WorldMapLine``).
///
/// **The blue button** (``WorldQuickStart``) quick-starts what the person does where they stand; Walk
/// together puts the walk bar under the status plate, and End logs the walk with a note that has Undo.
struct WorldMapHome: View {
    @Bindable var store: FernletStore
    /// Whether the map is what the person sees (no panel or sheet over it).
    let isFrontmost: Bool
    /// The opt-in body-signal reading for the companion's feeling, as Home reads it.
    var bodySignal: CompanionBodySignal?
    /// Opens a panel: Today from the status plate, Friends (the shared album) from the photo prints.
    let onOpen: (WorldPanel) -> Void
    /// Opens one of the app's sheets (Move's workout suggestion, from the quick start).
    var onSheet: (FernletSheet) -> Void = { _ in }
    /// Whether a stamp's banner is showing over the map: the prints step aside for it, as the approved
    /// banner design draws it (`b1-stamp-banner`).
    var stampBannerShowing = false
    /// Reports whether the disposable camera is open full screen (the root holds the session button and
    /// the stamp banner back meanwhile).
    var isCameraOpen: Binding<Bool> = .constant(false)
    @State private var camera = WorldCamera(center: GeoPoint(0, 0), distance: 1_700)
    @State private var hasPlace = false
    @State private var isCustomizing = false
    @State private var customizePetCount = 0
    @State private var tiles = WorldTileStatus()
    @State private var loadingLong = false
    @State private var cardContext: WorldQuickStartContext?
    @State private var guidedSession: WorkoutProgram.SessionSuggestion?
    @State private var cameraMode: WorldDisposableCamera.Mode?
    @State private var loggedWalk: WorldLoggedWalk?
    @State private var markers: [WorldMapMarker] = []
    @State private var sky: AmbientSky?
    /// A saved walk starting near where the map last came to the front.
    @State private var savedLine: WorldSavedLine?
    /// The saved line being walked again, drawn to follow.
    @State private var guideLine: [GeoPoint] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    var body: some View {
        TimelineView(.everyMinute) { timeline in
            if presence == .off {
                offHome(date: timeline.date)
            } else {
                mapHome(date: timeline.date)
            }
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $isCustomizing) {
            // The sheet applies `fernletSheet()` itself (full height, the wooden grabber); a second one
            // here would draw a second band.
            CompanionCustomizationSheet(store: store, petCount: $customizePetCount)
        }
        // The runner is a focused flow (`b3-runner-*`), presented full screen with no grabber as Move
        // presents it; its ✕ ends it.
        .fullScreenCover(item: $guidedSession) { session in
            GuidedWorkoutSheet(store: store, session: session, sessionsRemain: store.worldGuidedSessionsRemain(after: session))
        }
        .worldDisposableCamera(store: store, mode: $cameraMode)
        .environment(\.worldTileStatus, tiles)
        .task { await applyTestScenes() }
        .task(id: isFrontmost) { await refreshWeather() }
        .task(id: tiles.state) { await watchLoading() }
        .onAppear { updateLocation() }
        .onDisappear { store.worldLocation.stopForeground() }
        .onChange(of: isFrontmost) { updateLocation() }
        .onChange(of: scenePhase) { updateLocation() }
        .onChange(of: store.worldLocation.latest) { _, fix in follow(fix) }
        .onChange(of: notice) { _, kind in announce(kind) }
        .onChange(of: cameraMode) { _, mode in isCameraOpen.wrappedValue = mode != nil }
    }

    // MARK: Location off

    /// The open scene with location off (`b1-home-denied`, draft 4).
    private func offHome(date: Date) -> some View {
        WorldOffMapHome(store: store, date: date, status: WorldStatus.current(store: store, date: date), onOpen: onOpen) {
            WorldMapCompanion(store: store, bodySignal: bodySignal, isActive: isFrontmost && !isCustomizing,
                              mapLine: mapLine, pixelScale: dynamicTypeSize.isAccessibilitySize ? 6 : 7) {
                isCustomizing = true
            }
        }
    }

    // MARK: The map

    /// The live map with everything on it, the plates over it, and the bottom controls.
    private func mapHome(date: Date) -> some View {
        ZStack(alignment: .topLeading) {
            WorldMapStack(kind: hasPlace ? .appleMuted : .plain, camera: $camera, ground: ground, phase: phase(at: date),
                          darkMode: colorScheme == .dark, creditInset: Self.creditInset,
                          veiled: isOffline) { viewport, size in
                onMap(viewport: viewport, size: size)
            }
            if let sky, sky == .rain || sky == .snow {
                WorldWeatherLayer(sky: sky, isActive: isFrontmost).ignoresSafeArea()
            }
            plates(date: date)
        }
        .overlay { bottomControls }
    }

    /// What stands on the map, placed from the viewport: the space markers, the companion and any friend
    /// beside it.
    private func onMap(viewport: MapViewport, size: CGSize) -> some View {
        let point = companionPoint(viewport: viewport, size: size)
        return ZStack(alignment: .topLeading) {
            ForEach(shownMarkers) { marker in
                WorldMapMarkerView(marker: marker) { openCard(spaceID: marker.id) }
                    .fixedSize()
                    .position(viewport.screenPoint(for: marker.point, in: size))
            }
            ForEach(Array(nearbyFriends.enumerated()), id: \.element.id) { index, friend in
                WorldNearbyFriendView(friend: friend)
                    .fixedSize()
                    .position(x: point.x + (index == 0 ? 92 : -92), y: point.y + 40)
            }
            companion(at: point)
        }
    }

    /// The companion with its bubble, its feet on `point`.
    private func companion(at point: CGPoint) -> some View {
        WorldMapCompanion(store: store, bodySignal: bodySignal, isActive: isFrontmost && !isCustomizing, mapLine: mapLine,
                          isQuiet: isBubbleQuiet) {
            isCustomizing = true
        }
        .fixedSize()
        .frame(width: 0, height: 0, alignment: Alignment.bottom)
        .position(point)
    }

    /// The status plate and the prints along the top; the walk bar or the map's notice under them.
    private func plates(date: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                WorldStatusPlate(status: WorldStatus.current(store: store, date: date)) { onOpen(.today) }
                Spacer(minLength: 0)
                if showsPrints {
                    WorldPhotoPrints(store: store) { onOpen(.friends) }
                        .padding(.trailing, -2)
                }
            }
            if isWalking {
                WorldWalkBar(metres: walkMetres, onEnd: endWalk)
            }
            if let notice {
                WorldMapNotice(kind: notice, onUsePrecise: openSettings)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 12)
    }

    /// The blue button and its card bottom right, and the walk's note bottom centre, above the item bar.
    private var bottomControls: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
            VStack(alignment: .trailing, spacing: 14) {
                if let card = cardContext.flatMap(WorldQuickStart.card(for:)) {
                    WorldQuickStartCardView(card: card, onChoose: choose, onClose: closeCard)
                        .transition(.opacity)
                }
                if let glyph = WorldQuickStart.glyph(for: buttonContext) {
                    WorldQuickStartButton(glyph: glyph, action: toggleCard)
                }
            }
            .padding(.trailing, 12)
            .padding(.bottom, Self.bottomLift)
            if let loggedWalk {
                WorldWalkToast(walk: loggedWalk) { undo(loggedWalk) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, WorldWalkToast.bottomLift)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .task(id: loggedWalk.id) { await holdToast(loggedWalk) }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeOut(duration: 0.18), value: cardContext)
    }

    /// The blue button's distance off the physical bottom: above the item bar with the design's gap.
    /// The session button bottom left mirrors it.
    static let bottomLift = WorldItemBar.height + WorldItemBar.bottomGap + 22

    /// Where Apple's "Maps" credit sits: just above the item bar, as the approved Home draws it, below
    /// the blue button and the session button's bottom edge, so neither covers it (MapKit terms).
    static let creditInset = WorldItemBar.height + WorldItemBar.bottomGap + 2

    // MARK: State read from the store

    /// On or off, precise or approximate (a DEBUG screenshot can ask for approximate).
    private var presence: WorldMapPresence {
        let location = store.worldLocation
        let real = WorldMapPresence.make(permission: location.permission, isPrecise: location.isPrecise)
        guard real != .off, testScenes.contains("approx") else { return real }
        return .approximate
    }

    /// Whether Apple's tiles failed to load (no signal).
    private var isOffline: Bool { tiles.state == .failed || testScenes.contains("offline") }

    /// The map's notice now, if any.
    private var notice: WorldMapNoticeKind? {
        if testScenes.contains("loading") { return .loading }
        return WorldMapNoticeKind.make(presence: presence, tiles: isOffline ? .failed : tiles.state, loadingLong: loadingLong,
                                       liftedCells: store.worldFog.visibleCells.count,
                                       uncovers: WorldMapPreferences.uncoverAsYouGo(), isDecoy: store.duressSessionActive,
                                       isWalking: isWalking)
    }

    /// The map's own line for the companion, if it has one.
    private var mapLine: String? {
        var facts = WorldMapLine.Facts()
        facts.stampWaiting = store.sillyStats.stampLine(todayKey: store.todayKey, latestJournal: store.day.journals.last?.date) != nil
        facts.friendName = nearbyFriends.first?.firstName
        facts.isUnwell = store.isSick(on: store.todayKey)
        facts.sky = sky
        facts.presence = presence
        facts.isOffline = isOffline
        return WorldMapLine.line(facts)
    }

    /// What the ground draws: the lifted fog, and the walk's line while it records.
    private var ground: WorldGround {
        let trace = isWalking ? store.worldWalk.points.map(\.point) : []
        return WorldGround(lifted: store.worldFog.visibleCells, trails: isWalking && guideLine.count >= 2 ? [guideLine] : [],
                           traces: trace.count >= 2 ? [trace] : [])
    }

    /// Whether a walk is recording.
    private var isWalking: Bool { store.worldLocation.isWalking }

    /// Whether the companion's bubble stays down: under the open quick-start card, and at accessibility
    /// sizes while a notice, the walk bar or a stamp's banner fills the top, so the large bubble never
    /// runs into them.
    private var isBubbleQuiet: Bool {
        cardContext != nil || (dynamicTypeSize.isAccessibilitySize && (notice != nil || isWalking || stampBannerShowing))
    }

    /// The walk's length so far, in metres.
    private var walkMetres: Double { WorldRouteCodec.length(of: store.worldWalk.points) }

    /// Whether the prints show: not at accessibility sizes (as Home's photo wall), not while walking (the
    /// walk bar takes their place), not under a stamp's banner.
    private var showsPrints: Bool { !dynamicTypeSize.isAccessibilitySize && !isWalking && !stampBannerShowing }

    /// The markers on the map (a DEBUG screenshot can pin the first saved space near the companion).
    private var shownMarkers: [WorldMapMarker] {
        guard testScenes.contains("pin"), !store.duressSessionActive, let fix = store.worldLocation.latest,
              let space = store.settings.workoutLocations.first else { return markers }
        return markers + [WorldMapMarker(id: space.id, kind: .space, name: space.displayedName,
                                         point: fix.point.offset(east: -90, north: -170))]
    }

    /// Friends nearby (a DEBUG screenshot can stand one in).
    private var nearbyFriends: [WorldNearbyFriend] {
        guard testScenes.contains("friend") else { return store.worldNearbyFriends }
        return [WorldNearbyFriend(id: "fixture", firstName: "Sam")]
    }

    /// The time of day (fixed for DEBUG screenshots by `FERNLET_UI_TEST_WORLD_MAP_PHASE`).
    private func phase(at date: Date) -> CompanionDayPhase {
        UITestSupport.worldMapHarnessPhase ?? CompanionDayPhase.current(date: date)
    }

    /// The DEBUG screenshot scenes (empty in release builds).
    private var testScenes: Set<String> { UITestSupport.worldHomeScenes }

    // MARK: The blue button

    /// What the button sees: cheap, for its icon (the space from the markers already read).
    private var buttonContext: WorldQuickStartContext {
        staged(store.worldQuickStartContext(spaceID: hereSpaceID, includingPlans: false))
    }

    /// Adds what the map holds to the store's reading (the saved walk starting here) and, for DEBUG
    /// screenshots only, `solo` (the camera of your own) or `session` (a session with Sam and Rae),
    /// display only; the scene list is empty in release builds.
    private func staged(_ context: WorldQuickStartContext) -> WorldQuickStartContext {
        var context = context
        context.savedLine = savedLineHere?.summary
        if testScenes.contains("solo") { context.soloCameraAvailable = true }
        if testScenes.contains("session"), !context.isDecoy {
            context.session = WorldQuickStartContext.Session(names: ["Sam", "Rae"], shotsLeft: 3)
        }
        return context
    }

    /// The saved walk read when the map came to the front, while the person still stands at its start.
    private var savedLineHere: WorldSavedLine? {
        guard let savedLine, let start = savedLine.points.first, let fix = store.worldLocation.latest, fix.isPrecise,
              start.distance(to: fix.point) <= SpacePinStore.matchRadius else { return nil }
        return savedLine
    }

    /// The pinned space the person stands at, if any (a DEBUG screenshot stands the first space in).
    private var hereSpaceID: UUID? {
        if testScenes.contains("space"), !store.duressSessionActive { return store.settings.workoutLocations.first?.id }
        return WorldMapMarker.space(near: store.worldLocation.latest, in: markers)
    }

    /// The button: opens the card for where the person stands, or closes it.
    private func toggleCard() {
        guard cardContext == nil else {
            closeCard()
            return
        }
        openCard(spaceID: hereSpaceID)
    }

    /// Opens the card for `spaceID` (where the person stands, or a tapped marker's space).
    private func openCard(spaceID: UUID?) {
        readSavedLine()
        cardContext = staged(store.worldQuickStartContext(spaceID: spaceID, includingPlans: true))
    }

    /// Reads the saved walk that starts where the person stands now (a precise reading only; none while
    /// a walk records).
    private func readSavedLine() {
        guard let fix = store.worldLocation.latest, fix.isPrecise, !isWalking else { return }
        savedLine = store.worldSavedLine(startingNear: fix.point)
    }

    private func closeCard() {
        cardContext = nil
    }

    /// Does what a choice says, then closes the card.
    private func choose(_ option: WorldQuickStartOption) {
        let spaceID = cardContext?.space?.id
        closeCard()
        switch option {
        case .todaysPlan:
            if let spaceID { guidedSession = store.startTodaysPlan(at: spaceID) }
        case .suggestWorkout:
            if let spaceID { store.prepareSuggestion(at: spaceID) }
            onSheet(.workoutSuggestion)
        case .gentleStretch:
            guidedSession = store.todaysGentleStretch(committing: true)
        case .walkTogether:
            startWalk()
        case .walkSavedLine:
            guideLine = savedLineHere?.points ?? []
            startWalk()
        case .sessionCamera:
            cameraMode = .session
        case .soloCamera:
            cameraMode = .solo
        case .backToWorkout:
            guidedSession = store.guidedSessionForResume()
        }
    }

    // MARK: Walking together

    /// Starts Walk together: the recorder, and location for the walk.
    private func startWalk() {
        loggedWalk = nil
        store.startWorldWalk()
        follow(store.worldLocation.latest)
    }

    /// End: logs the walk (in a decoy, keeps nothing) and shows its note.
    private func endWalk() {
        guard let walk = store.endWorldWalk() else { return }
        FernletFeedback.system.play(.done)
        loggedWalk = walk
        guideLine = []
        // Ending the walk stops its updates; the map is still in front, so it follows again.
        updateLocation()
        FernletAnnouncer.system.announce(.success, resolved: WorldWalkCopy.logged(walk))
    }

    /// The note's Undo: the walk and its line go.
    private func undo(_ walk: WorldLoggedWalk) {
        loggedWalk = nil
        guard store.undoWorldWalk(walk) else { return }
        FernletAnnouncer.system.announce(.status, resolved: String(localized: WorldWalkCopy.undone))
    }

    /// Holds the walk's note for its window (four seconds, or the assistive one), then lets it go.
    private func holdToast(_ walk: WorldLoggedWalk) async {
        let window = FernletDismissalWindow.system.window(standard: .seconds(4), assistive: FernletDismissalWindow.assistiveActionWindow)
        do {
            try await Task.sleep(for: window)
        } catch {
            return
        }
        if loggedWalk?.id == walk.id { loggedWalk = nil }
    }
}

extension WorldMapHome {
    // MARK: Location, weather and loading

    /// Where the companion stands: the latest reading, or the middle of the map without one.
    private func companionPoint(viewport: MapViewport, size: CGSize) -> CGPoint {
        guard hasPlace, let fix = store.worldLocation.latest else {
            return CGPoint(x: size.width / 2, y: size.height * 0.6)
        }
        return viewport.screenPoint(for: fix.point, in: size)
    }

    /// Starts location while the map is in front and the app active; stops it otherwise (a walk keeps
    /// it running). Reads the space markers each time the map comes to the front.
    private func updateLocation() {
        let location = store.worldLocation
        guard isFrontmost, scenePhase == .active else {
            location.stopForeground()
            store.worldFog.flush()
            if !isFrontmost { cardContext = nil }
            return
        }
        store.worldFog.load()
        markers = store.worldSpaceMarkers(near: location.latest)
        readSavedLine()
        location.startForeground()
        follow(location.latest)
    }

    /// Moves the camera to a new reading while it follows the person. With approximate location the
    /// camera stands back to show the area, never a street.
    private func follow(_ fix: WorldFix?) {
        guard let fix, camera.follows else { return }
        let distance = presence == .approximate ? max(camera.distance, Self.areaDistance) : camera.distance
        if !hasPlace || distance != camera.distance {
            if !hasPlace { readSavedLine() }
            hasPlace = true
            camera = WorldCamera(center: Self.lookAt(fix.point, distance: distance), distance: distance,
                                 revision: camera.revision &+ 1)
            return
        }
        camera.move(to: Self.lookAt(fix.point, distance: camera.distance))
    }

    /// Where the camera looks so the person stands a little below the middle, as the approved Home
    /// stands the companion (about 58% of the way down), leaving room above for the plates and notices.
    static func lookAt(_ point: GeoPoint, distance: Double) -> GeoPoint {
        point.offset(east: 0, north: distance * PlainBaseMap.heightPerDistance * companionDrop)
    }

    /// How far below the middle the person stands, as a share of the map's height.
    static let companionDrop = 0.08

    /// How far back the camera stands with approximate location: the area, not the street.
    static let areaDistance = 5_000.0

    /// Reads the weather for rain and snow while weather prompts are on, as Home's ambience does.
    private func refreshWeather() async {
        if testScenes.contains("rain") { sky = .rain; return }
        if testScenes.contains("snow") { sky = .snow; return }
        guard isFrontmost, store.settings.weatherPromptsEnabled else { return }
        sky = await WeatherKitService.shared.currentAmbient()?.sky
    }

    /// Shows the loading plate once tiles have been loading for a moment.
    private func watchLoading() async {
        loadingLong = false
        guard tiles.state == .loading else { return }
        do {
            try await Task.sleep(for: WorldMapNoticeKind.loadingDelay)
        } catch {
            return
        }
        loadingLong = tiles.state == .loading
    }

    /// Announces a notice when it appears (the loading plate only once it has lasted two seconds).
    private func announce(_ kind: WorldMapNoticeKind?) {
        guard let kind, isFrontmost else { return }
        guard kind == .loading else {
            FernletAnnouncer.system.announce(.status, resolved: WorldMapNotice.announcement(kind))
            return
        }
        Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard notice == .loading else { return }
            FernletAnnouncer.system.announce(.status, resolved: WorldMapNotice.announcement(kind))
        }
    }

    /// "Use precise": Fernlet's page in the Settings app, where Precise Location is. Fernlet's own ask
    /// for precise location (temporary full accuracy) arrives with the permission screens (step 5c).
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// DEBUG screenshots: opens customize, marks today unwell, starts a walk or opens the card, as the
    /// scene list asks (nothing in release builds).
    private func applyTestScenes() async {
        if UITestSupport.shouldOpenCustomize { isCustomizing = true }
        let scenes = testScenes
        guard !scenes.isEmpty else { return }
        if scenes.contains("sick") != store.isSick(on: store.todayKey) { store.setSick(scenes.contains("sick"), on: store.todayKey) }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            return
        }
        if scenes.contains("walk") { startWalk() }
        if scenes.contains("qs") { openCard(spaceID: hereSpaceID) }
    }
}
