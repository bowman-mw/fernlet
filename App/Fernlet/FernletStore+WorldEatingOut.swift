import FernletDomainModel
import FernletScoring
import Foundation
import WorldMapStore

/// "Remember places I eat out" on the store (World build round 6; `b1-qs-food`, `b3-qs-food-camera`;
/// owner, 2026-10-22): the meals logged at a place to eat are noted there (``WorldPlacesKeeper``), and
/// after the third it is a favourite the blue button offers there: the usual in one tap, the camera on
/// your own, the menu search by name. What is kept follows the MapKit terms: Apple's reference, the
/// person's own name, Fernlet's point, the meals (no dates). Nothing in a decoy.
extension FernletStore {
    /// Notes today's meals logged during the visit to a place to eat under way (or just ended): the map
    /// coming to the front after the person logged a meal in Food.
    func noteWorldMealsEatenOut(now: Date = Date()) {
        guard !duressSessionActive else { return }
        let meals = day.meals.map { WorldLoggedMeal(id: $0.id, name: $0.name, loggedAt: $0.loggedAt) }
        worldPlaces.noteMeals(meals, now: now)
    }

    /// The favourite place to eat within 75 m of a precise `fix`, for the blue button's card; nil anywhere
    /// else or in a decoy. Its usual is offered only when that meal can still be logged again.
    func worldEatingOut(near fix: WorldFix?) -> WorldQuickStartContext.EatingOut? {
        guard !duressSessionActive, let fix, fix.isPrecise,
              let place = worldPlaces.eatingPlaces.favourite(near: fix.point) else { return nil }
        return WorldQuickStartContext.EatingOut(id: place.id, name: worldEatingName(place), meals: place.mealCount,
                                                usual: worldUsualMeal(at: place.id)?.name)
    }

    /// The favourite place to eat `id`, for its card opened from its icon on the map; nil when it is gone,
    /// not a favourite, or in a decoy.
    func worldEatingOut(id: UUID) -> WorldQuickStartContext.EatingOut? {
        guard !duressSessionActive, let place = worldPlaces.eatingPlaces.first(where: { $0.id == id }), place.isFavourite else { return nil }
        return WorldQuickStartContext.EatingOut(id: place.id, name: worldEatingName(place), meals: place.mealCount,
                                                usual: worldUsualMeal(at: place.id)?.name)
    }

    /// A place to eat's name: the person's own, else Apple's given again by reference (in memory), else "A
    /// place you eat".
    func worldEatingName(_ place: EatingPlace) -> String {
        place.label ?? worldPlaces.eatingNames[place.id] ?? String(localized: WorldPlaceIconCopy.unnamedPlace)
    }

    /// The meal "Log your usual" logs again at the place to eat `id`: the usual meal itself when today's or
    /// the recent meals still hold it, else the latest of the same name there. Nil when none is left.
    func worldUsualMeal(at id: UUID) -> Meal? {
        guard !duressSessionActive, let usual = worldPlaces.eatingPlaces.first(where: { $0.id == id })?.usual else { return nil }
        let candidates = day.meals + recentMeals
        return candidates.first { $0.id == usual.id }
            ?? candidates.first { $0.name.compare(usual.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// What the meal sheet starts with for "Find …'s menu": the usual and the place's name, worded so the
    /// food lookup searches the web by the place's name ("tonkotsu ramen from Hoshi Noodle Bar"); the person
    /// changes the dish. Never the person's location.
    func worldMenuSearchSeed(at id: UUID) -> MealSheetSeed? {
        guard !duressSessionActive, let place = worldPlaces.eatingPlaces.first(where: { $0.id == id }) else { return nil }
        let dish = worldUsualMeal(at: id)?.name ?? place.usual?.name ?? ""
        let name = worldEatingName(place)
        return MealSheetSeed(description: dish.isEmpty ? "from \(name)" : "\(dish) from \(name)")
    }

    /// The meal type the usual is logged under: by the time now ("Auto"), as a typed log is.
    func worldUsualMealType(for meal: Meal) -> MealType {
        MealParser.classifyMealType(meal.name)
    }
}
