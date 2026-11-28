import FernletDomainModel
import FernletScoring
import Foundation
import WorldMapStore

/// Which kind of place an arrival offer is for (owner's picks N1 to N5, 2026-11-27): a restaurant, where the blue
/// button offers "Log a meal", or a gym, where it offers today's plan or a workout. Frozen tokens.
nonisolated enum WorldArrivalKind: String, CaseIterable, Sendable {
    /// A restaurant: "Log a meal", then "Find the menu" (N2-A).
    case restaurant
    /// A gym: "Start today's plan" when one is due, else "Log a workout" and "Suggest a workout" (N3-A).
    case gym

    /// The arrival kind of a drive-end lookup's place, nil for a hotel or a station (they have their own offers).
    init?(_ category: WorldNearbyCategory) {
        switch category {
        case .restaurant: self = .restaurant
        case .gym: self = .gym
        case .hotel, .station: return nil
        }
    }

    /// The arrival kind of a place the foreground stop lookup decided on, nil for a park, a beach or a campground.
    init?(_ category: PlaceCategory) {
        switch category {
        case .foodAndDrink: self = .restaurant
        case .gym: self = .gym
        case .park, .beach, .campground: return nil
        }
    }
}

/// An arrival offer: the restaurant or gym the person arrived at, by Apple's name, where it is, where the person was
/// when it was found, and when (owner, 2026-11-27). Held in memory only (``WorldHotelOfferKeeper/arrival``), never
/// written. The name never reaches the button (N4-B); it is used only to word "Find the menu"'s search.
nonisolated struct WorldArrivalOffer: Equatable, Sendable {
    /// Which kind of place it is.
    let kind: WorldArrivalKind
    /// Apple's name for it, in memory only.
    let name: String
    /// Where the place is (the person's own point, for a place the foreground stop lookup decided on).
    let point: GeoPoint
    /// Where the person was when it was found: the drive's end, or the stop.
    let anchor: GeoPoint
    /// When it was found.
    let since: Date

    /// Whether the offer was used: a meal logged since it was found spends a restaurant's, and a workout logged
    /// since spends a gym's (owner, 2026-11-27: it goes "after a meal is logged or a workout started from it").
    func isSpent(mealsLoggedAt meals: [Date], workoutsLoggedAt workouts: [Date]) -> Bool {
        switch kind {
        case .restaurant: meals.contains { $0 >= since }
        case .gym: workouts.contains { $0 >= since }
        }
    }

    /// Whether a reading at `point` means the person has left: more than ``HomeBook/atRadius`` (120 m) from both the
    /// place and where they were when it was found.
    func isLeft(at point: GeoPoint) -> Bool {
        min(self.point.distance(to: point), anchor.distance(to: point)) > HomeBook.atRadius
    }
}

/// The arrival offers' rules on plain values (owner's picks, 2026-11-27), so they are tested without a store:
///
/// - **The switches** (N5-B): a restaurant's offer rides "Remember places I eat out", a gym's (and, as before, a
///   hotel's) "Remember places I stop at". No switch of its own.
/// - **The drive-end lookup** (N1-B, N7-A) asks the same single request for only the kinds whose switch is on;
///   with both off it asks nothing.
/// - **The meal type** "Log a meal" opens with is picked by the time of day (N2-A), as Log meal's "Auto" rule does.
nonisolated enum WorldArrivalRules {
    /// The kinds a drive's end asks Apple Maps for: hotels and gyms with "Remember places I stop at" on,
    /// restaurants with "Remember places I eat out" on. Empty with both off.
    static func driveEndCategories(remembersPlaces: Bool, remembersEatingOut: Bool) -> [WorldNearbyCategory] {
        var categories: [WorldNearbyCategory] = []
        if remembersPlaces { categories.append(.hotel) }
        if remembersEatingOut { categories.append(.restaurant) }
        if remembersPlaces { categories.append(.gym) }
        return categories
    }

    /// Whether an offer of `kind` may stand with the switches as they are now.
    static func allows(_ kind: WorldArrivalKind, remembersPlaces: Bool, remembersEatingOut: Bool) -> Bool {
        switch kind {
        case .restaurant: remembersEatingOut
        case .gym: remembersPlaces
        }
    }

    /// The nearest restaurant or gym among `places` within `radius` metres of `point`, as an arrival offer found at
    /// `now`; nil for none.
    static func nearestArrival(in places: [WorldNearbyPlace], to point: GeoPoint, radius: Double, now: Date) -> WorldArrivalOffer? {
        let near = places.filter { WorldArrivalKind($0.category) != nil && !$0.name.isEmpty && $0.point.distance(to: point) <= radius }
        guard let place = near.min(by: { $0.point.distance(to: point) < $1.point.distance(to: point) }),
              let kind = WorldArrivalKind(place.category) else { return nil }
        return WorldArrivalOffer(kind: kind, name: place.name, point: place.point, anchor: point, since: now)
    }

    /// The meal type "Log a meal" opens with at `hour` (0 to 23): breakfast, lunch, a snack or dinner, as Log meal's
    /// "Auto" rule picks it for a meal with no telling words.
    static func mealType(hour: Int) -> MealType {
        MealParser.classifyMealType("", hour: hour)
    }
}
