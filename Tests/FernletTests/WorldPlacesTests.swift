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

    /// A visit is kept only at the nearest place, only when it is an allowed kind and its name refuses
    /// nothing; a refused nearest place refuses the visit even beside a café. The verdict carries the
    /// place's reference and nothing else of the answer.
    @Test func aVisitIsKeptOnlyAtTheNearestAllowedPlace() {
        let cafe = NearbyPlace(name: "Hoshi Noodle Bar", kind: .allowed(.foodAndDrink), metres: 12, placeID: "I-cafe")
        let clinic = NearbyPlace(name: "Riverside Family Clinic", kind: .other, metres: 8)
        let shop = NearbyPlace(name: "Corner Shop", kind: .other, metres: 5)
        #expect(PlaceClassifier.visitVerdict([cafe]) == .allowed(placeID: "I-cafe"))
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 12)]) == .allowed(placeID: nil),
                "no reference: still allowed, kept by its point alone")
        #expect(PlaceClassifier.visitVerdict([cafe, clinic]) == .refused, "a clinic nearer than the café")
        #expect(PlaceClassifier.visitVerdict([cafe, shop]) == .unnamed)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Ortiz Law Office", kind: .other, metres: 3)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Centro de Terapia", kind: .other, metres: 3)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Mercy Hospital", kind: .refused, metres: 30)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Far Café", kind: .allowed(.foodAndDrink), metres: 70)]) == .unnamed)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: " ", kind: .allowed(.gym), metres: 4, placeID: "I-gym")]) == .unnamed,
                "a nameless place can't be read for the refused words")
        #expect(PlaceClassifier.visitVerdict([]) == .unnamed)
    }

    /// Inside a park, far from its one point and with nothing else near, the park keeps the visit; a
    /// refused place within 80 m still refuses it; a café that far never does.
    @Test func anAreaKeepsAVisitFromInside() {
        let park = NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 210, placeID: "I-park")
        #expect(PlaceClassifier.visitVerdict([park]) == .allowed(placeID: "I-park"))
        #expect(PlaceClassifier.visitVerdict([park, NearbyPlace(name: "Park Clinic", kind: .other, metres: 70)]) == .refused)
        #expect(PlaceClassifier.visitVerdict([park, NearbyPlace(name: "Corner Shop", kind: .other, metres: 30)]) == .unnamed,
                "the shop is the nearest place, so the visit is there")
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Café", kind: .allowed(.foodAndDrink), metres: 120)]) == .unnamed)
        #expect(PlaceClassifier.visitVerdict([NearbyPlace(name: "Far Park", kind: .allowed(.park), metres: 400)]) == .unnamed)
    }

    /// Round 5 (owner): a solo photo keeps its place only at the everyday allowlist or inside a park, beach
    /// or campground, the same rule as a visit. Anywhere else (an office nobody lists, a shop, a station,
    /// nothing at all) and offline, it keeps no place.
    @Test func aPhotoKeepsItsPlaceOnlyAtAnAllowedPlace() {
        #expect(PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 20)]))
        #expect(PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Hoshi Noodle Bar", kind: .allowed(.foodAndDrink), metres: 12)]))
        #expect(PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Cannon Beach", kind: .allowed(.beach), metres: 260)]),
                "outdoors inside a beach, far from its one point")
        #expect(PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Iron Gym", kind: .allowed(.gym), metres: 30)]))
        // The other side: everywhere else.
        #expect(!PlaceClassifier.photoMayKeepPlace(nil), "offline: nothing can be placed")
        #expect(!PlaceClassifier.photoMayKeepPlace([]), "nothing recognised near: no place")
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Corner Shop", kind: .other, metres: 10)]))
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Dr. Lee Dental", kind: .other, metres: 40)]))
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Walgreens", kind: .refused, metres: 55)]))
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Walgreens", kind: .refused, metres: 90)]),
                "far from a pharmacy but at no allowed place: still no place (the old rule kept it)")
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Far Café", kind: .allowed(.foodAndDrink), metres: 120)]))
        #expect(!PlaceClassifier.photoMayKeepPlace([NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 12),
                                                    NearbyPlace(name: "Lakeside Therapy", kind: .other, metres: 6)]))
    }

    // MARK: The log and its device side

    /// A fold adds new places, counts each visit once (a stop already folded is not counted again), and
    /// drops stops older than 30 days.
    @Test func aFoldCountsEachVisitOnceAndKeepsThirtyDays() {
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
        let old = PlaceStop(kind: .visit, at: Self.now.addingTimeInterval(-40 * 86_400), placeID: place.id)
        let device = PlaceDeviceState.empty.learning(place, at: Self.now)
            .appending(PlaceStop(kind: .walk, at: Self.now, metres: 900, workoutID: UUID()))
            .appending(old)
        let log = PlaceLog.empty.folding(device, now: Self.now)
        #expect(log.places.map(\.visits) == [1], "a stop that waited past the 30 days is not counted")
        #expect(log.stops.count == 2, "and it never reaches the timeline")
        let again = log.folding(device, now: Self.now)
        #expect(again.places.first?.visits == 1, "a fold cut short and run again counts nothing twice")
        let reopened = PlaceDeviceState.empty.recordingVisit(to: place.id, at: Self.now.addingTimeInterval(3_600))
        #expect(log.folding(reopened, now: Self.now).places.first?.visits == 1,
                "the map opened again at the park an hour later, after a fold: the same visit")
        let later = PlaceDeviceState.empty.recordingVisit(to: place.id, at: Self.now.addingTimeInterval(5 * 3_600))
        #expect(log.folding(later, now: Self.now.addingTimeInterval(5 * 3_600)).places.first?.visits == 2)
        #expect(log.returnedTo.map(\.placeID) == ["I-park"])
        #expect(log.returnedTo.first?.label == nil, "no name is kept until the person gives one")
    }

    /// Deleting a day takes its visits off the counts, removes a place left with none, and names the
    /// day's walks so their lines can go. Renaming gives a place the person's own label.
    @Test func deletingADayTakesItsVisitsAndNamesItsWalks() {
        let place = PlaceRecord(point: Self.park)
        let walkID = UUID()
        let device = PlaceDeviceState.empty.learning(place, at: Self.now)
            .appending(PlaceStop(kind: .walk, at: Self.now.addingTimeInterval(60), metres: 500, workoutID: walkID))
        let log = PlaceLog.empty.folding(device, now: Self.now)
        let day = Calendar.current.startOfDay(for: Self.now)
        let result = log.deletingDay(day)
        #expect(result.log.stops.isEmpty && result.log.places.isEmpty)
        #expect(result.workoutIDs == [walkID])
        #expect(result.removedPlaces == [place.id])
        let renamed = log.renaming(place.id, to: "  My gym ")
        #expect(renamed.places.first?.label == "My gym")
        #expect(renamed.renaming(place.id, to: "   ") == renamed, "an empty name changes nothing")
    }

    /// Visits to one place within three hours count once; a known place matches within 75 m, or anywhere
    /// by the lookup's reference; the waiting stops are capped.
    @Test func theDeviceSideMatchesDedupesAndIsBounded() {
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
        let state = PlaceDeviceState.empty.learning(place, at: Self.now)
        #expect(state.knownPlace(near: Self.park.offset(east: 60, north: 0))?.id == place.id)
        #expect(state.knownPlace(near: Self.park.offset(east: 90, north: 0)) == nil)
        #expect(state.knownPlace(withPlaceID: "I-park")?.id == place.id)
        #expect(state.knownPlace(withPlaceID: "I-other") == nil && state.knownPlace(withPlaceID: nil) == nil)
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
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
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

    /// After an app-lock reset (a new hub key that can't open the log), the fold starts Where you've been
    /// again empty and drops what waited on the device side too, as the reset screen says.
    @Test func aResetStartsWhereYouveBeenAgainEmpty() throws {
        let vault = WorldMapVault.ephemeral()
        let store = PlaceLogStore(vault: vault)
        let oldKey = SymmetricKey(size: .bits256)
        let place = PlaceRecord(placeID: "I-park", point: Self.park)
        try store.saveDeviceState(PlaceDeviceState.empty.learning(place, at: Self.now))
        #expect(try store.fold(hubKey: oldKey, now: Self.now).places.count == 1)
        try store.saveDeviceState(try store.deviceState().recordingVisit(to: place.id, at: Self.now.addingTimeInterval(5 * 3_600)))
        let newKey = SymmetricKey(size: .bits256)
        #expect(try store.fold(hubKey: newKey, now: Self.now) == .empty)
        #expect(try store.deviceState() == .empty, "the waiting visit and the known point went with it")
        #expect(try store.fold(hubKey: newKey, now: Self.now) == .empty)
        #expect(vault.clearAll())
    }

    /// The first format kept Apple's name and Fernlet's kind for each place. Reading it drops both (none
    /// can be told apart from a person's rename, so none is kept), keeps the point and the visits, and
    /// seals the log and the device side again in the current format at once.
    @Test func aFirstFormatLogIsMigratedWithoutApplesNames() throws {
        let vault = WorldMapVault.ephemeral()
        let store = PlaceLogStore(vault: vault)
        let key = SymmetricKey(size: .bits256)
        let id = UUID()
        let point = #""point":{"latitude":45.5213,"longitude":-122.6253}"#
        let legacyLog = #"{"places":[{"category":"park","id":"\#(id.uuidString)","name":"Laurelhurst Park",\#(point),"visits":2}],"schemaVersion":1,"stops":[]}"#
        try vault.write(Data(legacyLog.utf8), to: .places, sealedWith: key)
        let legacyDevice = #"{"known":[{"category":"park","id":"\#(id.uuidString)",\#(point)}],"newPlaces":[{"category":"foodAndDrink","id":"\#(UUID().uuidString)","name":"Hoshi Noodle Bar",\#(point),"visits":0}],"pending":[]}"#
        try vault.write(Data(legacyDevice.utf8), to: .placesDevice)

        let log = try store.log(hubKey: key)
        #expect(log.schemaVersion == PlaceLog.currentSchema)
        #expect(log.places.map(\.id) == [id] && log.places.first?.visits == 2 && log.places.first?.point == Self.park)
        #expect(log.places.first?.label == nil && log.places.first?.placeID == nil)
        let sealedLog = String(decoding: try #require(try vault.read(.places, sealedWith: key)), as: UTF8.self)
        #expect(!sealedLog.contains("Laurelhurst") && !sealedLog.contains("category"), "the name was sealed again without it")

        let device = try store.deviceState()
        #expect(!device.needsMigration && device.known.map(\.id) == [id])
        let sealedDevice = String(decoding: try #require(try vault.read(.placesDevice)), as: UTF8.self)
        #expect(!sealedDevice.contains("Hoshi") && !sealedDevice.contains("category"))
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

    /// Open on the map at a park: the lookup is asked once, the park is learned by its reference and the
    /// person's point (never its name), and the next reading there is the same visit, without asking
    /// again. Entering the same park far from that point is a visit there, by its reference. A refused
    /// place is never learned.
    @Test func theMapLearnsAnAllowedPlaceOnce() async throws {
        let lookup = CountingLookup(answer: [NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 10, placeID: "I-park")])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true })
        let fix = WorldFix(point: Self.park, accuracy: 10, at: Self.now, isPrecise: true)
        #expect(await keeper.handleForeground(fix, now: Self.now))
        #expect(!(await keeper.handleForeground(fix, now: Self.now.addingTimeInterval(60))), "the same visit")
        #expect(lookup.calls == 1)
        let state = try keeper.store.deviceState()
        #expect(state.newPlaces.map(\.placeID) == ["I-park"] && state.newPlaces.first?.label == nil && state.pending.count == 1)

        let farSide = WorldFix(point: Self.park.offset(east: 400, north: 0), accuracy: 10, at: Self.now, isPrecise: true)
        #expect(await keeper.handleForeground(farSide, now: Self.now.addingTimeInterval(4 * 3_600)))
        let after = try keeper.store.deviceState()
        #expect(after.known.count == 1 && after.pending.count == 2, "the same park by its reference, not a second place")

        let refused = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(),
                                        lookup: CountingLookup(answer: [NearbyPlace(name: "Lakeside Therapy", kind: .other, metres: 5)]),
                                        remembersPlaces: { true })
        #expect(!(await refused.handleForeground(fix, now: Self.now)))
        #expect(try refused.store.deviceState() == .empty, "a therapist's office is never kept")
    }

    /// With "Remember places I stop at" off, nothing new is noted and nothing is looked up: no visit, no
    /// background visit, no walk on the timeline. What is already kept stays.
    @Test func rememberPlacesOffNotesNothingNew() async throws {
        var remembers = true
        let lookup = CountingLookup(answer: [NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 10, placeID: "I-park")])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { remembers })
        let fix = WorldFix(point: Self.park, accuracy: 10, at: Self.now, isPrecise: true)
        #expect(await keeper.handleForeground(fix, now: Self.now))
        let kept = try keeper.store.deviceState()
        remembers = false
        #expect(!(await keeper.handleForeground(fix, now: Self.now.addingTimeInterval(5 * 3_600))))
        #expect(!keeper.handleVisit(WorldVisit(point: Self.park, accuracy: 30, arrived: Self.now.addingTimeInterval(6 * 3_600))))
        #expect(!keeper.recordOuting(.walk, at: Self.now, metres: 900, workoutID: UUID()))
        #expect(lookup.calls == 1)
        #expect(try keeper.store.deviceState() == kept, "the park already kept stays")
    }

    /// The switch is on by default, device-only, and goes with the map's other settings.
    @Test func rememberPlacesIsOnByDefaultAndCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldPlacesTests.\(UUID().uuidString)"))
        #expect(WorldMapPreferences.remembersPlaces(in: defaults))
        WorldMapPreferences.setRemembersPlaces(false, in: defaults)
        #expect(!WorldMapPreferences.remembersPlaces(in: defaults))
        WorldMapPreferences.clearAll(in: defaults)
        #expect(WorldMapPreferences.remembersPlaces(in: defaults))
        #expect(defaults.object(forKey: WorldMapPreferences.Key.remembersPlaces) == nil)
    }

    /// Approximate or poor readings, and a decoy, note nothing and ask nothing.
    @Test func poorReadingsAndADecoyNoteNothing() async throws {
        let lookup = CountingLookup(answer: [NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 10)])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true })
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
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true })
        let place = PlaceRecord(point: Self.park)
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

    /// A solo photo keeps its place at an allowed place (a park, a café), none anywhere else (a clinic, a
    /// shop, nothing recognised) or offline, and deleting the photo deletes its place.
    @Test func soloPhotoPlacesFollowTheAllowlist() async throws {
        let fix = WorldFix(point: Self.park, accuracy: 8, at: Self.now, isPrecise: true)
        let open = makeTestStore(worldPlaceLookup: FixedPlaceLookup(answer: [NearbyPlace(name: "Park", kind: .allowed(.park), metres: 5)]))
        let photo = UUID()
        #expect(await open.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now))
        #expect(try open.worldPhotoPlaces.place(for: photo) == Self.park)
        open.forgetSoloPhotoPlaces([photo])
        #expect(try open.worldPhotoPlaces.place(for: photo) == nil)
        #expect(!(await open.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now.addingTimeInterval(600))), "a stale reading")
        let cafe = makeTestStore(worldPlaceLookup: FixedPlaceLookup(answer: [NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 9)]))
        #expect(await cafe.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now))

        for elsewhere in [[NearbyPlace(name: "Northside Clinic", kind: .other, metres: 15)],
                          [NearbyPlace(name: "Corner Shop", kind: .other, metres: 10)], []] {
            let store = makeTestStore(worldPlaceLookup: FixedPlaceLookup(answer: elsewhere))
            #expect(!(await store.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now)), "\(elsewhere.map(\.name))")
            #expect(try store.worldPhotoPlaces.all().isEmpty, "it stays in Just you, off the map")
        }
        let offline = makeTestStore()
        #expect(!(await offline.keepSoloPhotoPlace(for: photo, fix: fix, now: Self.now)), "no answer, no place")
    }

    /// A kept place's name is asked for again by its reference only while Private is open, never in a
    /// decoy; a place the person renamed shows their name, and with no answer a place shows as "A place you
    /// return to". A name Apple now gives as a refused place is never shown.
    @Test func placeNamesComeBackByReferenceOnlyInPrivate() async throws {
        let name = WorldPlaceName(name: "Laurelhurst Park", category: .park)
        let store = makeTestStore(worldPlaceLookup: FixedPlaceLookup(answer: nil, names: ["I-park": name]))
        let place = PlaceRecord(placeID: "I-park", point: Self.park, visits: 1)
        #expect(await store.worldPlaceName(for: place) == nil, "Private closed: nothing asked")
        store.hubContentKeyProvider = { SymmetricKey(size: .bits256) }
        #expect(await store.worldPlaceName(for: place) == name)
        #expect(await store.worldPlaceName(for: PlaceRecord(point: Self.park)) == nil, "no reference, nothing to ask")
        store.duressSessionActive = true
        #expect(await store.worldPlaceName(for: place) == nil, "a decoy asks nothing")
        store.duressSessionActive = false

        #expect(WorldPlacesCopy.placeTitle(place, name: name) == "Laurelhurst Park")
        #expect(WorldPlacesCopy.placeTitle(PlaceRecord(label: "Our park", placeID: "I-park", point: Self.park), name: name) == "Our park")
        #expect(WorldPlacesCopy.placeTitle(place, name: nil) == String(localized: "privatePlaces.unnamedPlace", defaultValue: "A place you return to"))
        #expect(WorldPlaceName.shown(name: "Riverside Family Clinic", kind: .other) == nil)
        #expect(WorldPlaceName.shown(name: "Mercy Hospital", kind: .refused) == nil)
        #expect(WorldPlaceName.shown(name: "Hoshi", kind: .allowed(.foodAndDrink)) == WorldPlaceName(name: "Hoshi", category: .foodAndDrink))
    }

    /// Delete map history clears the places with the rest of the vault; nothing real goes in a decoy.
    @Test func deleteMapHistoryClearsThePlaces() throws {
        let store = makeTestStore()
        try store.worldPlaces.store.saveDeviceState(.empty.learning(PlaceRecord(placeID: "I-park", point: Self.park), at: Self.now))
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

    func placeName(for placeID: String) async -> WorldPlaceName? {
        nil
    }

    func forgetNames() {}
}
