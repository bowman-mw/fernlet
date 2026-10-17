import Foundation
import FernletDomainModel

/// One recipe the pre-log review sheet offers to save, with the person's choices: save it or not, its
/// name and its yield.
///
/// A resolution offers the dish-decomposition tier's `suggestedRecipe` and the plan tiers'
/// `offeredRecipes` (one per multi-ingredient item); ``offers(for:)`` lists them, each switched on, so
/// the sheet shows every recipe it would add before anything is added. Nothing here persists: the sheet
/// hands ``confirmedRecipe(reviewedComponents:)`` of each offer still switched on back to the caller,
/// which mints them through `FernletStore.commitResolution` as `createdRecipes`. Until 2026-10-16 the
/// plan tiers' recipes never appeared here and were minted anyway, on the review's confirm and on every
/// auto-commit alike (bug confirmation 2026-10-15, food-ai §4).
nonisolated struct MealReviewRecipeOffer: Identifiable {
    /// The recipe as the resolver built it.
    let base: RecipeDefinition
    /// Whether the person keeps the recipe; on by default, as the offer was before this list existed.
    var isSaved = true
    /// The name the recipe is saved under (the base name until edited).
    var name: String
    /// How many servings the recipe makes (the base yield until edited, at least 1).
    var servings: Int

    var id: UUID { base.id }

    /// An offer of `base`, switched on, under its own name and yield.
    init(base: RecipeDefinition) {
        self.base = base
        self.name = base.name
        self.servings = max(base.servings, 1)
    }

    /// Every recipe `resolution` offers, the decomposition tier's first.
    static func offers(for resolution: MealResolution) -> [MealReviewRecipeOffer] {
        ([resolution.suggestedRecipe].compactMap { $0 } + resolution.offeredRecipes).map(Self.init(base:))
    }

    /// The recipe to mint, with the person's name and yield applied — or `nil` when they switched the
    /// offer off.
    ///
    /// The ingredient quantities are rebuilt from the REVIEWED per-serving component grams (each × the
    /// chosen yield gives the full batch), not from the resolver's original amounts. Components can only
    /// be re-quantified in review, never added or removed, so the `foodItemId`s of the recipe's
    /// ingredients find their components — keeping the promised invariant (per-serving == the plate)
    /// true even when the person corrected a component's grams, instead of minting the pre-edit amounts.
    func confirmedRecipe(reviewedComponents: [MealComponentCorrectionInput]) -> RecipeDefinition? {
        guard isSaved else { return nil }
        var recipe = base
        let oldYield = max(base.servings, 1)
        let newYield = max(servings, 1)
        // The reviewed per-serving grams, keyed by the catalog item they bound to.
        var editedPerServing: [UUID: MealComponentCorrectionInput] = [:]
        for component in reviewedComponents {
            if let foodItemId = component.foodItemId { editedPerServing[foodItemId] = component }
        }
        recipe.ingredients = base.ingredients.map { ingredient in
            if let edited = editedPerServing[ingredient.foodItemId] {
                return RecipeIngredient(
                    id: ingredient.id,
                    foodItemId: ingredient.foodItemId,
                    quantity: edited.quantity * Double(newYield),
                    unit: edited.unit
                )
            }
            // No matching reviewed component (not expected for an offered recipe) — fall back to
            // yield-scaling the resolver's original batch quantity so nothing is dropped.
            let factor = Double(newYield) / Double(oldYield)
            return RecipeIngredient(id: ingredient.id, foodItemId: ingredient.foodItemId, quantity: ingredient.quantity * factor, unit: ingredient.unit)
        }
        recipe.servings = newYield
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.name = trimmed.isEmpty ? base.name : trimmed
        recipe.updatedAt = Date()
        return recipe
    }
}
