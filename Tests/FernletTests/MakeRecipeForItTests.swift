import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Recipes as building blocks, step 7 (design §12, picks P11a/P12a): what "Make a recipe for it" starts
/// a new recipe with, and the line it binds using the whole batch.
@MainActor
struct MakeRecipeForItTests {
    @Test func theNewRecipeIsNamedAfterTheLineAndMakesItsAmount() {
        let seed = NewRecipeSeed(row: ManualRecipeIngredientInput(name: "dragonfruit sauce", quantity: 1, unit: "cup"))
        #expect(seed.name == "Dragonfruit sauce")
        #expect(seed.makes == RecipeYield(quantity: 1, unit: "cup"))
        let counted = NewRecipeSeed(row: ManualRecipeIngredientInput(name: "Tortillas", quantity: 4, unit: "each"))
        #expect(counted.makes == nil)   // a count is what Servings says
    }

    @Test func aRecipeMadeForALineTotalsTheWholeBatchOnThatLine() throws {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Dragonfruit sauce", servings: 1,
                                    ingredients: [ManualRecipeIngredientInput(name: "Dragonfruit", quantity: 200, unit: "g",
                                                                              protein: 2, carbs: 40, fat: 0)])
        store.setRecipeMakes(RecipeYield(quantity: 1, unit: "cup"), forRecipeID: sauce.id)
        let food = try #require(store.prepareRecipeFood(for: sauce))
        let row = ManualRecipeIngredientInput(name: food.name, selectedFoodItemId: food.id,
                                              quantity: Double(sauce.servings), unit: "serving")
        let pasta = store.addRecipe(name: "Pasta", servings: 1, ingredients: [row])
        #expect(store.macroTotals(for: pasta).carbs == 40)
        #expect(store.linesWithoutNutrition(in: pasta) == 0)
    }
}
