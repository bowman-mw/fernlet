import CryptoKit
import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// World build round 6 (owner-approved 2026-10-25): a place the person adds themselves (`ref-tag-*`), homes
/// and hotels (`ref-home-*`, `ref-hotel`), Home in Where you've been (`ref-home-where`), restaurants and gyms
/// on the map (`ref-places-map`) and the restaurant quick starts (`b1-qs-food`, `b3-qs-food-camera`).
@MainActor
struct WorldPlacesRound6Tests {
    private static let home = GeoPoint(45.5205, -122.6255)
    private static let cafe = GeoPoint(45.5047, -122.6359)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: Homes and hotels: the rules

    /// Up to two homes: a third is refused unless it names one to replace; moving or renaming one keeps its id.
    @Test func upToTwoHomesAndAThirdReplacesOne() {
        let first = HomePlace(kind: .home, label: "Home", point: Self.home)
        let second = HomePlace(kind: .home, label: "Mum's", point: Self.cafe)
        var book = HomeBook.empty.savingHome(first).savingHome(second)
        #expect(book.homes.map(\.id) == [first.id, second.id])
        let third = HomePlace(kind: .home, label: "Cabin", point: Self.home.offset(east: 9_000, north: 0))
        #expect(book.savingHome(third) == book, "a third needs one to replace")
        book = book.savingHome(third, replacing: first.id)
        #expect(book.homes.map(\.id) == [second.id, third.id])
        var renamed = second
        renamed.label = "Mum and Dad's"
        #expect(book.savingHome(renamed).homes.first?.label == "Mum and Dad's")
        #expect(book.isHomeOrHotel(Self.cafe.offset(east: 60, north: 0)), "Places you return to leaves it out")
        #expect(!book.isHomeOrHotel(Self.cafe.offset(east: 400, north: 0)))
    }

    /// One hotel at a time: checking in elsewhere remembers the last one; a hotel stayed at before (within
    /// 150 m) is a welcome back, a new one the first-visit line; checking out remembers it; removing forgets it.
    @Test func oneHotelAtATimeRemembersTheLastForAWelcomeBack() {
        let ace = HomePlace(kind: .hotel, label: "Ace", point: Self.cafe)
        var book = HomeBook.empty.checkingIn(ace)
        #expect(book.hotel?.id == ace.id && book.presence.greeting?.kind == .hotelFirst)
        let hilton = HomePlace(kind: .hotel, label: "Hilton", point: Self.home.offset(east: 3_000, north: 0))
        book = book.checkingIn(hilton)
        #expect(book.hotel?.id == hilton.id && book.pastHotels.map(\.id) == [ace.id])
        book = book.checkedOut
        #expect(book.hotel == nil && book.pastHotels.map(\.id) == [hilton.id, ace.id])
        let again = HomePlace(kind: .hotel, label: "Ace", point: Self.cafe.offset(east: 40, north: 0))
        book = book.checkingIn(again)
        #expect(book.presence.greeting?.kind == .hotelAgain, "within 150 m of the Ace: welcome back")
        #expect(!book.pastHotels.contains { $0.id == ace.id }, "the old Ace's place is taken by this stay")
        #expect(book.removing(again.id).hotel == nil && !book.removing(again.id).pastHotels.contains { $0.id == again.id })
    }

    /// Leaving a home is dated at the last sighting there; getting back after an hour or more leaves one
    /// greeting, said once while the person is still there; a short trip leaves none. Getting home ends a
    /// hotel stay.
    @Test func gettingHomeAfterAnHourGreetsOnce() {
        let home = HomePlace(kind: .home, label: "Home", point: Self.home)
        var book = HomeBook.empty.savingHome(home)
        book = book.observing(Self.home, at: Self.now).book
        let away = book.observing(Self.cafe, at: Self.now.addingTimeInterval(600))
        #expect(away.moves == [HomeMove(left: true, placeID: home.id, at: Self.now)])
        let back = away.book.observing(Self.home.offset(east: 30, north: 0), at: Self.now.addingTimeInterval(9 * 3_600))
        #expect(back.moves == [HomeMove(left: false, placeID: home.id, at: Self.now.addingTimeInterval(9 * 3_600))])
        #expect(back.book.presence.greeting == HomeGreeting(kind: .cameHome, placeID: home.id, line: 0))
        let taken = back.book.takingGreeting()
        #expect(taken.greeting?.kind == .cameHome && taken.book.takingGreeting().greeting == nil, "once per return")

        let short = taken.book.observing(Self.cafe, at: Self.now.addingTimeInterval(9 * 3_600 + 600)).book
            .observing(Self.home, at: Self.now.addingTimeInterval(9 * 3_600 + 1_800)).book
        #expect(short.presence.greeting == nil, "half an hour away is not a long day")

        let staying = short.checkingIn(HomePlace(kind: .hotel, label: "Ace", point: Self.cafe))
        let home2 = staying.observing(Self.cafe, at: Self.now.addingTimeInterval(11 * 3_600)).book
            .observing(Self.home, at: Self.now.addingTimeInterval(20 * 3_600)).book
        #expect(home2.hotel == nil && home2.pastHotels.first?.label == "Ace", "getting home checks you out")
    }

    /// iOS's low-power visit at home, delivered again on departure, dates the leave at the departure.
    @Test func aVisitsDepartureDatesTheLeave() {
        let home = HomePlace(kind: .home, label: "Home", point: Self.home)
        let book = HomeBook.empty.savingHome(home)
        let arrived = book.observing(Self.home, at: Self.now)
        #expect(arrived.moves.isEmpty, "no leave seen before: no return")
        let left = arrived.book.observing(Self.home, at: Self.now, departed: Self.now.addingTimeInterval(3_600))
        #expect(left.moves == [HomeMove(left: true, placeID: home.id, at: Self.now.addingTimeInterval(3_600))])
        #expect(left.book.presence.atID == nil)
    }

    /// "Out and about" is the time from each leave to the next return that day.
    @Test func outAndAboutSumsTheDaysTrips() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.startOfDay(for: Self.now)
        let home = UUID()
        let at = { (hours: Double) in day.addingTimeInterval(hours * 3_600) }
        let log = PlaceLog(places: [], stops: [PlaceStop(kind: .leftHome, at: at(8.5), placeID: home),
                                               PlaceStop(kind: .walk, at: at(12), metres: 900),
                                               PlaceStop(kind: .cameHome, at: at(18), placeID: home),
                                               PlaceStop(kind: .leftHome, at: at(19), placeID: home),
                                               PlaceStop(kind: .cameHome, at: at(19.5), placeID: home)])
        #expect(abs((log.outAndAbout(on: day, calendar: calendar) ?? 0) - 10 * 3_600) < 1, "9 h 30 min, then 30 min")
        #expect(PlaceLog(places: [], stops: [PlaceStop(kind: .leftHome, at: at(8), placeID: home)]).outAndAbout(on: day, calendar: calendar) == nil)
    }

    // MARK: The files

    /// Homes live on the device side and survive a fold and "Delete all of it" (they stay until removed in
    /// Settings › Home map); an app-lock reset (a new hub key) and the lock-reset reach take them with the
    /// places the person has been, as the reset screens say.
    @Test func homesStayThroughDeleteAllButGoWithALockReset() throws {
        let vault = WorldMapVault.ephemeral()
        let store = PlaceLogStore(vault: vault)
        let key = SymmetricKey(size: .bits256)
        let book = HomeBook.empty.savingHome(HomePlace(kind: .home, label: "Home", point: Self.home))
        try store.saveDeviceState(PlaceDeviceState.empty.withHomes(book).learning(PlaceRecord(point: Self.cafe), at: Self.now))
        _ = try store.fold(hubKey: key, now: Self.now)
        #expect(try store.deviceState().homes == book, "a fold keeps the homes on the device side")
        #expect(store.deleteAll())
        #expect(try store.deviceState() == PlaceDeviceState.empty.withHomes(book), "Delete all of it keeps only the homes")
        #expect(try store.fold(hubKey: SymmetricKey(size: .bits256), now: Self.now) == .empty)
        #expect(try store.deviceState().homes != nil, "no log was left to fail; the homes stay")
        _ = try store.fold(hubKey: key, now: Self.now)
        try store.saveLog(PlaceLog(places: [], stops: []), hubKey: key)
        #expect(try store.fold(hubKey: SymmetricKey(size: .bits256), now: Self.now) == .empty)
        #expect(try store.deviceState() == .empty, "a reset's new key: the homes went with the places")
        try store.saveDeviceState(PlaceDeviceState.empty.withHomes(book))
        #expect(store.deleteEverything())
        #expect(try store.deviceState() == .empty)
        #expect(vault.clearAll())
    }

    // MARK: Capture

    /// A refused spot is offered for "Remember this place" in memory only, and goes when the person moves
    /// on; adding it keeps the person's own name and point (no reference) with a visit, and nothing of the
    /// refused place.
    @Test func aRefusedSpotCanBeAddedByThePerson() async throws {
        let lookup = FixedPlaceLookup(answer: [NearbyPlace(name: "Lakeside Therapy", kind: .other, metres: 5)])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true },
                                       remembersEatingOut: { false })
        let fix = WorldFix(point: Self.cafe, accuracy: 10, at: Self.now, isPrecise: true)
        #expect(!(await keeper.handleForeground(fix, now: Self.now)))
        #expect(keeper.refusedSpot?.point == Self.cafe)
        #expect(try keeper.store.deviceState() == .empty, "nothing kept unless they add it")
        _ = await keeper.handleForeground(WorldFix(point: Self.cafe.offset(east: 80, north: 0), accuracy: 10, at: Self.now, isPrecise: true),
                                          now: Self.now.addingTimeInterval(60))
        #expect(keeper.refusedSpot == nil, "gone once they move on")
        #expect(keeper.remember("The square", at: Self.cafe, date: Self.now))
        let state = try keeper.store.deviceState()
        #expect(state.newPlaces.map(\.label) == ["The square"] && state.newPlaces.first?.placeID == nil)
        #expect(state.pending.count == 1 && state.known.count == 1)
        let kept = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!kept.contains("Therapy"), "never the refused place's name")
    }

    /// Readings at a home note no visit there (homes and hotels are not places you return to), and leaving
    /// and getting back join the timeline as their own stops.
    @Test func homesAreNotPlacesYouReturnTo() async throws {
        let lookup = FixedPlaceLookup(answer: [NearbyPlace(name: "Corner Café", kind: .allowed(.foodAndDrink), metres: 10, placeID: "I-cafe")])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true },
                                       remembersEatingOut: { false })
        let home = HomePlace(kind: .home, label: "Home", point: Self.home)
        #expect(keeper.saveHome(home))
        let atHome = WorldFix(point: Self.home, accuracy: 10, at: Self.now, isPrecise: true)
        #expect(!(await keeper.handleForeground(atHome, now: Self.now)), "no visit at home, even above a café")
        _ = await keeper.handleForeground(WorldFix(point: Self.cafe, accuracy: 10, at: Self.now, isPrecise: true),
                                          now: Self.now.addingTimeInterval(3_600))
        _ = await keeper.handleForeground(atHome, now: Self.now.addingTimeInterval(4 * 3_600))
        let kinds = try keeper.store.deviceState().pending.map(\.kind)
        #expect(kinds == [.leftHome, .visit, .cameHome])
        #expect(keeper.takeGreeting()?.greeting.kind == .cameHome)
        #expect(keeper.takeGreeting()?.greeting == nil)
    }

    /// "Remember places I eat out": meals logged during a visit to a food-and-drink place are noted there
    /// once, by Apple's reference (never its name or kind); after the third it is a favourite with a usual.
    @Test func mealsLoggedAtAPlaceToEatMakeAFavourite() async throws {
        let lookup = FixedPlaceLookup(answer: [NearbyPlace(name: "Hoshi Noodle Bar", kind: .allowed(.foodAndDrink), metres: 8, placeID: "I-hoshi")])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { true },
                                       remembersEatingOut: { true })
        _ = await keeper.handleForeground(WorldFix(point: Self.cafe, accuracy: 10, at: Self.now, isPrecise: true), now: Self.now)
        let ramen = WorldLoggedMeal(id: UUID(), name: "tonkotsu ramen", loggedAt: Self.now.addingTimeInterval(600))
        let before = WorldLoggedMeal(id: UUID(), name: "toast", loggedAt: Self.now.addingTimeInterval(-3 * 3_600))
        #expect(keeper.noteMeals([ramen, before], now: Self.now.addingTimeInterval(900)))
        #expect(!keeper.noteMeals([ramen], now: Self.now.addingTimeInterval(900)), "once")
        let more = [WorldLoggedMeal(id: UUID(), name: "Tonkotsu Ramen", loggedAt: Self.now.addingTimeInterval(1_200)),
                    WorldLoggedMeal(id: UUID(), name: "gyoza", loggedAt: Self.now.addingTimeInterval(1_300))]
        #expect(keeper.noteMeals(more, now: Self.now.addingTimeInterval(1_400)))
        let place = try #require(keeper.eatingPlaces.first)
        #expect(place.placeID == "I-hoshi" && place.label == nil && place.mealCount == 3 && place.isFavourite)
        #expect(place.usual?.name.lowercased() == "tonkotsu ramen")
        #expect([place].favourite(near: Self.cafe.offset(east: 20, north: 0))?.id == place.id)
        let sealed = String(decoding: try JSONEncoder().encode(try keeper.store.deviceState()), as: UTF8.self)
        #expect(!sealed.contains("Hoshi") && !sealed.contains("foodAndDrink"), "never Apple's name or kind")
    }

    /// Only food and drink makes a place to eat: a park, a café with no reference, or the switch off note no meal.
    @Test func onlyFoodAndDrinkWithAReferenceIsAPlaceToEat() {
        #expect(PlaceClassifier.eatingPlaceID([NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 8, placeID: "I-hoshi")]) == "I-hoshi")
        #expect(PlaceClassifier.eatingPlaceID([NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 8)]) == nil)
        #expect(PlaceClassifier.eatingPlaceID([NearbyPlace(name: "Laurelhurst Park", kind: .allowed(.park), metres: 8, placeID: "I-park")]) == nil)
        #expect(PlaceClassifier.eatingPlaceID([NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 8, placeID: "I-hoshi"),
                                               NearbyPlace(name: "Dr. Lee Dental", kind: .other, metres: 4)]) == nil)
    }

    /// A decoy reads and writes none of it.
    @Test func aDecoyKeepsNoHomesOrMeals() async throws {
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: FixedPlaceLookup(answer: nil),
                                       remembersPlaces: { true }, remembersEatingOut: { true })
        keeper.setDecoy(true)
        #expect(!keeper.saveHome(HomePlace(kind: .home, label: "Home", point: Self.home)))
        #expect(!keeper.checkIn(HomePlace(kind: .hotel, label: "Ace", point: Self.cafe)))
        #expect(!keeper.remember("The square", at: Self.cafe, date: Self.now))
        #expect(!keeper.noteMeals([WorldLoggedMeal(id: UUID(), name: "ramen", loggedAt: Self.now)]))
        keeper.setDecoy(false)
        #expect(try keeper.store.deviceState() == .empty)
    }

    /// "Remember places I eat out" is on by default, device-only, and goes with the map's other settings.
    @Test func eatOutIsOnByDefaultAndCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldPlacesRound6Tests.\(UUID().uuidString)"))
        #expect(WorldMapPreferences.remembersEatingOut(in: defaults))
        WorldMapPreferences.setRemembersEatingOut(false, in: defaults)
        #expect(!WorldMapPreferences.remembersEatingOut(in: defaults))
        WorldMapPreferences.clearAll(in: defaults)
        #expect(defaults.object(forKey: WorldMapPreferences.Key.remembersEatingOut) == nil)
    }

    // MARK: The map

    /// A home's circle reaches 1 km; a kept place's about 300 m; neither is ever written into the fog.
    @Test func homesUncoverAKilometreAndPlacesThreeHundredMetres() {
        let disc = MercatorHexGrid.disc(around: Self.home, radius: HomeBook.uncoverRadius)
        let far = disc.map { MercatorHexGrid.centreGeo(of: $0).distance(to: Self.home) }.max() ?? 0
        #expect(far > 950 && far <= 1_000)
        let small = MercatorHexGrid.disc(around: Self.home, radius: WorldMapMarker.uncoverRadius)
        #expect(small.count < disc.count / 8)
        #expect(MercatorHexGrid.cells(around: Self.home, within: 1_000).count < disc.count, "the fog's own reach stays capped")
    }

    // MARK: The blue button

    /// At a favourite place to eat: its name, "You've logged meals here 4 times", the usual, the camera on
    /// your own second, the menu; the bowl stays on the button with the camera row; a space wins; a resting
    /// day keeps the restaurant; a decoy never sees it.
    @Test func theBlueButtonAtAFavouritePlaceToEat() {
        var context = WorldQuickStartContext()
        context.canWalk = true
        context.soloCameraAvailable = true
        context.eatingPlace = WorldQuickStartContext.EatingOut(id: UUID(), name: "Hoshi Noodle Bar", meals: 4, usual: "tonkotsu ramen")
        let card = WorldQuickStart.card(for: context)
        #expect(card?.heading == .eatingPlace("Hoshi Noodle Bar") && card?.note == .loggedMealsHere(times: 4))
        #expect(card?.options == [.logUsual(meal: "tonkotsu ramen", meals: 4), .soloCamera, .findMenu(place: "Hoshi Noodle Bar")])
        #expect(WorldQuickStart.glyph(for: context) == .eat)
        #expect(WorldQuickStartCopy.title(.logUsual(meal: "tonkotsu ramen", meals: 4)) == "Log your usual: tonkotsu ramen")
        #expect(WorldQuickStartCopy.detail(.findMenu(place: "Hoshi")) == "Searches the web by name. Your location isn't sent.")
        var resting = context
        resting.isResting = true
        #expect(WorldQuickStart.card(for: resting)?.heading == .eatingPlace("Hoshi Noodle Bar"))
        var atSpace = context
        atSpace.space = WorldQuickStartContext.Space(id: UUID(), name: "Full gym", equipment: "", itemCount: 3)
        #expect(WorldQuickStart.card(for: atSpace)?.heading == .space("Full gym"))
        var decoy = context
        decoy.isDecoy = true
        #expect(WorldQuickStart.card(for: decoy)?.heading == .walk)
        var noUsual = context
        noUsual.eatingPlace = WorldQuickStartContext.EatingOut(id: UUID(), name: "Café Lune", meals: 3, usual: nil)
        noUsual.soloCameraAvailable = false
        #expect(WorldQuickStart.card(for: noUsual)?.options == [.findMenu(place: "Café Lune")])
    }

    /// The approved homes-and-hotels copy, word for word, with the companion's name in Sprout's place.
    @Test func theHomeCopyReadsAsApproved() {
        let home = HomePlace(kind: .home, label: "Home", point: Self.home)
        #expect(WorldHomeMapCopy.spoken(home, companion: "Sprout") == "Sprout's house, at Home")
        #expect(WorldHomeMapCopy.greeting(HomeGreeting(kind: .cameHome, placeID: home.id), place: home) == "You're home! Long day?")
        let ace = HomePlace(kind: .hotel, label: "Ace", point: Self.cafe)
        #expect(WorldHomeMapCopy.greeting(HomeGreeting(kind: .hotelAgain, placeID: ace.id), place: ace) == "Welcome back to the Ace!")
        #expect(WorldHomeCopy.homeNote(companion: "Sprout")
                == "Home stays sealed on this iPhone, like your journal. Fernlet uncovers the map for 1 km around it, and Sprout gets a house here.")
        #expect(WorldPlacesCopy.outAndAbout(9 * 3_600 + 40 * 60, style: .abbreviated).hasPrefix("Out and about 9"))
    }
}
