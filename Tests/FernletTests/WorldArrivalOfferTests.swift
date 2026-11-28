import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The blue button's arrival offers at a restaurant or a gym (owner's picks N1 to N7, 2026-11-27): the drive-end
/// lookup's kinds per switch, the foreground stop lookup's hand-off, the rule order, the gym's plan-due and no-plan
/// choices, the words without a place name, and when the offer goes.
@MainActor
struct WorldArrivalOfferTests {
    private static let end = GeoPoint(45.5047, -122.6359)
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: The switches and the drive-end kinds (N1-B, N5-B)

    /// A drive's end asks only for the kinds whose switch is on: hotels and gyms ride "Remember places I stop at",
    /// restaurants "Remember places I eat out"; with both off it asks nothing.
    @Test func theDriveEndAsksOnlyForTheKindsWhoseSwitchIsOn() {
        #expect(WorldArrivalRules.driveEndCategories(remembersPlaces: true, remembersEatingOut: true) == [.hotel, .restaurant, .gym])
        #expect(WorldArrivalRules.driveEndCategories(remembersPlaces: true, remembersEatingOut: false) == [.hotel, .gym])
        #expect(WorldArrivalRules.driveEndCategories(remembersPlaces: false, remembersEatingOut: true) == [.restaurant])
        #expect(WorldArrivalRules.driveEndCategories(remembersPlaces: false, remembersEatingOut: false).isEmpty)
        #expect(WorldArrivalRules.allows(.restaurant, remembersPlaces: false, remembersEatingOut: true))
        #expect(!WorldArrivalRules.allows(.restaurant, remembersPlaces: true, remembersEatingOut: false))
        #expect(WorldArrivalRules.allows(.gym, remembersPlaces: true, remembersEatingOut: false))
        #expect(!WorldArrivalRules.allows(.gym, remembersPlaces: false, remembersEatingOut: true))
    }

    /// The store reads the kinds from the Home map switches; with every switch off the gate asks nothing, and an
    /// offer whose own switch is off is never held. A wipe's hand-off forgets what is held.
    @Test func theStoreReadsTheSwitchesAndKeepsTheHotelGate() throws {
        let defaults = try #require(UserDefaults(suiteName: "WorldArrivalOfferTests.\(UUID().uuidString)"))
        let store = makeTestStore()
        #expect(store.worldDriveEndCategories(defaults: defaults) == [.hotel, .restaurant, .gym], "both on by default")
        WorldMapPreferences.setRemembersPlaces(false, in: defaults)
        #expect(store.worldDriveEndCategories(defaults: defaults) == [.restaurant])
        #expect(store.worldArrivalSwitchIsOn(.restaurant, defaults: defaults) && !store.worldArrivalSwitchIsOn(.gym, defaults: defaults))
        WorldMapPreferences.setRemembersEatingOut(false, in: defaults)
        #expect(store.worldDriveEndCategories(defaults: defaults).isEmpty)
        #expect(!store.worldHotelLookupAllowed(at: Self.end, defaults: defaults), "every switch off: nothing asked")
        store.worldArrivalFound(Self.offer(.restaurant), defaults: defaults)
        #expect(store.worldLocation.hotelOffers.arrival == nil)
        WorldMapPreferences.setRemembersEatingOut(true, in: defaults)
        store.worldArrivalFound(Self.offer(.gym), defaults: defaults)
        #expect(store.worldLocation.hotelOffers.arrival == nil, "a gym rides Remember places I stop at, which is off")
        store.worldLocation.hotelOffers.arrive(Self.offer(.restaurant))
        store.worldArrivalFound(nil, defaults: defaults)
        #expect(store.worldLocation.hotelOffers.arrival == nil, "a wipe forgets it")
    }

    // MARK: The drive-end lookup (N1-B, N7-A)

    /// The same one request asks for every kind allowed; the nearest restaurant or gym within 150 m is the arrival
    /// offer, a hotel the check-in offer, and the gate saying no kinds asks nothing.
    @Test func theDriveEndRequestCarriesTheArrivalKinds() async {
        let keeper = WorldHotelOfferKeeper()
        let finder = ArrivalNearbyFinder()
        keeper.finder = finder
        keeper.mayLook = { _ in true }
        keeper.categories = { [.hotel, .restaurant, .gym] }
        finder.answer = [WorldNearbyPlace(category: .gym, name: "Iron Works", point: Self.end.offset(east: 90, north: 0)),
                         WorldNearbyPlace(category: .restaurant, name: "Hoshi", point: Self.end.offset(east: 40, north: 0)),
                         WorldNearbyPlace(category: .restaurant, name: "Far Diner", point: Self.end.offset(east: 400, north: 0))]
        keeper.driveEnded(at: Self.end, now: Self.now)
        await keeper.lookup?.value
        #expect(finder.asked.count == 1 && finder.asked.first?.categories == [.hotel, .restaurant, .gym])
        #expect(finder.asked.first?.radius == HomeBook.sameHotelRadius)
        #expect(keeper.arrival?.kind == .restaurant && keeper.arrival?.name == "Hoshi" && keeper.offer == nil)

        finder.answer = [WorldNearbyPlace(category: .gym, name: "Iron Works", point: Self.end.offset(east: 90, north: 0)),
                         WorldNearbyPlace(category: .hotel, name: "The Ace", point: Self.end.offset(east: 30, north: 0))]
        keeper.driveEnded(at: Self.end, now: Self.now)
        await keeper.lookup?.value
        #expect(keeper.arrival?.kind == .gym && keeper.offer?.name == "The Ace", "both held; the button ranks the hotel first")

        keeper.categories = { [] }
        keeper.driveEnded(at: Self.end, now: Self.now)
        await keeper.lookup?.value
        #expect(finder.asked.count == 2 && keeper.arrival == nil, "every switch off: no request at all")
    }

    // MARK: The foreground stop lookup (N1-B)

    /// The stop lookup that already runs while the map is open hands a food-and-drink place or a gym on, by its
    /// kind and Apple's name, under that kind's switch; a park hands nothing, and a wipe hands the forgetting on.
    @Test func theForegroundStopLookupHandsOnARestaurantOrGym() async {
        var eatsOut = true
        let lookup = ArrivalPlaceLookup(answer: [NearbyPlace(name: "Hoshi", kind: .allowed(.foodAndDrink), metres: 8, placeID: "I-hoshi")])
        let keeper = WorldPlacesKeeper(vault: WorldMapVault.ephemeral(), lookup: lookup, remembersPlaces: { false },
                                       remembersEatingOut: { eatsOut })
        var handed: [WorldArrivalOffer?] = []
        keeper.onArrival = { handed.append($0) }
        let fix = WorldFix(point: Self.end, accuracy: 10, at: Self.now, isPrecise: true)
        _ = await keeper.stayed(at: fix, until: Self.now)
        #expect(handed.count == 1 && handed.first??.kind == .restaurant && handed.first??.name == "Hoshi")
        #expect(lookup.calls == 1, "no lookup of its own")

        eatsOut = false
        keeper.offerArrival(.named(placeID: "I-hoshi", name: "Hoshi", category: .foodAndDrink), at: Self.end, now: Self.now)
        keeper.offerArrival(.named(placeID: "I-iron", name: "Iron Works", category: .gym), at: Self.end, now: Self.now)
        keeper.offerArrival(.named(placeID: "I-park", name: "Laurelhurst", category: .park), at: Self.end, now: Self.now)
        #expect(handed.count == 1, "a restaurant with its switch off, a gym with its switch off and a park hand nothing")

        keeper.forget()
        #expect(handed.count == 2 && handed.last == .some(nil), "a wipe forgets the offers held elsewhere too")
    }

    // MARK: The rule order (N2-A, N3-A)

    /// A hotel's check-in outranks a restaurant or gym, a home outranks all of them, and a favourite place to eat
    /// keeps its own offers over a new restaurant's.
    @Test func aHotelAHomeAndAFavouriteOutrankTheArrival() throws {
        var context = WorldQuickStartContext()
        context.canWalk = true
        context.arrival = .restaurant
        context.hotelOffer = "The Ace"
        #expect(WorldQuickStart.card(for: context)?.heading == .hotel("The Ace"))
        context.hotelOffer = nil
        context.base = WorldQuickStartContext.Base(name: "Home", isHotel: false)
        #expect(WorldQuickStart.card(for: context)?.heading == .home("Home"))
        context.base = nil
        context.eatingPlace = WorldQuickStartContext.EatingOut(id: UUID(), name: "Hoshi", meals: 4, usual: "Ramen")
        let favourite = try #require(WorldQuickStart.card(for: context))
        #expect(favourite.heading == .eatingPlace("Hoshi") && favourite.options.contains(.findMenu(place: "Hoshi")))
        context.eatingPlace = nil
        let new = try #require(WorldQuickStart.card(for: context))
        #expect(new.heading == .arrivedToEat && new.options == [.arrival(.logMeal), .arrival(.findMenu)])
        #expect(WorldQuickStart.glyph(for: context) == .eat)
    }

    /// At a gym: today's plan when one is due, else Log a workout with Suggest a workout below it; a pinned space
    /// keeps its own card, and a resting day's card comes first.
    @Test func atAGymThePlanLeadsWhenOneIsDue() throws {
        var context = WorldQuickStartContext()
        context.arrival = .gym
        context.canWalk = true
        let free = try #require(WorldQuickStart.card(for: context))
        #expect(free.heading == .arrivedAtGym && free.options == [.arrival(.logWorkout), .arrival(.suggestWorkout)])
        context.plannedSession = "Upper body"
        let planned = try #require(WorldQuickStart.card(for: context))
        #expect(planned.options == [.arrival(.startPlan(session: "Upper body"))])
        #expect(WorldQuickStart.glyph(for: context) == .space)

        context.space = WorldQuickStartContext.Space(id: UUID(), name: "Full gym", equipment: "Free weights", itemCount: 12)
        #expect(WorldQuickStart.card(for: context)?.heading == .space("Full gym"), "a pinned space keeps its card")
        context.space = nil
        context.isResting = true
        #expect(WorldQuickStart.card(for: context)?.heading == .gentle)
        context.isResting = false
        context.isDecoy = true
        #expect(WorldQuickStart.card(for: context)?.options == [.walkTogether], "a decoy offers only the walk")
    }

    // MARK: The words (N4-B)

    /// No place name on the button, the card or its choices: "Log a meal here", "Start a workout here".
    @Test func theWordsNeverNameThePlace() throws {
        var context = WorldQuickStartContext()
        context.arrival = .restaurant
        let eat = try #require(WorldQuickStart.card(for: context))
        #expect(WorldQuickStartCopy.offerLabel(eat) == "Log a meal here")
        #expect(WorldQuickStartCopy.heading(eat.heading) == "Eating out")
        #expect(eat.options.map(WorldQuickStartCopy.title) == ["Log a meal", "Find the menu"])
        context.arrival = .gym
        let gym = try #require(WorldQuickStart.card(for: context))
        #expect(WorldQuickStartCopy.offerLabel(gym) == "Start a workout here")
        #expect(WorldQuickStartCopy.heading(gym.heading) == "At the gym")
        #expect(gym.options.map(WorldQuickStartCopy.title) == ["Log a workout", "Suggest a workout"])
        #expect(WorldQuickStartCopy.title(.arrival(.startPlan(session: "Upper body"))) == "Start today's plan")
        #expect(WorldQuickStartCopy.offerLabel(WorldQuickStartCard(heading: .walk, note: nil, options: [.walkTogether])) == nil)
    }

    /// "Log a meal" opens with the meal type picked by the time of day.
    @Test func logAMealPicksTheMealByTheTimeOfDay() {
        #expect(WorldArrivalRules.mealType(hour: 8) == .breakfast)
        #expect(WorldArrivalRules.mealType(hour: 12) == .lunch)
        #expect(WorldArrivalRules.mealType(hour: 15) == .snack)
        #expect(WorldArrivalRules.mealType(hour: 19) == .dinner)
    }

    // MARK: When it goes

    /// The offer goes 120 m from both the place and where it was found, on a new drive, once used, and with a
    /// meal (a restaurant's) or a workout (a gym's) logged since it was found.
    @Test func theOfferGoesWhenLeftUsedOrReplaced() {
        let keeper = WorldHotelOfferKeeper()
        keeper.arrive(Self.offer(.restaurant))
        keeper.noteReading(Self.end.offset(east: 100, north: 0))
        #expect(keeper.arrival != nil, "still at the door")
        keeper.noteReading(Self.end.offset(east: -300, north: 0))
        #expect(keeper.arrival == nil, "left")

        keeper.arrive(Self.offer(.gym))
        keeper.driveStarted()
        #expect(keeper.arrival == nil, "a new drive")
        keeper.arrive(Self.offer(.gym))
        keeper.clearArrival()
        #expect(keeper.arrival == nil, "a workout started from it")

        let meal = Self.offer(.restaurant)
        #expect(!meal.isSpent(mealsLoggedAt: [Self.now.addingTimeInterval(-600)], workoutsLoggedAt: [Self.now.addingTimeInterval(60)]))
        #expect(meal.isSpent(mealsLoggedAt: [Self.now.addingTimeInterval(60)], workoutsLoggedAt: []))
        let gym = Self.offer(.gym)
        #expect(!gym.isSpent(mealsLoggedAt: [Self.now.addingTimeInterval(60)], workoutsLoggedAt: []))
        #expect(gym.isSpent(mealsLoggedAt: [], workoutsLoggedAt: [Self.now.addingTimeInterval(60)]))
    }

    /// An offer of `kind` found at the drive's end at ``now``.
    private static func offer(_ kind: WorldArrivalKind) -> WorldArrivalOffer {
        WorldArrivalOffer(kind: kind, name: "Somewhere", point: end, anchor: end, since: now)
    }
}

/// Apple Maps' drive-end answer as a test sets it, with what each lookup asked for.
@MainActor
private final class ArrivalNearbyFinder: WorldNearbyFinding {
    /// What the next lookup returns (nil: no answer).
    var answer: [WorldNearbyPlace]? = []
    /// Each lookup's point, radius and kinds, in order.
    private(set) var asked: [(point: GeoPoint, radius: Double, categories: [WorldNearbyCategory])] = []

    func places(around point: GeoPoint, radius: Double, categories: [WorldNearbyCategory]) async -> [WorldNearbyPlace]? {
        asked.append((point, radius, categories))
        return answer
    }
}

/// The foreground stop lookup with a fixed answer, counting how often it is asked.
@MainActor
private final class ArrivalPlaceLookup: WorldPlaceLooking {
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
