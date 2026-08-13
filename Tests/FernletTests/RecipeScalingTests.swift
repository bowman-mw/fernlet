import Foundation
import Testing
import FernletDomainModel

/// F4 (decision §11.4): recipe scaling is a pure, non-persisted, view/share-time proportional
/// transform. These tests pin the engine's proportionality, the per-serving invariant, nil-
/// micronutrient preservation, the integer-yield guard, unscalable-recipe behavior, and — critically
/// — that computing a scaled view never mutates the source recipe (no store write, value semantics).
struct RecipeScalingTests {

    private func makeRecipe(servings: Int, quantities: [Double]) -> RecipeDefinition {
        let now = Date()
        let ingredients = quantities.map {
            RecipeIngredient(foodItemId: UUID(), quantity: $0, unit: "g")
        }
        return RecipeDefinition(
            name: "Test Bake",
            servings: servings,
            ingredients: ingredients,
            notes: "",
            source: "manual",
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeWebImport() -> RecipeDefinition {
        RecipeDefinition(
            name: "Imported",
            servings: 4,
            ingredients: [],
            notes: "",
            source: "imported",
            createdAt: Date(),
            updatedAt: Date(),
            webImport: RecipeWebImport(sourceURLString: "https://example.com", ingredientLines: ["1 cup flour", "2 eggs"])
        )
    }

    @Test func scaleFactorIsTargetOverBase() {
        #expect(RecipeScaling.scaleFactor(baseServings: 2, targetYield: 6) == 3.0)
        #expect(RecipeScaling.scaleFactor(baseServings: 4, targetYield: 2) == 0.5)
        // Identity when cooking at the stored yield.
        #expect(RecipeScaling.scaleFactor(baseServings: 4, targetYield: 4) == 1.0)
        // Zero/negative inputs floor to 1 rather than producing NaN/inf.
        #expect(RecipeScaling.scaleFactor(baseServings: 0, targetYield: 3) == 3.0)
        #expect(RecipeScaling.scaleFactor(baseServings: 3, targetYield: 0) == 1.0 / 3.0)
    }

    @Test func ingredientQuantitiesScaleByFactor() {
        let recipe = makeRecipe(servings: 2, quantities: [100, 50, 12.5])
        let scaled = RecipeScaling.scaledIngredients(recipe, forYield: 6) // factor 3
        #expect(scaled.count == 3)
        #expect(scaled[0].quantity == 300)
        #expect(scaled[1].quantity == 150)
        #expect(scaled[2].quantity == 37.5)
    }

    @Test func scalingPreservesIngredientIdentity() {
        let recipe = makeRecipe(servings: 2, quantities: [100, 50])
        let scaled = RecipeScaling.scaledIngredients(recipe, forYield: 4)
        // id + foodItemId are preserved so the resolved-name lookup and ForEach identity still work.
        #expect(scaled[0].id == recipe.ingredients[0].id)
        #expect(scaled[0].foodItemId == recipe.ingredients[0].foodItemId)
        #expect(scaled[0].unit == recipe.ingredients[0].unit)
    }

    @Test func totalsScaleAndPerServingIsInvariant() {
        let recipe = makeRecipe(servings: 2, quantities: [100])
        let base = MacroTotals(protein: 10, carbs: 40, fat: 6)

        // Whole-recipe totals scale up.
        let scaledUp = RecipeScaling.scaledTotals(base, baseServings: 2, targetYield: 6) // factor 3
        #expect(scaledUp == MacroTotals(protein: 30, carbs: 120, fat: 18))

        // Per-serving is invariant: base/base == scaled/target, across up- and down-scaling.
        func perServing(_ t: MacroTotals, _ n: Int) -> MacroTotals {
            MacroTotals(
                protein: Int((Double(t.protein) / Double(n)).rounded()),
                carbs: Int((Double(t.carbs) / Double(n)).rounded()),
                fat: Int((Double(t.fat) / Double(n)).rounded())
            )
        }
        let basePerServing = perServing(base, recipe.servings)
        for target in [1, 3, 4, 6, 8, 24] {
            let scaled = RecipeScaling.scaledTotals(base, baseServings: recipe.servings, targetYield: target)
            #expect(perServing(scaled, target) == basePerServing)
        }

        // Down-scaling too (base 4 -> 2).
        let bigBase = MacroTotals(protein: 20, carbs: 80, fat: 12)
        let scaledDown = RecipeScaling.scaledTotals(bigBase, baseServings: 4, targetYield: 2)
        #expect(scaledDown == MacroTotals(protein: 10, carbs: 40, fat: 6))
        #expect(perServing(scaledDown, 2) == perServing(bigBase, 4))
    }

    @Test func micronutrientScalingPreservesNil() {
        // iron present, everything else nil.
        let base = Micronutrients(iron: 6.0)
        let scaled = RecipeScaling.scaledMicronutrients(base, baseServings: 2, targetYield: 6) // factor 3
        #expect(scaled.iron == 18.0)
        // Absent nutrients stay absent — never coerced to 0.
        #expect(scaled.calcium == nil)
        #expect(scaled.vitaminC == nil)
        #expect(scaled.sodium == nil)
    }

    @Test func yieldRangeIsIntegerOneToTwentyFour() {
        #expect(RecipeScaling.yieldRange == 1...24)
        #expect(RecipeScaling.clampedYield(0) == 1)
        #expect(RecipeScaling.clampedYield(1) == 1)
        #expect(RecipeScaling.clampedYield(24) == 24)
        #expect(RecipeScaling.clampedYield(99) == 24)
        #expect(RecipeScaling.clampedYield(-5) == 1)
    }

    @Test func webImportRecipeIsNotScalable() {
        let recipe = makeWebImport()
        #expect(RecipeScaling.isScalable(recipe) == false)
        // No fake scaling: the structured-ingredient result is empty, so the UI falls back to lines.
        #expect(RecipeScaling.scaledIngredients(recipe, forYield: 8).isEmpty)
    }

    @Test func ingredientlessRecipeIsNotScalable() {
        let recipe = makeRecipe(servings: 2, quantities: [])
        #expect(RecipeScaling.isScalable(recipe) == false)
        #expect(RecipeScaling.scaledIngredients(recipe, forYield: 4).isEmpty)
    }

    @Test func structuredRecipeIsScalable() {
        let recipe = makeRecipe(servings: 4, quantities: [100, 200])
        #expect(RecipeScaling.isScalable(recipe))
    }

    @Test func scalingDoesNotMutateSourceRecipe() {
        let recipe = makeRecipe(servings: 2, quantities: [100, 50, 12.5])
        let snapshot = recipe // RecipeDefinition is a value type — capture the "before".

        // Exercise every engine entry point the view uses.
        _ = RecipeScaling.scaledIngredients(recipe, forYield: 6)
        _ = RecipeScaling.scaledTotals(MacroTotals(protein: 10, carbs: 40, fat: 6), baseServings: recipe.servings, targetYield: 6)
        _ = RecipeScaling.scaledMicronutrients(Micronutrients(iron: 6.0), baseServings: recipe.servings, targetYield: 6)

        // The source recipe is byte-for-byte unchanged — no in-place mutation, no store write.
        #expect(recipe == snapshot)
        #expect(recipe.servings == 2)
        #expect(recipe.ingredients.map(\.quantity) == [100, 50, 12.5])
    }

    @Test func identityYieldReturnsUnchangedQuantities() {
        let recipe = makeRecipe(servings: 3, quantities: [90, 30])
        let scaled = RecipeScaling.scaledIngredients(recipe, forYield: 3)
        #expect(scaled.map(\.quantity) == recipe.ingredients.map(\.quantity))
    }
}
