import Foundation
import Testing
import FernletDomainModel
import FernletExchange
import FoodCatalog
@testable import Fernlet

/// Release review 2026-11-18, F3: a share flattens a recipe's sub-recipes' steps into it, and no share
/// can carry more than `SharedRecipeLimits.maxSteps`. The Share screen refuses such a recipe up front
/// (`FernletStore.shareStepOverflow(for:)`) rather than letting a send fail.
@MainActor
struct RecipeShareStepLimitTests {
    private static func steps(_ count: Int, _ label: String) -> [RecipeStep] {
        (1...count).map { RecipeStep(text: "\(label) \($0)") }
    }

    private static func store(ownSteps: Int, sauceSteps: Int) -> (FernletStore, RecipeDefinition) {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Sauce", servings: 2,
                                    ingredients: [ManualRecipeIngredientInput(name: "Tomato", quantity: 200, unit: "g",
                                                                              protein: 2, carbs: 8, fat: 0)],
                                    steps: steps(sauceSteps, "Sauce step"))
        let pasta = store.addRecipe(name: "Pasta", servings: 2,
                                    ingredients: [ManualRecipeIngredientInput(name: sauce.name, selectedFoodItemId: sauce.id,
                                                                              quantity: 2, unit: "serving")],
                                    steps: steps(ownSteps, "Pasta step"))
        return (store, pasta)
    }

    @Test func aRecipeWhoseSubRecipeStepsPassTheLimitIsRefusedBeforeSending() throws {
        let (store, pasta) = Self.store(ownSteps: 40, sauceSteps: 25)
        #expect(store.shareStepOverflow(for: pasta) == 65)
        // The limit is real: the packet every outside share builds refuses this recipe.
        #expect(throws: (any Error).self) {
            try RecipeExchangePacket(recipe: store.sharingDefinition(for: pasta),
                                     foodItems: store.foodCatalog.items(forRecipe: pasta), includesNotes: true)
        }
    }

    @Test func aRecipeWithinTheLimitSharesAsBefore() throws {
        let (store, pasta) = Self.store(ownSteps: 35, sauceSteps: 25)
        #expect(store.shareStepOverflow(for: pasta) == nil)
        let packet = try RecipeExchangePacket(recipe: store.sharingDefinition(for: pasta),
                                              foodItems: store.foodCatalog.items(forRecipe: pasta), includesNotes: true)
        #expect(packet.recipe.steps?.count == SharedRecipeLimits.maxSteps)
    }
}
