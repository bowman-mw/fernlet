import Foundation

/// Pure, value-level proportional scaling for recipes (F4, decision §11.4).
///
/// **Scaling is a non-persisted view/share-time transform — it never mutates a stored recipe.** This
/// engine holds only the arithmetic (lifted from the `MealComponentCorrectionInput` rescaler in
/// `FoodView`); it takes a `RecipeDefinition` plus a target yield and returns *scaled copies* of the
/// value types. It performs no store writes, resolves no `FoodItem`, and touches no catalog, so it
/// lives below the wall in `FernletDomainModel` where both the UI (`RecipeDetailView`'s "cook for N"
/// control) and a future below-the-wall grocery aggregation (F3 "cook for 6") can call it. `FoodItem`
/// resolution stays the caller's job: totals come in already resolved (from `MealBuilder`/the store),
/// and `scaledIngredients` returns structured quantities the caller resolves through the catalog.
///
/// The transform is deliberately additive-free: it stores nothing, adds no `RecipeDefinition` field,
/// and crosses no wire, so there is no codec/paired-device-strip concern for scaling — that concern
/// belongs to substitution (which forks a recipe with a `parentRecipeID`), a separate feature.
///
/// This is a value-only namespace with no stored state, so adding it does not change the memory
/// layout of any existing `FernletDomainModel` type (it is not the enum-case / stored-property
/// clean-build hazard).
public nonisolated enum RecipeScaling {

    /// Integer yields only, matching the servings `Stepper` range used everywhere for recipe yields.
    /// Fractional yields are intentionally unsupported: `servings` is an `Int` divisor at every log
    /// and display seam, so a "cook for 2.5" would have no consistent per-serving meaning.
    public static let yieldRange: ClosedRange<Int> = 1...24

    /// Clamps a requested yield into the supported integer range `1...24`.
    public static func clampedYield(_ yield: Int) -> Int {
        min(max(yield, yieldRange.lowerBound), yieldRange.upperBound)
    }

    /// The proportional factor that rescales a recipe's WHOLE-BATCH quantities/totals from its stored
    /// base yield to a target yield. Both inputs are floored at 1, so the factor is always finite and
    /// non-negative; cooking a recipe at its own base yield returns exactly `1.0` (identity).
    public static func scaleFactor(baseServings: Int, targetYield: Int) -> Double {
        Double(max(targetYield, 1)) / Double(max(baseServings, 1))
    }

    /// True only when there is structured quantity data to scale. Web imports carry free-text
    /// ingredient lines (no structured `ingredients`) and cannot be proportionally rescaled without
    /// fabricating quantities, so the UI hides/disables the yield control for them rather than faking
    /// it. An otherwise-structured recipe with an empty ingredient list is likewise not scalable.
    public static func isScalable(_ recipe: RecipeDefinition) -> Bool {
        recipe.webImport == nil && recipe.ingredients.isEmpty == false
    }

    /// Structured ingredients with their whole-batch quantities multiplied by the base→target factor.
    /// Pure on the value: it never resolves a `FoodItem`, which is exactly what lets F3 call
    /// `scaledIngredients(recipe, forYield:)` for "cook for 6" aggregation below the wall. Returns an
    /// empty array for non-structured (web-import) or ingredient-less recipes — callers must treat an
    /// empty result as "not scalable" and fall back to the recipe's free-text lines unscaled.
    public static func scaledIngredients(_ recipe: RecipeDefinition, forYield targetYield: Int) -> [RecipeIngredient] {
        guard isScalable(recipe) else { return [] }
        let factor = scaleFactor(baseServings: recipe.servings, targetYield: targetYield)
        return recipe.ingredients.map { ingredient in
            var scaled = ingredient
            scaled.quantity = ingredient.quantity * factor
            return scaled
        }
    }

    /// Whole-recipe macro totals rescaled to a target yield.
    ///
    /// Per-serving is INVARIANT under this transform — that is the entire point (decision §11.4):
    /// scaling the plan changes how much you cook, never what one serving is. Numerically, per-serving
    /// derived from these scaled totals divided by `targetYield` equals per-serving derived from the
    /// base totals divided by `baseServings`, because both the numerator and the denominator scale by
    /// the same factor. The UI therefore keeps its per-serving figure pinned to the base recipe and
    /// only lets the whole-recipe total move.
    public static func scaledTotals(_ base: MacroTotals, baseServings: Int, targetYield: Int) -> MacroTotals {
        let factor = scaleFactor(baseServings: baseServings, targetYield: targetYield)
        return MacroTotals(
            protein: Int((Double(base.protein) * factor).rounded()),
            carbs: Int((Double(base.carbs) * factor).rounded()),
            fat: Int((Double(base.fat) * factor).rounded())
        )
    }

    /// Whole-recipe micronutrient totals rescaled to a target yield. Delegates to the existing
    /// nil-preserving `Micronutrients.scaled(by:)`, so an absent nutrient stays absent (never
    /// silently becomes `0`) after scaling.
    public static func scaledMicronutrients(_ base: Micronutrients, baseServings: Int, targetYield: Int) -> Micronutrients {
        base.scaled(by: scaleFactor(baseServings: baseServings, targetYield: targetYield))
    }
}
