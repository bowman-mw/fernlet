import FernletDomainModel
import FernletScoring
import Foundation
import WorldMapStore

/// The arrival offers on the store (owner's picks N1 to N5, 2026-11-27): the blue button's offer at a restaurant or a
/// gym the person arrived at. There are two triggers and nothing runs in the background for them:
///
/// - **A drive's end**, through the hotel check-in's one lookup (``worldDriveEndCategories(defaults:)``: restaurants
///   with "Remember places I eat out" on, gyms with "Remember places I stop at" on).
/// - **A stop while the map is open**, through the places' own foreground stop lookup, which the device already
///   decides food-and-drink places and gyms with (``WorldPlacesKeeper/offerArrival(_:at:now:)``).
///
/// The gate (``worldArrivalFound(_:)``, ``worldArrivalOffer``) is the hotel offer's (no decoy, precise location, not
/// at a home or the current hotel) with the kind's own switch. The offer is held in memory only, in the location
/// source's ``WorldHotelOfferKeeper``; Apple's name never reaches the button (N4-B) and is never written. It goes
/// 120 m away, on a new drive, on a wipe, and once a meal is logged or a workout started from it.
extension FernletStore {
    /// An arrival offer the foreground stop lookup found, through the store's gate; nil forgets the offers held (the
    /// places keeper forgot its memory: a wipe or a decoy).
    func worldArrivalFound(_ offer: WorldArrivalOffer?, defaults: UserDefaults = .standard) {
        let offers = worldLocation.hotelOffers
        guard let offer else {
            offers.clear()
            return
        }
        guard worldHotelLookupAllowed(at: offer.anchor, defaults: defaults), worldArrivalSwitchIsOn(offer.kind, defaults: defaults) else { return }
        offers.arrive(offer)
    }

    /// Whether the switch an offer of `kind` rides is on (owner's pick N5-B).
    func worldArrivalSwitchIsOn(_ kind: WorldArrivalKind, defaults: UserDefaults = .standard) -> Bool {
        WorldArrivalRules.allows(kind, remembersPlaces: WorldMapPreferences.remembersPlaces(in: defaults),
                                 remembersEatingOut: WorldMapPreferences.remembersEatingOut(in: defaults))
    }

    /// The restaurant or gym to offer a meal or a workout at now: none in a decoy, with its switch off, at a home or
    /// the current hotel, or once a meal (a restaurant's) or a workout (a gym's) was logged since it was found.
    var worldArrivalOffer: WorldArrivalOffer? {
        guard !duressSessionActive, let offer = worldLocation.hotelOffers.arrival, worldArrivalSwitchIsOn(offer.kind),
              worldHomes.base(near: offer.anchor) == nil else { return nil }
        let spent = offer.isSpent(mealsLoggedAt: day.meals.map(\.loggedAt), workoutsLoggedAt: day.workouts.map(\.loggedAt))
        return spent ? nil : offer
    }

    /// "Log a meal" at a restaurant: Log meal's start, empty, with the meal type picked by the time of day.
    func worldArrivalMealSeed(now: Date = Date()) -> MealSheetSeed {
        MealSheetSeed(description: "", mealType: WorldArrivalRules.mealType(hour: Calendar.current.component(.hour, from: now)))
    }

    /// "Find the menu" at a restaurant: Log meal's start worded so the food lookup searches the web by the place's
    /// name, as at a favourite place to eat; nil with no restaurant offered. Never the person's location.
    func worldArrivalMenuSeed() -> MealSheetSeed? {
        guard let offer = worldArrivalOffer, offer.kind == .restaurant else { return nil }
        return MealSheetSeed(description: "from \(offer.name)")
    }

    /// "Start today's plan" at a gym that isn't a pinned space: today's plan's next guided session, committing the
    /// plan first as Move's "Start today's workout" does, with the active space left as it is. The offer goes once
    /// a session starts. Nil when nothing is left to guide.
    func startTodaysPlanAtArrival() -> WorkoutProgram.SessionSuggestion? {
        let plan = commitTodaysGuidedWorkoutPlan(intensity: recommendedWorkoutIntensity() ?? .moderate)
        let session = GuidedWorkoutAvailability.firstGuidable(in: plan, excluding: guidedCompletedSessionIDs,
                                                              loggedGuidedWorkoutNames: loggedGuidedWorkoutNamesToday)
        if session != nil { worldLocation.hotelOffers.clearArrival() }
        return session
    }
}
