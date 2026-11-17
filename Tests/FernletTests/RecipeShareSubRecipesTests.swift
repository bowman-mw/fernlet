import Foundation
import Testing
import FernletDomainModel
import FernletExchange
import FernletSocial
import FoodCatalog
@testable import Fernlet

/// Recipes as building blocks, step 6 (design §9, pick P09a): a recipe that uses others is shared with
/// them, older readers still total it and see the sub-recipes' steps, and the hash-covered packet sends
/// the sub-recipes as fixed ingredients.
@MainActor
struct RecipeShareSubRecipesTests {
    /// A store holding Pasta, which uses 2 of Dragonfruit sauce's 4 servings.
    private func pastaStore() -> (store: FernletStore, pasta: RecipeDefinition, sauce: RecipeDefinition) {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Dragonfruit sauce", servings: 4,
                                    ingredients: [ManualRecipeIngredientInput(name: "Dragonfruit", quantity: 400, unit: "g",
                                                                              protein: 4, carbs: 80, fat: 0)],
                                    steps: [RecipeStep(text: "Blend")])
        let pasta = store.addRecipe(name: "Pasta", servings: 2,
                                    ingredients: [ManualRecipeIngredientInput(name: sauce.name, selectedFoodItemId: sauce.id,
                                                                              quantity: 2, unit: "serving"),
                                                  ManualRecipeIngredientInput(name: "Spaghetti", quantity: 200, unit: "g",
                                                                              protein: 26, carbs: 150, fat: 3)],
                                    steps: [RecipeStep(text: "Toss")])
        return (store, pasta, sauce)
    }

    private func localPayload(_ store: FernletStore, _ recipe: RecipeDefinition) throws -> SharedRecipePayload {
        try #require(store.proximityRecipeSharePayload(for: recipe).recipe.local)
    }

    @Test func theShareCarriesTheSubRecipeAndLabelledStepsForOlderReaders() throws {
        let (store, pasta, _) = pastaStore()
        let payload = try localPayload(store, pasta)
        #expect(payload.subRecipes?.map(\.name) == ["Dragonfruit sauce"])
        #expect(payload.ingredients.first?.subRecipeIndex == 0)
        #expect(payload.ingredients.first?.carbs == 40)   // 2 of 4 servings, inline for older readers
        #expect(payload.steps?.map(\.text) == ["Dragonfruit sauce: Blend", "Pasta: Toss"])
        #expect(payload.components?.map(\.name) == ["Dragonfruit sauce", "Pasta"])

        let decoded = try JSONDecoder().decode(SharedRecipePayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded == payload)
    }

    @Test func badSubRecipeReferencesAreRefused() throws {
        let (store, pasta, _) = pastaStore()
        var payload = try localPayload(store, pasta)
        payload.ingredients[0].subRecipeIndex = 3
        #expect(throws: RecipeImportError.invalidPayload) {
            try JSONDecoder().decode(SharedRecipePayload.self, from: JSONEncoder().encode(payload))
        }
        var selfReferencing = try localPayload(store, pasta)
        selfReferencing.subRecipes?[0].ingredients[0].subRecipeIndex = 0
        #expect(throws: RecipeImportError.invalidPayload) {
            try JSONDecoder().decode(SharedRecipePayload.self, from: JSONEncoder().encode(selfReferencing))
        }
    }

    @Test func aSubRecipeNeverCarriesSubRecipesOfItsOwn() throws {
        let (store, pasta, _) = pastaStore()
        var payload = try localPayload(store, pasta)
        let nested = payload
        payload.subRecipes?[0].subRecipes = [nested]
        let decoded = try JSONDecoder().decode(SharedRecipePayload.self, from: JSONEncoder().encode(payload))
        #expect(decoded.subRecipes?[0].subRecipes == nil)
    }

    @Test func thePacketSendsSubRecipesAsFixedIngredientsWithTheirSteps() throws {
        let (store, pasta, _) = pastaStore()
        let packet = try RecipeExchangePacket(recipe: store.sharingDefinition(for: pasta),
                                              foodItems: store.foodCatalog.items(forRecipe: pasta), includesNotes: true)
        #expect(!packet.recipe.carriesSubRecipes)
        #expect(packet.formatVersion == RecipeExchangePacket.multipartFormatVersion)
        #expect(packet.recipe.steps?.map(\.text) == ["Dragonfruit sauce: Blend", "Pasta: Toss"])
        #expect(try RecipeExchangePacket.decode(packet.encodedData()) == packet)
    }

    @Test func importingMakesTheSubRecipeAndReusesItTheSecondTime() throws {
        let (sender, pasta, _) = pastaStore()
        let text = String(decoding: try JSONEncoder().encode(try localPayload(sender, pasta)), as: UTF8.self)
        let senderTotals = sender.macroTotals(for: pasta)

        let receiver = makeTestStore()
        let imported = try receiver.importRecipe(from: text)
        let sauce = try #require(receiver.recipes.first { $0.name == "Dragonfruit sauce" })
        #expect(imported.ingredients.first?.foodItemId == sauce.id)
        #expect(sauce.steps?.map(\.text) == ["Blend"])
        #expect(imported.steps?.map(\.text) == ["Toss"])
        #expect(!imported.isMultipart)
        #expect(receiver.macroTotals(for: imported) == senderTotals)
        #expect(receiver.cookingSteps(for: imported).map(\.step.text) == ["Blend", "Toss"])

        let again = try receiver.importRecipe(from: text)
        #expect(receiver.recipes.filter { $0.name == "Dragonfruit sauce" }.count == 1)
        #expect(again.ingredients.first?.foodItemId == sauce.id)
    }
}
