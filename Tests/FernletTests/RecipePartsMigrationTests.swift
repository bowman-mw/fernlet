import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// Recipes as building blocks, step 5 (design §7, pick P07a): multipart recipes become separate
/// recipes, with identical nutrition, the same ids on every device, and nothing lost.
@MainActor
struct RecipePartsMigrationTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated private static func food(_ name: String, protein: Int, carbs: Int, fat: Int) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: protein, carbs: carbs, fat: fat),
                 micronutrients: Micronutrients(), category: "custom ingredient", source: .manual, tags: [])
    }

    private struct Salad {
        let oil = RecipePartsMigrationTests.food("Olive oil", protein: 0, carbs: 0, fat: 100)
        let lemon = RecipePartsMigrationTests.food("Lemon juice", protein: 1, carbs: 7, fat: 0)
        let romaine = RecipePartsMigrationTests.food("Romaine", protein: 1, carbs: 3, fat: 0)
        let recipe: RecipeDefinition
        init(servings: Int = 3, extraStepsOnlyPart: Bool = false) {
            let oilLine = RecipeIngredient(foodItemId: oil.id, quantity: 37, unit: "g")
            let lemonLine = RecipeIngredient(foodItemId: lemon.id, quantity: 23, unit: "g")
            let romaineLine = RecipeIngredient(foodItemId: romaine.id, quantity: 210, unit: "g")
            let whisk = RecipeStep(text: "Whisk"), chill = RecipeStep(text: "Chill the bowls"), toss = RecipeStep(text: "Toss")
            var parts = [RecipeComponent(name: "Lemon dressing", ingredientIDs: [oilLine.id, lemonLine.id], stepIDs: [whisk.id])]
            if extraStepsOnlyPart { parts.append(RecipeComponent(name: "Bowls", stepIDs: [chill.id])) }
            parts.append(RecipeComponent(name: "Salad", ingredientIDs: [romaineLine.id], stepIDs: [toss.id]))
            recipe = RecipeDefinition(name: "Garden salad", servings: servings, ingredients: [oilLine, lemonLine, romaineLine],
                                      source: "manual", createdAt: RecipePartsMigrationTests.now, updatedAt: RecipePartsMigrationTests.now,
                                      steps: extraStepsOnlyPart ? [whisk, chill, toss] : [whisk, toss], components: parts)
        }
        var foods: [FoodItem] { [oil, lemon, romaine] }
    }

    @Test func everyPartButTheLastBecomesARecipeAndNutritionIsUnchanged() throws {
        for servings in [1, 3, 7] {
            let salad = Salad(servings: servings)
            let before = MealBuilder.macroTotals(for: salad.recipe, foodItems: salad.foods)
            let beforeMicros = MealBuilder.micronutrientTotals(for: salad.recipe, foodItems: salad.foods)
            let result = RecipePartsMigration.migrated([salad.recipe])
            #expect(result.converted == 1)
            let parent = try #require(result.recipes.first)
            let dressing = try #require(result.recipes.last)
            #expect(result.recipes.count == 2)
            #expect(parent.id == salad.recipe.id && parent.components == nil)
            #expect(dressing.name == "Lemon dressing" && dressing.servings == servings)
            #expect(dressing.steps?.map(\.text) == ["Whisk"])
            #expect(parent.steps?.map(\.text) == ["Toss"])
            #expect(parent.ingredients.first?.foodItemId == dressing.id)

            let foods = RecipeFoodSync.synced(foodItems: salad.foods, recipes: result.recipes)
            #expect(MealBuilder.macroTotals(for: parent, foodItems: foods) == before)
            #expect(MealBuilder.micronutrientTotals(for: parent, foodItems: foods) == beforeMicros)
        }
    }

    @Test func twoDevicesMakeTheSameRecipesAndItRunsOnce() {
        let salad = Salad()
        let first = RecipePartsMigration.migrated([salad.recipe]).recipes
        let second = RecipePartsMigration.migrated([salad.recipe]).recipes
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.ingredients) == second.map(\.ingredients))
        let again = RecipePartsMigration.migrated(first)
        #expect(again.converted == 0 && again.recipes == first)
        // A part recipe synced in from the other device is not made twice.
        let merged = RecipePartsMigration.migrated([salad.recipe, first[1]])
        #expect(merged.recipes.map(\.id).count == 2)
    }

    @Test func aStepsOnlyPartKeepsItsStepsInTheRecipe() throws {
        let salad = Salad(extraStepsOnlyPart: true)
        let result = RecipePartsMigration.migrated([salad.recipe])
        #expect(result.recipes.count == 2)
        let parent = try #require(result.recipes.first)
        #expect(parent.steps?.map(\.text) == ["Bowls: Chill the bowls", "Toss"])
    }

    @Test func theStoreConvertsAtLaunchAndCooksTheDressingFirst() async throws {
        let store = makeTestStore()
        let saved = store.addRecipe(name: "Garden salad", servings: 4, parts: [
            RecipeComponentInput(name: "Lemon dressing",
                                 ingredients: [ManualRecipeIngredientInput(name: "Olive oil", quantity: 30, unit: "g", protein: 0, carbs: 0, fat: 30)],
                                 steps: [RecipeStep(text: "Whisk")]),
            RecipeComponentInput(name: "Salad",
                                 ingredients: [ManualRecipeIngredientInput(name: "Romaine", quantity: 200, unit: "g", protein: 2, carbs: 6, fat: 0)],
                                 steps: [RecipeStep(text: "Toss")]),
        ])
        #expect(saved.isMultipart)   // a save never converts under the editor
        let before = store.macroTotals(for: saved)
        await store.loadBundledFoodItemsForLaunch()
        let parent = try #require(store.recipes.first { $0.id == saved.id })
        #expect(!parent.isMultipart)
        #expect(store.recipes.contains { $0.name == "Lemon dressing" })
        #expect(store.macroTotals(for: parent) == before)
        #expect(store.cookingSteps(for: parent).map(\.step.text) == ["Whisk", "Toss"])
        #expect(store.showsRecipePartsMigratedNote)
        store.dismissRecipePartsMigratedNote()
        #expect(!store.showsRecipePartsMigratedNote)
    }
}
