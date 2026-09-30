// RecipePortionGramsMemoryTests.swift
// FernletTests
//
// Ingredient-search round F4b: the recipe editor's "grams in one" memory — the grams a person gives
// for one of a food in place of a USDA typical size, remembered on this device when the recipe is
// saved and offered first the next time under "Your size". A new persisted surface: its wipe
// disposition lives in Docs/PrivacyWipeCoverage.md, `PrivacyWipeCoverageTests.wipeManifest` and
// `PersistedSurfaceWipeBoundaryTests.dispositions`; this suite pins the value half and the store's
// save and wipe paths.

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the "grams in one" sidecar and where the store writes and clears it.
@MainActor
struct RecipePortionGramsMemoryTests {
    static func personal(_ label: String, _ grams: Double) -> RecipePortionOption {
        RecipePortionOption(source: .personal, label: label, gramsPerOne: grams, dimension: .count)
    }

    /// Only a bound row counted in the person's own size is remembered — not a USDA portion, a typical
    /// size left as it is, or an unbound (custom) row.
    @Test func onlyThePersonsOwnSizesAreRemembered() throws {
        let defaults = uniqueRecipePortionGramsDefaults()
        let avocado = UUID()
        let banana = UUID()
        let typical = RecipePortionOption(source: .typicalSize, label: "fruit", gramsPerOne: 136, dimension: .count)
        let usda = RecipePortionOption(source: .usdaPortion, label: "medium", gramsPerOne: 118, dimension: .count)
        RecipePortionGramsMemory.remember(from: [
            ManualRecipeIngredientInput(name: "Avocado", selectedFoodItemId: avocado, quantity: 1, unit: "g", portion: Self.personal("fruit", 150)),
            ManualRecipeIngredientInput(name: "Avocado", selectedFoodItemId: avocado, quantity: 1, unit: "g", portion: typical),
            ManualRecipeIngredientInput(name: "Banana", selectedFoodItemId: banana, quantity: 1, unit: "g", portion: usda),
            ManualRecipeIngredientInput(name: "Mine", quantity: 1, unit: "each", protein: 3, portion: Self.personal("each", 40))
        ], defaults: defaults)
        #expect(RecipePortionGramsMemory.measures(for: avocado, defaults: defaults) == [RecipeHouseholdMeasure(label: "fruit", gramsPerUnit: 150)])
        #expect(RecipePortionGramsMemory.measures(for: banana, defaults: defaults).isEmpty)
    }

    /// One answer per food and label, the newest; newest first; bounded at the cap on the write AND the
    /// read side; cleared by the wipe.
    @Test func oneAnswerPerFoodAndLabelBoundedAndCleared() throws {
        let defaults = uniqueRecipePortionGramsDefaults()
        let food = UUID()
        let fruit = try #require(RecipePortionGrams(foodItemID: food, measure: RecipeHouseholdMeasure(label: "fruit", gramsPerUnit: 150)))
        let large = try #require(RecipePortionGrams(foodItemID: food, measure: RecipeHouseholdMeasure(label: "large", gramsPerUnit: 200)))
        RecipePortionGramsMemory.remember([fruit, large], defaults: defaults)
        let corrected = try #require(RecipePortionGrams(foodItemID: food, measure: RecipeHouseholdMeasure(label: "fruit", gramsPerUnit: 160)))
        RecipePortionGramsMemory.remember([corrected], defaults: defaults)
        #expect(RecipePortionGramsMemory.measures(for: food, defaults: defaults).map(\.gramsPerUnit) == [160, 200])
        #expect(RecipePortionGrams(foodItemID: food, measure: RecipeHouseholdMeasure(label: "", gramsPerUnit: 3)) == nil)
        let many = (0..<(RecipePortionGramsMemory.maxRememberedPortions + 20)).compactMap { index in
            RecipePortionGrams(foodItemID: UUID(), measure: RecipeHouseholdMeasure(label: "each", gramsPerUnit: Double(index + 1)))
        }
        RecipePortionGramsMemory.remember(many, defaults: defaults)
        let data = try #require(defaults.data(forKey: RecipePortionGramsMemory.defaultsKey))
        let stored = try JSONDecoder().decode([RecipePortionGrams].self, from: data)
        #expect(stored.count == RecipePortionGramsMemory.maxRememberedPortions)
        #expect(RecipePortionGramsMemory.measures(for: food, defaults: defaults).isEmpty, "the oldest were evicted")
        RecipePortionGramsMemory.clearAll(defaults: defaults)
        #expect(defaults.data(forKey: RecipePortionGramsMemory.defaultsKey) == nil)
    }

    /// The store remembers a size when a recipe is SAVED — the one-part and the multipart save — hands
    /// it back to the editor, and clears it in the wipe funnel.
    @Test func theStoreRemembersOnSaveAndForgetsOnWipe() throws {
        let avocado = FoodItem(name: "Avocado, Hass, peeled, raw", servingSize: 100, servingUnit: "g",
                               macros: Macros(protein: 2, carbs: 9, fat: 15), micronutrients: Micronutrients(),
                               category: "Fruits", source: .usda, dataType: .srLegacy, tags: [],
                               portions: [FoodPortion(amount: 1, unit: "RACC", gramWeight: 140)])
        let store = makeTestStore(bundledFoodItems: [avocado])
        let row = ManualRecipeIngredientInput(name: avocado.name, selectedFoodItemId: avocado.id, quantity: 2, unit: "g",
                                              portion: Self.personal("fruit", 150))
        let recipe = store.addRecipe(name: "Guacamole", servings: 2, ingredients: [row])
        #expect(recipe.ingredients.first?.quantity == 300 && recipe.ingredients.first?.householdMeasure?.label == "fruit")
        #expect(store.rememberedPortionGrams(for: avocado.id) == [RecipeHouseholdMeasure(label: "fruit", gramsPerUnit: 150)])
        let part = RecipeComponentInput(name: "Dip", ingredients: [
            ManualRecipeIngredientInput(name: avocado.name, selectedFoodItemId: avocado.id, quantity: 1, unit: "g",
                                        portion: Self.personal("fruit", 140))
        ], steps: [])
        store.updateRecipe(recipe, name: "Guacamole", servings: 2, parts: [part])
        #expect(store.rememberedPortionGrams(for: avocado.id).first?.gramsPerUnit == 140)
        _ = store.resetAll()
        #expect(store.rememberedPortionGrams(for: avocado.id).isEmpty, "the wipe funnel (resetAll, which deleteAllData reaches) clears the sidecar")
    }
}
