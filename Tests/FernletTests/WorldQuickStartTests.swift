import Foundation
import Testing
import AppServices
import FernletDomainModel
import WorldMapStore
@testable import Fernlet

/// The World Home's blue quick-start button and its map states (World app plan step 6b; designs
/// `b1-qs-*`, `b3-qs-*`, `b1-home-*`): the card's rules, the map's notices and lines, the space match,
/// and a walk ended from the walk bar, in a decoy too.
@MainActor
struct WorldQuickStartTests {
    private static let gym = WorldQuickStartContext.Space(id: UUID(), name: "Full gym",
                                                          equipment: "Cardio, Free weights, Machines", itemCount: 22)

    /// A context where walking is possible and nothing else is going on.
    private static func anywhere() -> WorldQuickStartContext {
        var context = WorldQuickStartContext()
        context.canWalk = true
        return context
    }

    // MARK: The card's rules

    /// Anywhere without a pin: Walk together alone, with the "nothing saved" line; no walk, no button.
    @Test func anywhereOffersTheWalkAndHidesWithoutIt() throws {
        let card = try #require(WorldQuickStart.card(for: Self.anywhere()))
        #expect(card.heading == .walk && card.note == .nothingSaved && card.options == [.walkTogether])
        #expect(WorldQuickStart.glyph(for: Self.anywhere()) == .walk)
        #expect(WorldQuickStart.card(for: WorldQuickStartContext()) == nil, "location off must hide the button")
        #expect(WorldQuickStart.glyph(for: WorldQuickStartContext()) == nil)
    }

    /// At a pinned space: Move's suggestion with nothing planned (and the space's item count), today's
    /// plan when there is one, then the walk.
    @Test func aSpaceOffersTodaysPlanOrTheSuggestionThenTheWalk() throws {
        var context = Self.anywhere()
        context.space = Self.gym
        let unplanned = try #require(WorldQuickStart.card(for: context))
        #expect(unplanned.heading == .space("Full gym") && unplanned.note == .nothingPlanned(items: 22))
        #expect(unplanned.options == [.suggestWorkout(space: "Full gym", equipment: "Cardio, Free weights, Machines", gentle: false),
                                      .walkTogether])
        context.plannedSession = "Full body"
        let planned = try #require(WorldQuickStart.card(for: context))
        #expect(planned.note == nil && planned.options.first == .todaysPlan(space: "Full gym", session: "Full body"))
        #expect(WorldQuickStart.glyph(for: context) == .space)
    }

    /// A resting or unwell day: "Resting counts today" first and the gentle stretch leading; at a space
    /// the workout stays, gently; elsewhere the walk stays.
    @Test func aRestingDayLeadsWithTheGentleChoices() throws {
        var context = Self.anywhere()
        context.isResting = true
        context.hasGentleStretch = true
        let away = try #require(WorldQuickStart.card(for: context))
        #expect(away.heading == .gentle && away.note == .restingCounts && away.options == [.gentleStretch, .walkTogether])
        #expect(WorldQuickStart.glyph(for: context) == .rest)
        context.space = Self.gym
        let atGym = try #require(WorldQuickStart.card(for: context))
        #expect(atGym.options == [.gentleStretch, .suggestWorkout(space: "Full gym", equipment: "Cardio, Free weights, Machines", gentle: true)])
        #expect(WorldQuickStart.glyph(for: context) == .rest)
    }

    /// In a session: the session's camera first, then the walk; the heading names the friends.
    @Test func aSessionOffersItsCameraThenTheWalk() throws {
        var context = Self.anywhere()
        context.session = WorldQuickStartContext.Session(names: ["Sam", "Rae"], shotsLeft: 3)
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .session(["Sam", "Rae"]) && card.options == [.sessionCamera(shotsLeft: 3), .walkTogether])
        #expect(WorldQuickStart.glyph(for: context) == .camera)
    }

    /// During a walk: the camera when there is one (the session's, else the one of your own), and no
    /// button at all without one; during a workout: the camera and the way back.
    @Test func duringAWalkOrWorkoutTheButtonOffersTheCamera() throws {
        var context = Self.anywhere()
        context.activity = .walking
        #expect(WorldQuickStart.card(for: context) == nil, "no camera of your own yet: the walk bar holds End")
        context.soloCameraAvailable = true
        #expect(WorldQuickStart.card(for: context)?.options == [.soloCamera])
        context.session = WorldQuickStartContext.Session(names: ["Sam"], shotsLeft: 5)
        #expect(WorldQuickStart.card(for: context)?.options == [.sessionCamera(shotsLeft: 5)])
        context = Self.anywhere()
        context.activity = .workout(title: "Full body")
        #expect(WorldQuickStart.card(for: context)?.options == [.backToWorkout(title: "Full body")])
        #expect(WorldQuickStart.glyph(for: context) == .space)
        context.soloCameraAvailable = true
        #expect(WorldQuickStart.card(for: context)?.options == [.soloCamera, .backToWorkout(title: "Full body")])
        #expect(WorldQuickStart.glyph(for: context) == .camera)
    }

    /// A decoy offers only the walk: never a space, a session's camera or a gentle day, and nothing at
    /// all while it walks.
    @Test func aDecoyOffersOnlyTheWalk() throws {
        var context = Self.anywhere()
        context.isDecoy = true
        context.space = Self.gym
        context.isResting = true
        context.session = WorldQuickStartContext.Session(names: ["Sam"], shotsLeft: 5)
        #expect(WorldQuickStart.card(for: context)?.options == [.walkTogether])
        context.activity = .walking
        #expect(WorldQuickStart.card(for: context) == nil)
    }

    /// Where a saved walk starts: walk it again (the tree); a space outranks it, and it needs the walk.
    @Test func aSavedWalkStartingHereOffersItAgain() throws {
        var context = Self.anywhere()
        context.savedLine = WorldQuickStartContext.SavedLine(metres: 1_000, walks: 3)
        let card = try #require(WorldQuickStart.card(for: context))
        #expect(card.heading == .savedLine && card.note == .walkedFromHere(times: 3) && card.options == [.walkSavedLine(metres: 1_000)])
        #expect(WorldQuickStart.glyph(for: context) == .trail)
        context.space = Self.gym
        #expect(WorldQuickStart.card(for: context)?.heading == .space("Full gym"), "a space outranks a saved line")
        context.space = nil
        context.canWalk = false
        #expect(WorldQuickStart.card(for: context) == nil)
    }

    // MARK: The map's states

    /// Off until allowed (not asked counts as off; nothing on Home asks), approximate or precise.
    @Test func thePresenceFollowsThePermission() {
        #expect(WorldMapPresence.make(permission: .notAsked, isPrecise: true) == .off)
        #expect(WorldMapPresence.make(permission: .denied, isPrecise: true) == .off)
        #expect(WorldMapPresence.make(permission: .whileUsing, isPrecise: false) == .approximate)
        #expect(WorldMapPresence.make(permission: .always, isPrecise: true) == .precise)
    }

    /// One notice, most important first; the first-day plate only while little is uncovered, never in a
    /// decoy, during a walk or with uncovering off.
    @Test func theNoticesComeInOrder() {
        func notice(_ presence: WorldMapPresence = .precise, tiles: WorldTileState = .ready, long: Bool = false,
                    cells: Int = 500, uncovers: Bool = true, decoy: Bool = false, walking: Bool = false) -> WorldMapNoticeKind? {
            WorldMapNoticeKind.make(presence: presence, tiles: tiles, loadingLong: long, liftedCells: cells,
                                    uncovers: uncovers, isDecoy: decoy, isWalking: walking)
        }
        #expect(notice(.off, tiles: .failed) == nil)
        #expect(notice(.approximate, tiles: .failed) == .offline)
        #expect(notice(.approximate, tiles: .loading, long: true) == .approximate)
        #expect(notice(tiles: .loading, long: false) == nil)
        #expect(notice(tiles: .loading, long: true) == .loading)
        #expect(notice(cells: 10) == .firstDay)
        #expect(notice(cells: 10, decoy: true) == nil)
        #expect(notice(cells: 10, walking: true) == nil)
        #expect(notice(cells: 10, uncovers: false) == nil)
        #expect(notice(cells: WorldMapNoticeKind.firstDayCellLimit + 1) == nil)
    }

    /// The tile status: loading, loaded, failed; a failure stays until tiles load.
    @Test func theTileStatusTracksMapKit() {
        let status = WorldTileStatus()
        status.loading()
        #expect(status.state == .loading && status.loadingSince != nil)
        status.failed()
        status.loading()
        #expect(status.state == .failed, "a retry must not hide the offline plate before tiles arrive")
        status.loaded()
        #expect(status.state == .ready && status.loadingSince == nil)
    }

    /// The map's line: a stamp waiting keeps the usual line; then a friend, an unwell day, the weather,
    /// and where the map is.
    @Test func theMapsLineFollowsItsOrder() {
        var facts = WorldMapLine.Facts()
        #expect(WorldMapLine.line(facts) == nil)
        facts.presence = .approximate
        #expect(WorldMapLine.line(facts) != nil)
        let approximate = WorldMapLine.line(facts)
        facts.isOffline = true
        #expect(WorldMapLine.line(facts) != approximate, "offline speaks before approximate")
        facts.sky = .rain
        let rain = WorldMapLine.line(facts)
        facts.isUnwell = true
        let unwell = WorldMapLine.line(facts)
        facts.friendName = "Sam"
        let friend = WorldMapLine.line(facts)
        #expect(Set([rain, unwell, friend]).count == 3)
        #expect(friend?.contains("Sam") == true)
        facts.stampWaiting = true
        #expect(WorldMapLine.line(facts) == nil, "a stamp just earned speaks first")
        #expect(WorldMapLine.line(WorldMapLine.Facts(sky: .clouds)) == nil, "clouds say nothing of their own")
    }

    /// The space match: within 100 m of a pin, from a precise reading only, nearest first.
    @Test func theSpaceMatchNeedsAPreciseReadingWithin100m() {
        let here = GeoPoint(45.5205, -122.6255)
        let near = WorldMapMarker(id: UUID(), kind: .space, name: "Full gym", point: here.offset(east: 60, north: 0))
        let nearer = WorldMapMarker(id: UUID(), kind: .space, name: "Home", point: here.offset(east: 20, north: 0))
        let far = WorldMapMarker(id: UUID(), kind: .space, name: "Far", point: here.offset(east: 300, north: 0))
        let precise = WorldFix(point: here, accuracy: 5, at: Date(), isPrecise: true)
        #expect(WorldMapMarker.space(near: precise, in: [near, nearer, far]) == nearer.id)
        #expect(WorldMapMarker.space(near: precise, in: [far]) == nil)
        let rough = WorldFix(point: here, accuracy: 900, at: Date(), isPrecise: false)
        #expect(WorldMapMarker.space(near: rough, in: [nearer]) == nil)
        #expect(WorldMapMarker.space(near: nil, in: [nearer]) == nil)
    }

    /// The camera looks a little north of the person, so the companion stands about 58% of the way
    /// down the map (the approved Home), and it scales with the zoom.
    @Test func theCameraStandsTheCompanionBelowTheMiddle() {
        let here = GeoPoint(45.5205, -122.6255)
        let near = WorldMapHome.lookAt(here, distance: 1_700).metres(from: here)
        #expect(abs(near.east) < 0.01)
        #expect(abs(near.north - 1_700 * PlainBaseMap.heightPerDistance * WorldMapHome.companionDrop) < 0.5)
        let far = WorldMapHome.lookAt(here, distance: 5_000).metres(from: here)
        #expect(far.north > near.north * 2.5, "zoomed out, the same share of the screen is more ground")
    }

    // MARK: The walk bar's End

    /// End logs the walk and its toast carries what Undo needs; Undo removes it.
    @Test func endLogsTheWalkAndUndoRemovesIt() throws {
        let store = makeTestStore()
        let defaults = try #require(UserDefaults(suiteName: "WorldQuickStartTests.\(UUID().uuidString)"))
        Self.recordWalk(store)
        let walk = try #require(store.endWorldWalk(at: Date().addingTimeInterval(6 * 60), defaults: defaults))
        #expect(walk.isKept && walk.minutes == 6 && abs(walk.metres - 200) < 20)
        #expect(store.day.workouts.contains { $0.id == walk.id })
        #expect(store.undoWorldWalk(walk))
        #expect(!store.day.workouts.contains { $0.id == walk.id })
    }

    /// A decoy's walk leaves nothing behind: no workout, no line; Undo has nothing to remove.
    @Test func aDecoyWalkLeavesNothingBehind() throws {
        let store = makeTestStore()
        let defaults = try #require(UserDefaults(suiteName: "WorldQuickStartTests.\(UUID().uuidString)"))
        let before = store.day.workouts.count
        store.duressSessionActive = true
        Self.recordWalk(store)
        let walk = try #require(store.endWorldWalk(at: Date().addingTimeInterval(120), defaults: defaults))
        #expect(!walk.isKept && store.day.workouts.count == before)
        #expect(try store.worldRoutes.workoutIDs().isEmpty)
        #expect(!store.undoWorldWalk(walk))
        store.duressSessionActive = false
        #expect(store.endWorldWalk(defaults: defaults) == nil, "no walk is running")
    }

    /// The saved-line search finds a walk that started within 100 m, and nothing far away or in a decoy.
    @Test func theSavedLineSearchFindsWalksStartingHere() throws {
        let store = makeTestStore()
        let defaults = try #require(UserDefaults(suiteName: "WorldQuickStartTests.\(UUID().uuidString)"))
        Self.recordWalk(store)
        let walk = try #require(store.endWorldWalk(at: Date().addingTimeInterval(5 * 60), defaults: defaults))
        let here = GeoPoint(45.5205, -122.6255)
        let line = try #require(store.worldSavedLine(startingNear: here.offset(east: 30, north: 0)))
        #expect(line.workoutID == walk.id && line.walks == 1 && abs(line.metres - 200) < 20)
        #expect(line.summary == WorldQuickStartContext.SavedLine(metres: line.metres, walks: 1))
        #expect(store.worldSavedLine(startingNear: here.offset(east: 500, north: 0)) == nil)
        store.duressSessionActive = true
        #expect(store.worldSavedLine(startingNear: here) == nil)
        store.duressSessionActive = false
    }

    /// The context in a decoy: no space, no session, only the walk's facts.
    @Test func theContextShowsADecoyNothingReal() {
        let store = makeTestStore()
        store.settings.workoutLocations = [WorkoutLocation.fullGym]
        let gymID = store.settings.workoutLocations[0].id
        #expect(store.worldQuickStartContext(spaceID: gymID, includingPlans: false).space?.name.isEmpty == false)
        store.duressSessionActive = true
        let decoy = store.worldQuickStartContext(spaceID: gymID, includingPlans: false)
        #expect(decoy.isDecoy && decoy.space == nil && decoy.session == nil)
        #expect(store.worldSpaceMarkers(near: nil).isEmpty)
        #expect(store.worldNearbyFriends.isEmpty)
        store.duressSessionActive = false
    }

    /// A 200 m walk east, recorded from good readings.
    private static func recordWalk(_ store: FernletStore) {
        let start = Date()
        store.startWorldWalk(at: start)
        for east in stride(from: 0.0, through: 200, by: 5) {
            store.worldWalk.record(WorldFix(point: GeoPoint(45.5205, -122.6255).offset(east: east, north: 0),
                                            accuracy: 5, at: start, isPrecise: true))
        }
    }
}
