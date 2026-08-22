//
//  FoodPlanning.swift
//  Fernlet
//
//  FernletStore facades added by the 2026-08-21 food redesign (Batch 4): the typed meal-plan
//  write (FOOD-35), the by-hand macro log the meal sheet's "Enter macros by hand" path commits
//  (FOOD-24), and the deduped Recent-meals read behind the dedicated Recent surface (FOOD-07).
//  A separate file, not FernletStore.swift, so the redesign's store surface stays in one place.
//

import Foundation
import DiaryStore
import FernletDomainModel
import FernletScoring

extension FernletStore {
    // MARK: - Typed meal plan (FOOD-35)

    /// Assigns a recipe to a day's plan under a specific meal slot (the planner picker's choice).
    ///
    /// Forwards to `DiaryStore.planRecipe(_:mealType:date:)`, which writes the typed
    /// `plannedMeals` entry AND the legacy `plannedRecipeIDs` id in parallel. The slotless
    /// two-argument `planRecipe(_:date:)` facade remains for legacy callers.
    func planRecipe(_ recipeID: UUID, mealType: MealType?, date: String) {
        diary.planRecipe(recipeID, mealType: mealType, date: date)
    }

    // MARK: - By-hand macro log (FOOD-24)

    /// Logs the meal the user described and macro'd by hand on the log-meal sheet — no resolve
    /// cascade, no AI: the three typed numbers ARE the meal.
    ///
    /// The slot is the sheet's explicit chip choice, or the same by-time "Auto" classification a
    /// typed log follows. Stamped ``MealConfidence/logged`` (entered directly by the user) with
    /// truthful manual provenance; there are no component snapshots and no micronutrients to
    /// invent, so none are.
    @discardableResult
    func logHandEnteredMacroMeal(description: String, mealType: MealType?, macros: Macros) -> Meal {
        let meal = Meal(
            name: MealParser.mealName(from: description),
            mealType: mealType ?? MealParser.classifyMealType(description),
            macros: macros,
            mealSource: .manual,
            isAIFallback: false,
            quality: macros.protein >= Macros.goodProteinThreshold ? .good : .ok,
            confidence: MealConfidence.logged.token,
            note: "Entered by hand.",
            source: MealLogSource.manual
        )
        diary.appendMeal(meal, date: todayKey)
        return meal
    }

    // MARK: - Recent meals, deduped (FOOD-07)

    /// The Recent-meals surface's rows: `recentMeals` deduped case-insensitively by name with the
    /// most recent log winning, capped at the top eight.
    var dedupedRecentMeals: [Meal] {
        Self.dedupedRecentMeals(from: recentMeals)
    }

    /// Pure dedupe behind ``dedupedRecentMeals``: newest-first by `loggedAt`, one row per
    /// case-insensitively folded name (locale-independent fold — this is matching, not display),
    /// first `limit` rows kept. Bounded by the store's own 50-meal recent cap.
    static func dedupedRecentMeals(from meals: [Meal], limit: Int = 8) -> [Meal] {
        var seenNames = Set<String>()
        var deduped: [Meal] = []
        for meal in meals.sorted(by: { $0.loggedAt > $1.loggedAt }) {
            let key = meal.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard seenNames.insert(key).inserted else { continue }
            deduped.append(meal)
            if deduped.count >= limit { break }
        }
        return deduped
    }
}
