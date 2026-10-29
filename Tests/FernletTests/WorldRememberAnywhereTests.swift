import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// World build round 7 (owner-approved 2026-10-26): "Remember this place" anywhere the person stays
/// (`ref-tag-home` draft 2, `ref-tag-how`), the sheet's three cases (`ref-tag-name` d2, `ref-tag-unnamed`,
/// `ref-tag-named`) and "This is home" on the companion's close-up (`ref-comp-home-add`, `ref-comp-home-at`).
@MainActor
struct WorldRememberAnywhereTests {
    private static let flat = GeoPoint(45.5047, -122.6359)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private static let hoshi = [NearbyPlace(name: "Hoshi Noodle Bar", kind: .allowed(.foodAndDrink), metres: 8, placeID: "I-hoshi")]
    private static let gym = [NearbyPlace(name: "Full Gym", kind: .allowed(.gym), metres: 8, placeID: "I-gym")]
    private static let therapy = [NearbyPlace(name: "Lakeside Therapy", kind: .other, metres: 5)]

    /// A keeper over `vault` whose lookups answer `answer`, with "Remember places I stop at" on.
    private static func keeper(_ answer: [NearbyPlace]?, vault: WorldMapVault? = nil) -> WorldPlacesKeeper {
        WorldPlacesKeeper(vault: vault ?? WorldMapVault.ephemeral(), lookup: FixedPlaceLookup(answer: answer), remembersPlaces: { true }, remembersEatingOut: { false })
    }

    /// A precise reading at `point` at `date`.
    private static func fix(_ point: GeoPoint, _ date: Date) -> WorldFix {
        WorldFix(point: point, accuracy: 10, at: date, isPrecise: true)
    }

    /// Readings at `point` from `start` until `minutes` later, one a minute (the stop decided at three).
    private static func stay(_ keeper: WorldPlacesKeeper, at point: GeoPoint, from start: Date, minutes: Int) async {
        for minute in 0...minutes {
            let at = start.addingTimeInterval(Double(minute) * 60)
            _ = await keeper.handleForeground(fix(point, at), now: at)
        }
    }

    // MARK: When it shows (ref-tag-home d2, ref-tag-how)

    /// After more than 2 minutes at any spot, named or not, the button shows: a restaurant with Apple's name
    /// in memory, a flat with none; it never shows before.
    @Test func aStayOfMoreThanTwoMinutesAnywhereShowsTheButton() async {
        let named = Self.keeper(Self.hoshi)
        await Self.stay(named, at: Self.flat, from: Self.now, minutes: 3)
        let spot = named.shownRememberSpot(near: Self.flat, now: Self.now.addingTimeInterval(3 * 60))
        #expect(spot?.appleName == "Hoshi Noodle Bar" && spot?.placeID == "I-hoshi" && spot?.category == .foodAndDrink)

        let flat = Self.keeper([])
        await Self.stay(flat, at: Self.flat, from: Self.now, minutes: 3)
        #expect(flat.shownRememberSpot(near: Self.flat, now: Self.now.addingTimeInterval(3 * 60))?.kind == .unnamed)

        let spotNow = WorldRememberSpot(point: Self.flat, since: Self.now, kind: .unnamed)
        #expect(!spotNow.isDue(at: Self.now.addingTimeInterval(WorldRememberSpot.showAfter)), "not at 2 minutes")
        #expect(spotNow.isDue(at: Self.now.addingTimeInterval(WorldRememberSpot.showAfter + 1)))
    }

    /// Never at a home, at the hotel, or at a place the person already remembered.
    @Test func neverAtAHomeAHotelOrAKeptPlace() async throws {
        let vault = WorldMapVault.ephemeral()
        let home = Self.keeper([], vault: vault)
        home.saveHome(HomePlace(kind: .home, label: "Home", point: Self.flat))
        await Self.stay(home, at: Self.flat, from: Self.now, minutes: 4)
        #expect(home.rememberSpot == nil, "not at a home")

        let hotel = Self.keeper([])
        hotel.checkIn(HomePlace(kind: .hotel, label: "Ace", point: Self.flat))
        await Self.stay(hotel, at: Self.flat, from: Self.now, minutes: 4)
        #expect(hotel.rememberSpot == nil, "not at the hotel")

        let kept = Self.keeper(Self.therapy)
        await Self.stay(kept, at: Self.flat, from: Self.now, minutes: 3)
        let spot = try #require(kept.rememberSpot)
        #expect(kept.remember(spot, named: "The square", at: Self.flat, date: Self.now) != nil)
        #expect(kept.rememberSpot == nil, "gone once remembered")
        kept.forget()
        await Self.stay(kept, at: Self.flat, from: Self.now.addingTimeInterval(3_600), minutes: 4)
        #expect(kept.rememberSpot == nil, "the place is kept: never asked again")
    }

    /// Moving more than 50 m away takes the button away, with nothing kept.
    @Test func movingFiftyMetresAwayTakesItAway() async throws {
        let keeper = Self.keeper([])
        await Self.stay(keeper, at: Self.flat, from: Self.now, minutes: 3)
        #expect(keeper.rememberSpot != nil)
        let later = Self.now.addingTimeInterval(4 * 60)
        _ = await keeper.handleForeground(Self.fix(Self.flat.offset(east: 40, north: 0), later), now: later)
        #expect(keeper.rememberSpot != nil, "40 m is still there")
        _ = await keeper.handleForeground(Self.fix(Self.flat.offset(east: 60, north: 0), later), now: later)
        #expect(keeper.rememberSpot == nil)
        #expect(try keeper.store.deviceState() == .empty, "nothing kept")
        #expect(keeper.marks.read() == .empty)
    }

    // MARK: Not here

    /// "Not here" at a spot Fernlet can name keeps a quiet "don't ask here" on the device (asked again by a
    /// new session, never again there), and the wipe takes it with the vault.
    @Test func notHereIsKeptQuietlyAndWiped() async {
        let vault = WorldMapVault.ephemeral()
        let keeper = Self.keeper([], vault: vault)
        await Self.stay(keeper, at: Self.flat, from: Self.now, minutes: 3)
        keeper.dismissRememberSpot()
        #expect(keeper.rememberSpot == nil)
        #expect(keeper.marks.read()?.quiet.count == 1)

        let again = Self.keeper([], vault: vault)
        await Self.stay(again, at: Self.flat.offset(east: 20, north: 0), from: Self.now.addingTimeInterval(86_400), minutes: 4)
        #expect(again.rememberSpot == nil, "never asks there again")
        #expect(vault.clearAll())
        #expect(again.marks.read() == .empty, "the wipes take it with the vault")

        let other = Self.keeper([])
        await Self.stay(other, at: Self.flat, from: Self.now, minutes: 3)
        other.dismissRememberSpot()
        #expect(other.marks.read()?.quiet.count == 1)
        #expect(other.removeMarks())
        #expect(other.marks.read() == .empty, "Delete all of it and the lock reset remove it")
    }

    /// At a spot Fernlet won't name, "Not here" keeps nothing: the button only hides until the person leaves.
    @Test func notHereAtARefusedSpotOnlyHidesIt() async {
        let keeper = Self.keeper(Self.therapy)
        await Self.stay(keeper, at: Self.flat, from: Self.now, minutes: 3)
        #expect(keeper.refusedSpot?.point == Self.flat)
        keeper.dismissRememberSpot()
        #expect(keeper.marks.read()?.quiet.isEmpty == true, "nothing kept at a refused spot")
        await Self.stay(keeper, at: Self.flat, from: Self.now.addingTimeInterval(40 * 60), minutes: 2)
        #expect(keeper.rememberSpot == nil, "hidden while they stay")
        let away = Self.now.addingTimeInterval(50 * 60)
        _ = await keeper.handleForeground(Self.fix(Self.flat.offset(east: 400, north: 0), away), now: away)
        // Back after the lookup spacing (30 minutes since the last one), staying again.
        await Self.stay(keeper, at: Self.flat, from: Self.now.addingTimeInterval(80 * 60), minutes: 4)
        #expect(keeper.refusedSpot != nil, "back after leaving")
    }

    /// A decoy session never sees the button and keeps nothing.
    @Test func aDecoyNeverSeesIt() async {
        let keeper = Self.keeper(Self.hoshi)
        keeper.setDecoy(true)
        await Self.stay(keeper, at: Self.flat, from: Self.now, minutes: 4)
        #expect(keeper.rememberSpot == nil)
        #expect(keeper.shownRememberSpot(near: Self.flat, now: Self.now.addingTimeInterval(600)) == nil)
        keeper.dismissRememberSpot()
        #expect(keeper.remember(WorldRememberSpot(point: Self.flat, since: Self.now, kind: .unnamed), named: "Flat",
                                at: Self.flat, date: Self.now) == nil)
        keeper.setDecoy(false)
        #expect(keeper.marks.read() == .empty)
    }

    // MARK: The sheet's cases (MapKit terms)

    /// Apple's name kept unchanged stores only the place's reference, never the name, on the device side and
    /// in the marks; a restaurant gets its bowl at once.
    @Test func anUnchangedAppleNameStoresOnlyTheReference() async throws {
        let keeper = Self.keeper(Self.hoshi)
        await Self.stay(keeper, at: Self.flat, from: Self.now, minutes: 3)
        let spot = try #require(keeper.rememberSpot)
        let outcome = keeper.remember(spot, named: " Hoshi Noodle Bar ", at: Self.flat, date: Self.now)
        #expect(outcome?.pendingRename == nil)
        let state = try keeper.store.deviceState()
        #expect(state.newPlaces.map(\.placeID) == ["I-hoshi"] && state.newPlaces.first?.label == nil)
        #expect(!String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("Hoshi"))
        let marks = try #require(keeper.marks.read())
        #expect(marks.kept.map(\.icon) == [.eat] && marks.kept.first?.label == nil && marks.kept.first?.placeID == "I-hoshi")
        #expect(!String(decoding: try JSONEncoder().encode(marks), as: UTF8.self).contains("Hoshi"))
    }

    /// A name the person changed is kept as their own label, with Apple's reference.
    @Test func anEditedNameStoresALabel() async throws {
        let keeper = Self.keeper(Self.hoshi)
        await Self.stay(keeper, at: Self.flat, from: Self.now, minutes: 3)
        let spot = try #require(keeper.rememberSpot)
        #expect(keeper.remember(spot, named: "Ramen night", at: Self.flat, date: Self.now) != nil)
        let record = try #require(try keeper.store.deviceState().newPlaces.first)
        #expect(record.label == "Ramen night" && record.placeID == "I-hoshi")
        #expect(keeper.keptPlaces.first?.label == "Ramen night")
        #expect(keeper.remember(spot, named: "   ", at: Self.flat, date: Self.now) == nil, "a blank name keeps nothing")
    }

    /// A remembered restaurant or gym is on the map at once (a bowl, a dumbbell), without three meals; a park
    /// gets no icon.
    @Test func aRememberedRestaurantOrGymGetsItsIconAtOnce() async throws {
        let store = makeTestStore()
        let restaurant = WorldRememberSpot(point: Self.flat, since: Self.now,
                                           kind: .named(placeID: "I-hoshi", name: "Hoshi Noodle Bar", category: .foodAndDrink))
        let gym = WorldRememberSpot(point: Self.flat.offset(east: 500, north: 0), since: Self.now,
                                    kind: .named(placeID: "I-gym", name: "Full Gym", category: .gym))
        #expect(store.rememberWorldSpot(restaurant, named: "Hoshi Noodle Bar", at: restaurant.point, now: Self.now))
        #expect(store.rememberWorldSpot(gym, named: "My gym", at: gym.point, now: Self.now))
        let markers = store.worldPlaceMarkers(near: nil).markers
        #expect(markers.contains { $0.kind == .eatingPlace(placeID: "I-hoshi") })
        #expect(markers.contains { $0.kind == .keptGym && $0.name == "My gym" })
        #expect(WorldKeptPlace.Icon.of(.park) == nil && WorldKeptPlace.Icon.of(nil) == nil)
        store.duressSessionActive = true
        #expect(store.worldPlaceMarkers(near: nil).markers.isEmpty && store.worldRememberSpot(near: Self.fix(Self.flat, Self.now)) == nil)
        store.duressSessionActive = false
    }

    /// Deleting a remembered place in Where you've been (W-14, `ref-del-confirm`) takes its kept mark and
    /// its icon with it; the other remembered places stay.
    @Test func deletingARememberedPlaceForgetsItsMarkAndIcon() throws {
        let gymPoint = Self.flat.offset(east: 500, north: 0)
        let a = WorldKeptPlace(id: UUID(), point: Self.flat, placeID: "I-hoshi", icon: .eat, label: nil)
        let b = WorldKeptPlace(id: UUID(), point: gymPoint, placeID: "I-gym", icon: .gym, label: nil)
        let marks = WorldPlaceMarks.empty.keeping(a).keeping(b)
        #expect(marks.forgetting([a.id]).kept == [b] && !marks.forgetting([a.id]).isKept(near: Self.flat))
        #expect(marks.forgetting([]) == marks)
        let store = makeTestStore()
        let gym = WorldRememberSpot(point: gymPoint, since: Self.now, kind: .named(placeID: "I-gym", name: "Full Gym", category: .gym))
        #expect(store.rememberWorldSpot(gym, named: "My gym", at: gymPoint, now: Self.now))
        let kept = try #require(store.worldPlaces.keptPlaces.first)
        store.worldPlaces.forgetKeptPlaces([kept.id])
        #expect(store.worldPlaces.keptPlaces.isEmpty)
        #expect(!store.worldPlaceMarkers(near: nil).markers.contains { $0.kind == .keptGym })
    }

    /// With background mapping on, iOS's visit says when the person arrived: the stay counts from then.
    @Test func aBackgroundVisitCountsTheStayFromTheArrival() async {
        let keeper = Self.keeper([])
        keeper.handleVisit(WorldVisit(point: Self.flat, accuracy: 30, arrived: Self.now))
        let opened = Self.now.addingTimeInterval(10 * 60)
        _ = await keeper.handleForeground(Self.fix(Self.flat, opened), now: opened)
        #expect(keeper.shownRememberSpot(near: Self.flat, now: opened) != nil, "shown as Fernlet opens")
    }

    // MARK: This is home (ref-comp-home-add, ref-comp-home-at)

    /// "This is home" opens the Remember this place sheet with Home picked, the pin where the person stands;
    /// with two homes kept it asks which to replace. At a home or the hotel the close-up says so instead.
    @Test func thisIsHomeOpensWithHomePickedAndAsksWhichToReplace() {
        #expect(WorldCloseUpAfterClose.thisIsHome(Self.flat).placeSheet == .remember(start: Self.flat, kind: .home))
        #expect(WorldCloseUpAfterClose.customize.placeSheet == nil)
        let one = HomeBook.empty.savingHome(HomePlace(kind: .home, label: "Home", point: Self.flat))
        let two = one.savingHome(HomePlace(kind: .home, label: "Mum's", point: Self.flat.offset(east: 9_000, north: 0)))
        #expect(!WorldRememberPlaceSheet.asksWhichHomeToReplace(one))
        #expect(WorldRememberPlaceSheet.asksWhichHomeToReplace(two))

        let away = Self.flat.offset(east: 3_000, north: 0)
        #expect(WorldCloseUpPlace.at(Self.fix(away, Self.now), book: two, decoy: false) == .away(away))
        #expect(WorldCloseUpPlace.at(Self.fix(Self.flat, Self.now), book: two, decoy: false) == .home(name: "Home"))
        let hotel = HomeBook.empty.checkingIn(HomePlace(kind: .hotel, label: "Ace", point: away))
        #expect(WorldCloseUpPlace.at(Self.fix(away, Self.now), book: hotel, decoy: false) == .hotel(name: "Ace"))
        #expect(WorldCloseUpPlace.at(Self.fix(away, Self.now), book: two, decoy: true) == .unknown, "never in a decoy")
        #expect(WorldCloseUpPlace.at(nil, book: two, decoy: false) == .unknown)
        let rough = WorldFix(point: away, accuracy: 3_000, at: Self.now, isPrecise: false)
        #expect(WorldCloseUpPlace.at(rough, book: two, decoy: false) == .unknown, "no home from an approximate area")
    }
}
