import CryptoKit
import FernletDomainModel
import Foundation
import Testing
import PrivateMediaStore
import WorldMapStore
@testable import Fernlet

/// World build step 5c: "Where you've been" (the place rules, the sealed log under the hub key, the device
/// side and its capture), the solo photos' places, the map intro's and the companion hint's rules.
@MainActor
struct WorldPlacesTests {
    private static let park = GeoPoint(45.5213, -122.6253)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: The device's rules

    /// A visit names only the nearest place, only when it is an allowed kind and its name refuses nothing;
    /// a refused nearest place refuses the visit even beside a café.
    @Test func aVisitNamesOnlyTheNearestAllowedPlace() {
        let cafe = NearbyPlace(name: "Hoshi Noodle Bar", kind: .allowed(.foodAndDrink), metres: 12)
        let clinic = NearbyPlace(name: "Riverside Family Clinic", kind: .other, metres: 8)
        let shop = NearbyPlace(name: "Corner Shop", kind: .other, metres: 5)
        #expect(PlaceClassifier.visitVerdict([cafe]) == .allowed(.foodAndDrink, name: "Hoshi Noodle Bar"))
        #expect(PlaceClassifier.visitVerdict([cafe, clinic]) == .refused, "a clinic nearer than the café")
        #expect(PlaceClassifier.visitVerdict([cafe, shop]) == .unnamed)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Ortiz Law Office", kind: .other, metres: 3)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Centro de Terapia", kind: .other, metres: 3)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Mercy Hospital", kind: .refused, metres: 30)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Far Café", kind: .allowed(.foodAndDrink), metres: 70)]) == .unnamed)
        #expect(PlaceClassifier.visitVerdict([]) == .unnamed)
    }

    /// Inside a park, far from its one point and with nothing else near, the park names the visit; a
    /// refused place within 80 m still refuses it; a café that far never names it.
    @Test func anAreaNamesAVisitFromInside() {
        let park = NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 210)
        #expect(PlaceClassifier.visitVerdict([park]) == .allowed(.park, name: "Laurelhurst Park"))
        #expect(PlaceClassifier.visitVerdict([park, NearbyPlace(name: "Park Clinic", kind: .other, metres: 70)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([park, NearbyPlace(name: "Corner Shop", kind: .other, metres: 30)]) == .unnamed,
                "the shop is the nearest place, so the visit is there")
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Café", kind: .allowed(.foodAndDrink), metres: 120)]) == .unnamed)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Far Park", kind: .allowed(.park), metres: 400)]) == .unnamed)
    }

    /// A solo photo keeps its place only when a lookup answered and no refused place is within 60 m.
    @Test func aPhotoKeepsItsPlaceOnlyAwayFromRefusedPlaces() {
        #expect(!PlaceClassifier.photoMayKeepPlace(nil), "offline: a refused place can't be ruled out")
        #expect(PlaceClassifier.photoMayKeepPlace([]))
        #expect(PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 20)]))
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Dr. Lee Dental", kind: .other, metres: 40)]))
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Walgreens", kind: .refused, metres: 55)]))
        #expect(PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Walgreens", kind: .refused, metres: 90)]))
    }

    // MARK: The log and its device side

    /// A fold adds new places, counts each visit once (a stop already folded is not counted again), and
    /// drops stops older than 30 days.
    @Test func aFoldCountsEachVisitOnceAndKeepsThirtyDays() {
        let place = PlaceRecord(name: "Laurelhurst Park", category: .park, point: Self.park)
        let old = PlaceStop(kind: .visit, at: Self.now.addingTimeInterval(-40 * 86_400), placeID: place.id)
        let device = PlaceDeviceState.empty.learning(place, at: Self.now)
            .appending(PlaceStop(kind: .walk, at: Self.now, metres: 900, workoutID: UUID()))
            .appending(old)
        let log = PlaceLog.empty.folding(device, now: Self.now)
        #expect(log.places.map(\.visits) == [1], "a stop that waited past the 30 days is not counted")
        #expect(log.stops.count == 2, "and it never reaches the timeline")
        let again = log.folding(device, now: Self.now)
        #expect(again.places.first?.visits == 1, "a fold cut short and run again counts nothing twice")
        #expect(log.returnedTo.map(\.name) == ["Laurelhurst Park"])
    }

    /// Deleting a day takes its visits off the counts, removes a place left with none, and names the
    /// day's walks so their lines can go.
    @Test func deletingADayTakesItsVisitsAndNamesItsWalks() {
        let place = PlaceRecord(name: "Gym", category: .gym, point: Self.park)
        let walkID = UUID()
        let device = PlaceDeviceState.empty.learning(place, at: Self.now)
            .appending(PlaceStop(kind: .walk, at: Self.now.addingTimeInterval(60), metres: 500, workoutID: walkID))
        let log = PlaceLog.empty.folding(device, now: Self.now)
        let day = Calendar.current.startOfDay(for: Self.now)
        let result = log.deletingDay(day)
        #expect(result.log.stops.isEmpty && result.log.places.isEmpty)
        #expect(result.workoutIDs == [walkID])
        #expect(result.removedPlaces == [place.id])
        #expect(log.renaming(place.id, to: "  My gym ").places.first?.name == "My gym")
        #expect(log.renaming(place.id, to: "   ").places.first?.name == "Gym", "an empty name changes nothing")
    }

    /// Visits to one place within three hours count once; a known place matches within 75 m; the waiting
    /// stops are capped.
    @Test func theDeviceSideMatchesDedupesAndIsBounded() {
        let place = PlaceRecord(name: "Park", category: .park, point: Self.park)
        let state = PlaceDeviceState.empty.learning(place, at: Self.now)
        #expect(state.knownPlace(near: Self.park.offset(east: 60, north: 0))?.id == place.id)
        #expect(state.knownPlace(near: Self.park.offset(east: 90, north: 0)) == nil)
        #expect(state.recordingVisit(to: place.id, at: Self.now.addingTimeInterval(3_600)) == state)
        #expect(state.recordingVisit(to: place.id, at: Self.now.addingTimeInterval(4 * 3_600)).pending.count == 2)
        var full = PlaceDeviceState.empty
        for index in 0..<(PlaceDeviceState.maxPending + 5) {
            full = full.appending(PlaceStop(kind: .walk, at: Self.now.addingTimeInterval(Double(index)), metres: 1))
        }
        #expect(full.pending.count == PlaceDeviceState.maxPending)
        #expect(full.pending.first?.at == Self.now.addingTimeInterval(5), "the oldest went first")
    }

    /// The log opens only with the hub key it was sealed with; under another key it reads empty and is
    /// removed. A fold moves the waiting stops under the hub key and clears them from the device side.
    @Test func theLogOpensOnlyUnderItsHubKey() throws {
        let vault = WorldMapVault.ephemeral()
        let store = PlaceLogStore(vault: vault)
        let key = SymmetricKey(size: .bits256)
        let place = PlaceRecord(name: "Park", category: .park, point: Self.park)
        try store.saveDeviceState(PlaceDeviceState.empty.learning(place, at: Self.now))
        let folded = try store.fold(hubKey: key, now: Self.now)
        #expect(folded.places.count == 1)
        #expect(try store.deviceState().pending.isEmpty, "the fold cleared what waited")
        #expect(try store.deviceState().known.count == 1, "the point stays for matching")
        #expect(try store.log(hubKey: key) == folded)
        #expect(try store.log(hubKey: SymmetricKey(size: .bits256)) == .empty, "another key opens nothing")
        #expect(try store.log(hubKey: key) == .empty, "and the unopenable log was removed")
        #expect(store.deleteAll())
        #expect(vault.clearAll())
    }

    /// Photo places: kept, read, removed with their photo, and all removed at once.
    @Test func photoPlacesFollowTheirPhotos() throws {
        let vault = WorldMapVault.ephemeral()
        let places = PhotoPlaceStore(vault: vault)
        let first = UUID(), second = UUID()
        #expect(try places.setPlace(Self.park, for: first))
        #expect(try places.setPlace(Self.park.offset(east: 500, north: 0), for: second))
        #expect(try places.place(for: first) == Self.park)
        try places.remove([first])
        #expect(try places.place(for: first) == nil && places.all().count == 1)
        #expect(places.removeAll())
        #expect(try places.all().isEmpty)
        #expect(!(try places.setPlace(GeoPoint(200, 0), for: first)), "an invalid point is refused")
    }

    // MARK: Capture

    /// Open on the map at a park: the lookup is asked once, the park is learned with its name, and the
    /// next reading there is the same visit, without asking again. A refused place is never learned.
    @Test func theMapLearnsAnAllowedPlaceOnce() async throws {
        let lookup = CountingLookup(answer: [NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 10)])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup)
        let fix = WorldFix(point: Self.park, accuracy: 10, at: Self.now, isPrecise: true)
        #expect(await keeper.handleForeground(fix, now: Self.now))
        #expect(!(await keeper.handleForeground(fix, now: Self.now.addingTimeInterval(60))), "the same visit")
        #expect(lookup.calls == 1)
        let state = try keeper.store.deviceState()
        #expect(state.newPlaces.map(\.name) == ["Laurelhurst Park"] && state.pending.count == 1)

        let refused = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(),
                                        lookup: CountingLookup(answer: [NearbyPlace(name: "Lakeside Therapy", kind: .other, metres: 5)]))
        #expect(!(await refused.handleForeground(fix, now: Self.now)))
        #expect(try refused.store.deviceState() == .empty, "a therapist's office is never kept")
    }

    /// Approximate or poor readings, and a decoy, note nothing and ask nothing.
    @Test func poorReadingsAndADecoyNoteNothing() async throws {
        let lookup = CountingLookup(answer: [NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 10)])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup)
        #expect(!(await keeper.handleForeground(WorldFix(point: Self.park, accuracy: 10, at: Self.now, isPrecise: false))))
        #expect(!(await keeper.handleForeground(WorldFix(point: Self.park, accuracy: 120, at: Self.now, isPrecise: true))))
        keeper.setDecoy(true)
        #expect(!(await keeper.handleForeground(WorldFix(point: Self.park, accuracy: 10, at: Self.now, isPrecise: true))))
        #expect(!keeper.recordOuting(.walk, at: Self.now, metres: 500, workoutID: nil))
        #expect(lookup.calls == 0)
        keeper.setDecoy(false)
        #expect(try keeper.store.deviceState() == .empty)
    }

    /// Background visits match known places only: a stop somewhere new is not kept, and never looked up.
    @Test func backgroundVisitsMatchOnlyKnownPlaces() throws {
        let lookup = CountingLookup(answer: [])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup)
        let place = PlaceRecord(name: "Park", category: .park, point: Self.park)
        try keeper.store.saveDeviceState(PlaceDeviceState.empty.learning(place, at: Self.now.addingTimeInterval(-86_400)))
        #expect(!keeper.handleVisit(WorldVisit(point: Self.park.offset(east: 2_000, north: 0), accuracy: 30, arrived: Self.now)))
        #expect(keeper.handleVisit(WorldVisit(point: Self.park.offset(east: 30, north: 0), accuracy: 30, arrived: Self.now)))
        #expect(!keeper.handleVisit(WorldVisit(point: Self.park, accuracy: 500, arrived: Self.now)), "too unsure")
        #expect(try keeper.store.deviceState().pending.count == 2)
        #expect(lookup.calls == 0)
    }

    // MARK: The store

    /// A walk joins the timeline, Private reads nothing without the hub key or in a decoy, and Delete a
    /// day takes the walk's line with it.
    @Test func privateReadsUnderTheHubKeyAndADayTakesItsLines() throws {
        let store = makeTestStore()
        let key = SymmetricKey(size: .bits256)
        #expect(store.worldPlaceLog() == nil, "Private closed: nothing read")
        store.hubContentKeyProvider = { key }
        let start = Date()
        store.startWorldWalk(at: start)
        for east in stride(from: 0.0, through: 300, by: 5) {
            store.worldWalk.record(WorldFix(point: Self.park.offset(east: east, north: 0), accuracy: 5, at: start, isPrecise: true))
        }
        let defaults = try #require(UserDefaults(suiteName: "WorldPlacesTests.\(UUID().uuidString)"))
        let workout = try #require(store.finishWorldWalk(at: start.addingTimeInterval(300), defaults: defaults))
        #expect(store.worldRoute(for: workout.id) != nil, "the walk kept its line")
        let log = try #require(store.worldPlaceLog())
        #expect(log.stops.map(\.kind) == [.walk] && log.stops.first?.workoutID == workout.id)
        store.duressSessionActive = true
        #expect(store.worldPlaceLog() == nil, "a decoy reads nothing")
        store.duressSessionActive = false
        #expect(store.deleteWorldPlaceDay(Calendar.current.startOfDay(for: start)))
        #expect(store.worldRoute(for: workout.id) == nil, "the day's line went with it")
        #expect(store.worldPlaceLog()?.stops.isEmpty == true)
        #expect(store.day.workouts.contains { $0.id == workout.id }, "the walk stays in Move")
    }

    /// A solo photo keeps its place where nothing refused is near, none at a refused place or offline,
    /// and deleting the photo deletes its place.
    @Test func soloPhotoPlacesFollowTheRefusedPlaceRule() async throws {
        let fix = WorldFix(point: Self.park, accuracy: 8, at: Self.now, isPrecise: true)
        let open = makeTestStore(worldPlaceLookup: FixedPlaceLookup(answer: [NearbyPlace(name: "Park", kind: .allowed(.park), metres: 5)]))
        let photo = UUID()
        #expect(await open.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now))
        #expect(try open.worldPhotoPlaces.place(for: photo) == Self.park)
        open.forgetSoloPhotoPlaces([photo])
        #expect(try open.worldPhotoPlaces.place(for: photo) == nil)
        #expect(!(await open.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now.addingTimeInterval(600))), "a stale reading")

        let clinic = makeTestStore(worldPlaceLookup: FixedPlaceLookup(answer: [NearbyPlace(name: "Northside Clinic", kind: .other, metres: 15)]))
        #expect(!(await clinic.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now)))
        #expect(try clinic.worldPhotoPlaces.all().isEmpty)
        let offline = makeTestStore()
        #expect(!(await offline.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now)), "no answer, no place")
    }

    /// Delete map history clears the places with the rest of the vault; nothing real goes in a decoy.
    @Test func deleteMapHistoryClearsThePlaces() throws {
        let store = makeTestStore()
        try store.worldPlaces.store.saveDeviceState(.empty.learning(PlaceRecord(name: "Park", category: .park, point: Self.park), at: Self.now))
        #expect(try store.worldPhotoPlaces.setPlace(Self.park, for: UUID()))
        store.duressSessionActive = true
        #expect(store.deleteWorldMapHistory())
        store.duressSessionActive = false
        #expect(try store.worldPlaces.store.deviceState() != .empty, "a decoy deleted real history")
        #expect(store.deleteWorldMapHistory())
        #expect(try store.worldPlaces.store.deviceState() == .empty)
        #expect(try store.worldPhotoPlaces.all().isEmpty)
    }

    // MARK: Photo markers and the rules on Home

    /// Photos within 40 m share one marker, newest first; nearest first when the person's place is known.
    @Test func photoMarkersGroupByPlace() {
        let a = UUID(), b = UUID(), c = UUID()
        let places = [a: Self.park, b: Self.park.offset(east: 20, north: 0), c: Self.park.offset(east: 800, north: 0)]
        let photos = [a, b, c].enumerated().map {
            SoloCameraPhoto(id: $0.element, takenAt: Self.now.addingTimeInterval(-Double($0.offset) * 60), revealsAt: Self.now)
        }
        let groups = WorldPhotoPlace.grouped(photos, places: places, near: Self.park.offset(east: 800, north: 0))
        #expect(groups.map(\.photoIDs) == [[c], [a, b]])
    }

    /// A reading places a photo only when it is precise, within 50 m and from the last two minutes.
    @Test func onlyAFreshPreciseReadingPlacesAPhoto() {
        let good = WorldFix(point: Self.park, accuracy: 20, at: Self.now, isPrecise: true)
        #expect(WorldPhotoPlaceRules.isGoodEnough(good, at: Self.now.addingTimeInterval(90)))
        #expect(!WorldPhotoPlaceRules.isGoodEnough(good, at: Self.now.addingTimeInterval(200)))
        #expect(!WorldPhotoPlaceRules.isGoodEnough(WorldFix(point: Self.park, accuracy: 80, at: Self.now, isPrecise: true), at: Self.now))
        #expect(!WorldPhotoPlaceRules.isGoodEnough(WorldFix(point: Self.park, accuracy: 20, at: Self.now, isPrecise: false), at: Self.now))
    }

    /// The companion hint waits for the location question and any stamp banner, never shows twice and
    /// never in a decoy.
    @Test func theHintWaitsItsTurn() {
        func due(shown: Bool = false, answered: Bool = true, permission: WorldLocationPermission = .notAsked,
                 asking: Bool = false, banner: Bool = false, front: Bool = true, decoy: Bool = false) -> Bool {
            WorldCompanionHint.isDue(alreadyShown: shown, introAnswered: answered, permission: permission, isAsking: asking,
                                     stampBannerShowing: banner, isFrontmost: front, isDecoy: decoy)
        }
        #expect(due())
        #expect(due(answered: false, permission: .whileUsing), "asked before the intro existed")
        #expect(!due(answered: false), "the location question is still to come")
        #expect(!due(asking: true), "iOS's prompt is up")
        #expect(!due(banner: true) && !due(shown: true) && !due(front: false) && !due(decoy: true))
    }

    /// The intro's answer and the hint's turn are device-only and go with the map's other settings.
    @Test func theIntroAndHintFlagsAreCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldPlacesTests.\(UUID().uuidString)"))
        WorldMapPreferences.setLocationIntroAnswered(in: defaults)
        WorldMapPreferences.setCompanionHintShown(in: defaults)
        #expect(WorldMapPreferences.locationIntroAnswered(in: defaults) && WorldMapPreferences.companionHintShown(in: defaults))
        WorldMapPreferences.clearAll(in: defaults)
        #expect(!WorldMapPreferences.locationIntroAnswered(in: defaults) && !WorldMapPreferences.companionHintShown(in: defaults))
    }
}

/// A lookup with a fixed answer that counts how often it is asked.
@MainActor
private final class CountingLookup: WorldPlaceLooking {
    let answer: [NearbyPlace]?
    private(set) var calls = 0

    init(answer: [NearbyPlace]?) {
        self.answer = answer
    }

    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? {
        calls += 1
        return answer
    }
}
