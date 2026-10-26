import Foundation

/// A meal logged while the person was at a place to eat: the meal's id (to log it again) and its name (for
/// "Log your usual"). Never its time or day: a restaurant keeps counts, not dates.
///
/// Frozen at rest: `id` and `name` are field names.
public nonisolated struct EatingMeal: Codable, Equatable, Sendable {
    /// The logged meal's id in the food log.
    public let id: UUID
    /// The meal's name as it was logged (at most ``PlaceRecord/maxNameLength``).
    public let name: String

    /// A meal `id` called `name`.
    public init(id: UUID, name: String) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(PlaceRecord.maxNameLength))
    }
}

/// A place the person eats out at ("Remember places I eat out", `b1-qs-food`; owner, 2026-10-22 and World
/// build round 6): the meals logged there, and, after the third, a favourite the blue button offers there
/// (the usual, the camera, the menu search) and the map draws as a bowl.
///
/// What is kept follows the MapKit terms (round 5): Apple's reference to the place, the person's own name
/// for it when they gave one, Fernlet's own point, and the meals. Never Apple's name or category: the name
/// is asked for again by the reference while Fernlet is open. Only food-and-drink places are ever noted
/// (the allowlist), decided on the device at the moment of the visit.
///
/// Frozen at rest: `id`, `placeID`, `label`, `point`, `meals` and `mealCount` are field names.
public nonisolated struct EatingPlace: Codable, Equatable, Identifiable, Sendable {
    /// How many meals make a place a favourite (owner: "after three meals at one place").
    public static let favouriteMeals = 3
    /// The most meals remembered per place (the count goes on).
    public static let maxMeals = 30
    /// The most places to eat kept.
    public static let maxPlaces = 300
    /// How near a reading must be to count as being at the place, in metres.
    public static let atRadius = 75.0

    /// The place's id (the visit log's place id when it has one).
    public let id: UUID
    /// Apple's reference to the place (its name is asked for again by it).
    public let placeID: String
    /// The person's own name for it, once they rename it.
    public var label: String?
    /// Where the person stood there.
    public let point: GeoPoint
    /// The meals logged there, oldest first, at most ``maxMeals``.
    public var meals: [EatingMeal]
    /// How many meals were logged there in all.
    public var mealCount: Int

    /// A place to eat with no meals yet.
    public init(id: UUID = UUID(), placeID: String, label: String? = nil, point: GeoPoint,
                meals: [EatingMeal] = [], mealCount: Int? = nil) {
        self.id = id
        self.placeID = placeID
        self.label = label.flatMap(PlaceRecord.validLabel)
        self.point = point
        self.meals = Array(meals.suffix(Self.maxMeals))
        self.mealCount = max(mealCount ?? meals.count, meals.count)
    }

    /// Whether the blue button offers it and the map draws it.
    public var isFavourite: Bool { mealCount >= Self.favouriteMeals }

    /// The usual: the name logged most often here (the latest breaks a tie), and the latest meal of that name.
    public var usual: EatingMeal? {
        let counts = Dictionary(meals.map { ($0.name.lowercased(), 1) }, uniquingKeysWith: +)
        guard let best = counts.values.max() else { return nil }
        return meals.last { counts[$0.name.lowercased()] == best && !$0.name.isEmpty }
    }

    /// This place with `meal` noted (once).
    public func noting(_ meal: EatingMeal) -> EatingPlace {
        guard !meals.contains(where: { $0.id == meal.id }) else { return self }
        var next = self
        next.meals.append(meal)
        if next.meals.count > Self.maxMeals { next.meals.removeFirst(next.meals.count - Self.maxMeals) }
        next.mealCount += 1
        return next
    }
}

extension Array where Element == EatingPlace {
    /// Whether the meal `id` is already noted at any of these places.
    public func hasNoted(_ id: UUID) -> Bool {
        contains { place in place.meals.contains { $0.id == id } }
    }

    /// The favourite within ``EatingPlace/atRadius`` of `point`, nearest first.
    public func favourite(near point: GeoPoint) -> EatingPlace? {
        filter(\.isFavourite)
            .map { (place: $0, metres: $0.point.distance(to: point)) }
            .filter { $0.metres <= EatingPlace.atRadius }
            .min { $0.metres < $1.metres }?.place
    }
}
