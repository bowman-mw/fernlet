import AppServices
import FernletDomainModel
import FernletFoundation
import FernletScoring
import FernletUI
import ProximityKit
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
/// (asked once by the map intro, `b1-loc-intro`, step 5c; a permission given earlier, for weather, counts too,
/// and the intro never shows). Without a reading yet the plain map stands in, the companion in its middle:
/// so it is before the person answers, behind the intro and iOS's prompt (`b1-home-first`, `b1-loc-prompt`).
/// With location off (denied, or the intro's Not now) there is no map: the open scene (``WorldOffMapHome``,
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
    /// Opens a panel: Today from the status plate, the Album from an empty photo print.
    let onOpen: (WorldPanel) -> Void
    /// Opens a page of the Album panel: Friends nearby or Activities from the blue button's friend
    /// choices (`b4-mem-blue-*`), or a print's photo from the photo wall (`ref-wall-photo`).
    var onFriends: (FriendsRoute) -> Void = { _ in }
    /// Opens one of the app's sheets (Move's workout suggestion, from the quick start).
    var onSheet: (FernletSheet) -> Void = { _ in }
    /// Whether a stamp's banner is showing over the map: the prints step aside for it, as the approved
    /// banner design draws it (`b1-stamp-banner`).
    var stampBannerShowing = false
    /// Reports whether the disposable camera is open full screen (the root holds the session button and
    /// the stamp banner back meanwhile).
    var isCameraOpen: Binding<Bool> = .constant(false)
    /// Where a meal the blue button logs goes: the toast (round 6, "Log your usual"; the root's reporter).
    var onMealsLogged: MealLogReporter = .none
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
    /// Whether the map intro is up (`b1-loc-intro`, ``WorldLocationIntroPresenter``).
    @State private var isLocationIntroUp = false
    /// Where the person's shown solo photos were taken (``WorldPhotoPlace``), read when the map comes to
    /// the front, and the one whose photos are open.
    @State private var photoPlaces: [WorldPhotoPlace] = []
    @State private var openPhotoPlace: WorldPhotoPlace?
    /// DEBUG `photo`: whether a photo taken where the person stands would keep its place.
    @State private var testPhotoKept = false
    /// Whether the one-time "Tap me to say hi!" hint is showing (`ref-hint`, ``WorldCompanionHint``).
    @State private var isHintShowing = false
    /// Round 6: Sprout's greeting at a home or hotel (said once), the map drawn clear round homes and kept
    /// places, the Remember this place sheet, and a menu search's meal sheet.
    @State private var homeGreeting: String?
    @State private var uncovered: Set<HexCell> = []
    @State private var placeSheet: WorldPlaceSheetMode?
    @State private var menuSearch: WorldMenuSearch?
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
        // The map intro, once, before iOS asks (`b1-loc-intro`).
        .modifier(WorldLocationIntroPresenter(store: store, isFrontmost: isFrontmost, isUp: $isLocationIntroUp))
        // A photo place's marker opens the photos taken there (World build step 5c).
        .modifier(WorldPhotoPlacePresenter(store: store, place: $openPhotoPlace))
        // Round 6: Remember this place, and a place to eat's menu search.
        .modifier(WorldPlacesPresenter(store: store, placeSheet: $placeSheet, menuSearch: $menuSearch, onMealsLogged: onMealsLogged))
        .environment(\.worldTileStatus, tiles)
        .task { await applyTestScenes() }
        .task(id: isHintDue) { if isHintDue { isHintShowing = true } }
        .task(id: isFrontmost) { await refreshWeather() }
        .task(id: tiles.state) { await watchLoading() }
        .onAppear { updateLocation() }
        .onDisappear { store.worldLocation.stopForeground() }
        .onChange(of: isFrontmost) { updateLocation() }
        .onChange(of: scenePhase) { updateLocation() }
        .onChange(of: store.worldLocation.latest) { _, fix in follow(fix) }
        .onChange(of: notice) { _, kind in announce(kind) }
        .onChange(of: cameraMode) { _, mode in isCameraOpen.wrappedValue = mode != nil || isLocationIntroUp }
        .onChange(of: isLocationIntroUp) { _, up in isCameraOpen.wrappedValue = up || cameraMode != nil }
        // A permission given (or taken back) in iOS's prompt or in Settings: start or stop following.
        .onChange(of: store.worldLocation.permission) { updateLocation() }
    }

    // MARK: Location off

    /// The open scene with location off (`b1-home-denied`, draft 4).
    private func offHome(date: Date) -> some View {
        WorldOffMapHome(store: store, date: date, status: WorldStatus.current(store: store, date: date), onOpen: onOpen,
                        onOpenPrint: openPrint) {
            WorldMapCompanion(store: store, bodySignal: bodySignal, isActive: isFrontmost && !isCustomizing,
                              mapLine: mapLine, pixelScale: dynamicTypeSize.isAccessibilitySize ? 6 : 7,
                              isNight: phase(at: date) == .night, hint: isHintShowing, onHintEnded: endHint) {
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
            WorldHomesLayer(store: store, viewport: viewport, size: size, isNight: phase(at: Date()) == .night)
            ForEach(shownMarkers) { marker in
                WorldMapMarkerView(marker: marker, resolvedName: store.worldPlaces.eatingNames[marker.id]) { open(marker) }
                    .fixedSize()
                    .position(viewport.screenPoint(for: marker.point, in: size))
            }
            ForEach(shownPhotoPlaces) { place in
                WorldPhotoMarkerView(place: place) { openPhotoPlace = place }
                    .fixedSize()
                    .position(viewport.screenPoint(for: place.point, in: size))
            }
            ForEach(Array(nearbyFriends.enumerated()), id: \.element.id) { index, friend in
                WorldNearbyFriendView(friend: friend)
                    .fixedSize()
                    .position(x: point.x + (index == 0 ? 92 : -92), y: point.y + 40)
            }
            companion(at: point)
            WorldCompanionExtras(store: store, point: point, date: Date())
        }
    }

    /// A print on the photo wall: its photo in the Album's carousel (`ref-wall-photo`), or the Album for an
    /// empty print.
    private func openPrint(_ route: FriendsRoute?) {
        if let route { onFriends(route) } else { onOpen(.friends) }
    }

    /// The companion with its bubble, its feet on `point`.
    private func companion(at point: CGPoint) -> some View {
        WorldMapCompanion(store: store, bodySignal: bodySignal, isActive: isFrontmost && !isCustomizing, mapLine: mapLine,
                          isQuiet: isBubbleQuiet, isNight: phase(at: Date()) == .night, hint: isHintShowing, onHintEnded: endHint) {
            isCustomizing = true
        }
        // Measured at the bubble's own wrap width, so a line of two or three rows is measured as it is
        // drawn and the feet stay on `point` (an unbounded measure took one row and pushed the sprite
        // down by the rest, off the house, the z's and the suitcase that stand at `point`).
        .frame(width: 236)
        .fixedSize(horizontal: false, vertical: true)
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
                    WorldPhotoPrints(store: store, onOpen: openPrint)
                        .padding(.trailing, -2)
                }
            }
            if isWalking {
                WorldWalkBar(metres: walkMetres, kind: store.worldWalk.kind, onEnd: endWalk)
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
                HStack(alignment: .bottom, spacing: 10) {
                    // Round 6 (`ref-tag-home`): beside the blue button at a spot Fernlet refused.
                    if cardContext == nil, let spot = store.worldRefusedSpot(near: store.worldLocation.latest) {
                        // Above the blue button's label, which slides out over it for 30 s (form answer 28).
                        WorldTagPlaceButton { placeSheet = .remember(start: spot, kind: .place) }
                            .zIndex(1)
                    }
                    if let glyph = WorldQuickStart.glyph(for: buttonContext) {
                        WorldQuickStartButton(glyph: glyph, spokenStatus: WorldQuickStartCopy.spokenStatus(WorldQuickStart.card(for: buttonContext)),
                                              action: toggleCard)
                    }
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

    /// On or off, precise or approximate (a DEBUG screenshot can ask for approximate). Before the person
    /// answers (the intro still to come, or iOS's prompt up) it is the first day's map, not the off scene.
    private var presence: WorldMapPresence {
        let location = store.worldLocation
        let awaits = !WorldMapPreferences.locationIntroAnswered() || location.isAsking
        let real = WorldMapPresence.make(permission: location.permission, isPrecise: location.isPrecise, awaitsAnswer: awaits)
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
        let now = Date()
        facts.isNight = phase(at: now) == .night || WorldMapCompanion.isPastBedtime(store: store, at: now)
        facts.homeGreeting = homeGreeting
        return WorldMapLine.line(facts)
    }

    /// What the ground draws: the lifted fog, and the walk's line while it records.
    private var ground: WorldGround {
        let trace = isWalking ? store.worldWalk.points.map(\.point) : []
        return WorldGround(lifted: store.worldFog.visibleCells, uncovered: uncovered,
                           trails: isWalking && guideLine.count >= 2 ? [guideLine] : [], traces: trace.count >= 2 ? [trace] : [])
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

    /// The solo photos' places on the map (a DEBUG screenshot, `photo`, stands three photos in beside the
    /// companion, display only, where a photo taken here would keep its place).
    private var shownPhotoPlaces: [WorldPhotoPlace] {
        guard testScenes.contains("photo"), testPhotoKept, !store.duressSessionActive,
              let fix = store.worldLocation.latest else { return photoPlaces }
        return photoPlaces + [WorldPhotoPlace(id: UUID(uuidString: "5C000000-0000-0000-0000-000000000001") ?? UUID(),
                                              point: fix.point.offset(east: 110, north: 140), photoIDs: [UUID(), UUID(), UUID()])]
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
    /// screenshots only, `solo` (the camera of your own), `friend` (Sam nearby, as the map stands him in)
    /// or `session` (a session with Sam and Rae), display only; the scene list is empty in release builds.
    private func staged(_ context: WorldQuickStartContext) -> WorldQuickStartContext {
        var context = context
        context.savedLine = savedLineHere?.summary
        context.eatingPlace = store.worldEatingOut(near: store.worldLocation.latest)
        if testScenes.contains("restaurant"), !context.isDecoy { context.eatingPlace = WorldPlacesTestScenes.restaurant }
        if testScenes.contains("solo") { context.soloCameraAvailable = true }
        if testScenes.contains("run") { context.savedLine = WorldQuickStartContext.SavedLine(metres: 3_200, walks: 8, kind: .run) }
        if testScenes.contains("friend"), context.canMeetFriends { context.nearbyFriends = nearbyFriends.map(\.firstName) }
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

    /// Opens the card for `spaceID` (where the person stands, or a tapped marker's space), or for the
    /// place to eat `eatingID` whose icon was tapped.
    private func openCard(spaceID: UUID?, eatingID: UUID? = nil) {
        readSavedLine()
        var context = staged(store.worldQuickStartContext(spaceID: spaceID, includingPlans: true))
        if let eatingID { context.eatingPlace = store.worldEatingOut(id: eatingID) }
        cardContext = context
    }

    /// A kept place's icon (`ref-places-map`): the photos taken there when it holds any, else its card.
    private func open(_ marker: WorldMapMarker) {
        if let photos = marker.photos {
            openPhotoPlace = photos
            return
        }
        switch marker.kind {
        case .space: openCard(spaceID: marker.id)
        case .eatingPlace: openCard(spaceID: nil, eatingID: marker.id)
        }
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
        let placeName = cardContext?.space?.name
        let eatingID = cardContext?.eatingPlace?.id
        closeCard()
        switch option {
        case .logUsual:
            // The usual, logged again in one tap; it reaches the toast like any meal log.
            guard let eatingID, let usual = store.worldUsualMeal(at: eatingID) else { return }
            onMealsLogged([store.copyMeal(usual, mealType: store.worldUsualMealType(for: usual))])
        case .findMenu:
            menuSearch = eatingID.flatMap(store.worldMenuSearchSeed(at:)).map { WorldMenuSearch(seed: $0) }
        case .todaysPlan:
            if let spaceID { guidedSession = store.startTodaysPlan(at: spaceID) }
        case .suggestWorkout:
            if let spaceID { store.prepareSuggestion(at: spaceID) }
            onSheet(.workoutSuggestion)
        case .gentleStretch:
            guidedSession = store.todaysGentleStretch(committing: true)
        case .walkTogether:
            // Walk or run together (`ref-run-first`): the pace decides which it is logged as.
            startWalk(decidesByPace: true)
        case .walkSavedLine:
            guideLine = savedLineHere?.points ?? []
            startWalk()
        case .runSavedLine:
            guideLine = savedLineHere?.points ?? []
            startWalk(kind: .run)
        case .sessionCamera:
            cameraMode = .session
        case .soloCamera:
            cameraMode = .solo(placeName: placeName)
        case .backToWorkout:
            guidedSession = store.guidedSessionForResume()
        case .startSession, .friendsNearby:
            onFriends(.nearby)
        case .startActivity:
            onFriends(.activities)
        }
    }

    // MARK: Walking together

    /// Starts Walk or run together (or a saved walk or run again): the recorder, and location for it.
    private func startWalk(kind: WorldWalkRecorder.Kind = .walk, decidesByPace: Bool = false) {
        loggedWalk = nil
        store.startWorldWalk(kind: kind, decidesByPace: decidesByPace)
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
        FernletAnnouncer.system.announce(.status, resolved: String(localized: walk.kind == .run ? WorldWalkCopy.undoneRun : WorldWalkCopy.undone))
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
            homeGreeting = nil
            return
        }
        store.worldFog.load()
        readPlaces()
        readSavedLine()
        location.startForeground()
        follow(location.latest)
    }

    /// Reads the kept places as the map comes to the front (round 6): the meals just logged at a place to
    /// eat, the homes and hotel, every kept place's icon with its photos and the photos elsewhere, the
    /// circles drawn clear round them, and Sprout's greeting when one waits.
    private func readPlaces() {
        let latest = store.worldLocation.latest
        store.noteWorldMealsEatenOut()
        store.reloadWorldHomes()
        let placed = store.worldPlaceMarkers(near: latest)
        markers = placed.markers
        photoPlaces = placed.loosePhotos
        uncovered = store.worldUncoveredCells(markers: placed.markers)
        if let greeting = store.takeWorldHomeGreeting() { homeGreeting = greeting }
        Task { await store.worldPlaces.resolveEatingNames() }
    }

    /// Moves the camera to a new reading while it follows the person. With approximate location the
    /// camera stands back to show the area, never a street.
    private func follow(_ fix: WorldFix?) {
        if homeGreeting == nil, isFrontmost, let greeting = store.takeWorldHomeGreeting() { homeGreeting = greeting }
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

    /// Whether the one-time companion hint should show (`ref-hint`): after the location question, never
    /// under the intro, iOS's prompt or a stamp banner, never in a decoy. Under a test harness only when a
    /// screenshot asks for it (`FERNLET_UI_TEST_WORLD_HOME=hint`).
    private var isHintDue: Bool {
        let asked = testScenes.contains("hint")
        guard !UITestSupport.isTestHarnessActive || asked else { return false }
        return WorldCompanionHint.isDue(alreadyShown: WorldMapPreferences.companionHintShown(),
                                        introAnswered: WorldMapPreferences.locationIntroAnswered() || asked,
                                        permission: store.worldLocation.permission, isAsking: store.worldLocation.isAsking,
                                        stampBannerShowing: stampBannerShowing,
                                        isFrontmost: isFrontmost && scenePhase == .active && !isLocationIntroUp,
                                        isDecoy: store.duressSessionActive)
    }

    /// The hint ended (a tap, or its 12 seconds): it never shows again on this iPhone (a decoy keeps nothing).
    private func endHint() {
        isHintShowing = false
        guard !store.duressSessionActive else { return }
        WorldMapPreferences.setCompanionHintShown()
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
        // The camera on your own, as the blue button opens it (`FERNLET_UI_TEST_SOLO_CAMERA`).
        if FriendsUITestHooks.opensSoloCamera, !store.meshNetworkManager.isInSession { cameraMode = .solo(placeName: nil) }
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
        if scenes.contains("photo") { await checkTestPhotoPlace() }
        applyPlacesTestScenes(scenes)
    }

    /// DEBUG round 6 scenes (``WorldPlacesTestScenes``): Sprout's welcome-home line, and the Remember this
    /// place / Put on the map sheet open where the person stands. Display only.
    private func applyPlacesTestScenes(_ scenes: Set<String>) {
        if scenes.contains("greeting") {
            let hotel = scenes.contains("hotel")
            homeGreeting = WorldHomeMapCopy.greeting(HomeGreeting(kind: hotel ? .hotelAgain : .cameHome, placeID: UUID()),
                                                     place: HomePlace(kind: hotel ? .hotel : .home, label: hotel ? "Ace" : "Home",
                                                                      point: WorldPlacesTestScenes.laurelhurst))
        }
        let here = store.worldLocation.latest?.point ?? WorldPlacesTestScenes.laurelhurst
        if scenes.contains("tagSheet") { placeSheet = .remember(start: here, kind: .place) }
        if scenes.contains("homeSheet") { placeSheet = .remember(start: here, kind: .home) }
        if scenes.contains("photoSheet") { placeSheet = .photo(id: UUID(), start: here, takenAt: Date()) }
    }

    /// DEBUG `photo`: the stand-in photos sit on the map only where a photo taken here would keep its
    /// place: the camera's own lookup and rule at the shutter (``PlaceClassifier/photoMayKeepPlace(_:)``,
    /// round 5), asked once the first reading arrives (waiting at most 15 s for it).
    private func checkTestPhotoPlace() async {
        for _ in 0..<15 where store.worldLocation.latest == nil {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
        }
        guard let fix = store.worldLocation.latest else { return }
        let nearby = await store.worldPlaceLookup.nearbyPlaces(around: fix.point)
        testPhotoKept = PlaceClassifier.photoMayKeepPlace(nearby)
        FernletAuditLog.log("worldMap.photoPlace.testScene", context: ["kept": testPhotoKept ? "yes" : "no"])
    }
}
