import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
import DiaryStore
@testable import Fernlet

/// Release review 2026-11-18, finding F1: a recipe whose lines use a built-in catalog food must still
/// get its stand-in recipe food when another recipe uses it. Built-in rows never enter the store's
/// `foodItems`, so the stand-in has to read them from the catalog.
@MainActor
struct RecipeCatalogStandInTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A built-in (USDA) row: served by the catalog, never saved among the person's foods.
    nonisolated private static func builtIn(_ name: String, protein: Int, carbs: Int, fat: Int) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: protein, carbs: carbs, fat: fat),
                 micronutrients: Micronutrients(), category: "Fats and Oils", source: .usda, dataType: .srLegacy, tags: [])
    }

    private static func dressingParts(oil: FoodItem) -> [RecipeComponentInput] {
        [
            RecipeComponentInput(name: "Lemon dressing",
                                 ingredients: [ManualRecipeIngredientInput(name: oil.name, selectedFoodItemId: oil.id,
                                                                           quantity: 30, unit: "g"),
                                               ManualRecipeIngredientInput(name: "Lemon juice", quantity: 20, unit: "g",
                                                                           protein: 0, carbs: 2, fat: 0)],
                                 steps: [RecipeStep(text: "Whisk")]),
            RecipeComponentInput(name: "Salad",
                                 ingredients: [ManualRecipeIngredientInput(name: "Romaine", quantity: 200, unit: "g",
                                                                           protein: 2, carbs: 6, fat: 0)],
                                 steps: [RecipeStep(text: "Toss")]),
        ]
    }

    @Test func aRecipeWithABuiltInFoodCanBeUsedInsideAnotherRecipe() throws {
        let oil = Self.builtIn("Oil, olive, salad or cooking", protein: 0, carbs: 0, fat: 100)
        let store = makeTestStore(bundledFoodItems: [oil])
        let dressing = store.addRecipe(name: "Dressing", servings: 2,
                                       ingredients: [ManualRecipeIngredientInput(name: oil.name, selectedFoodItemId: oil.id,
                                                                                 quantity: 30, unit: "g")])
        #expect(dressing.ingredients.map(\.foodItemId) == [oil.id])
        #expect(store.macroTotals(for: dressing).fat == 30)

        let food = try #require(store.prepareRecipeFood(for: dressing))
        #expect(food.isRecipeFood && food.macros.fat == 30)
        let salad = store.addRecipe(name: "Salad", servings: 1,
                                    ingredients: [ManualRecipeIngredientInput(name: dressing.name, selectedFoodItemId: dressing.id,
                                                                              quantity: 2, unit: "serving")])
        #expect(store.macroTotals(for: salad).fat == 30)
        #expect(store.logRecipe(salad) != nil)
        // The built-in row stays in the catalog, never among the person's foods.
        #expect(!store.foodItems.contains { $0.id == oil.id })
    }

    @Test func anUpgradedMultipartRecipeWithABuiltInFoodKeepsItsTotals() throws {
        let oil = Self.builtIn("Oil, olive, salad or cooking", protein: 0, carbs: 0, fat: 100)
        let store = makeTestStore(bundledFoodItems: [oil])
        let salad = store.addRecipe(name: "Garden salad", servings: 2, parts: Self.dressingParts(oil: oil))
        let before = store.macroTotals(for: salad)
        #expect(before.fat == 30)

        store.migrateRecipePartsAndSync()
        let parent = try #require(store.recipes.first { $0.id == salad.id })
        #expect(parent.components == nil)
        #expect(store.recipes.count == 2)
        #expect(store.macroTotals(for: parent) == before)
        #expect(store.logRecipe(parent) != nil)
        #expect(!store.foodItems.contains { $0.id == oil.id })
    }

    @Test func aRecipeSavedInTheBrokenStateHealsOnTheNextSync() throws {
        let oil = Self.builtIn("Oil, olive, salad or cooking", protein: 0, carbs: 0, fat: 100)
        let lemon = Self.builtIn("Lemon juice, raw", protein: 0, carbs: 7, fat: 0)
        let oilLine = RecipeIngredient(foodItemId: oil.id, quantity: 30, unit: "g")
        let lemonLine = RecipeIngredient(foodItemId: lemon.id, quantity: 20, unit: "g")
        let whisk = RecipeStep(text: "Whisk"), toss = RecipeStep(text: "Toss")
        let multipart = RecipeDefinition(
            name: "Garden salad", servings: 2, ingredients: [oilLine, lemonLine], source: "manual",
            createdAt: Self.now, updatedAt: Self.now, steps: [whisk, toss],
            components: [RecipeComponent(name: "Lemon dressing", ingredientIDs: [oilLine.id], stepIDs: [whisk.id]),
                         RecipeComponent(name: "Salad", ingredientIDs: [lemonLine.id], stepIDs: [toss.id])])
        // What a build with the defect persisted: the parts split, and no recipe food for the dressing.
        let split = RecipePartsMigration.migrated([multipart]).recipes
        let store = makeTestStore(bundledFoodItems: [oil, lemon])
        for recipe in split.reversed() { store.diary.insertRecipe(recipe) }
        let parent = try #require(store.recipes.first { $0.id == multipart.id })
        #expect(!store.foodItems.contains { $0.isRecipeFood })

        store.syncRecipeFoods()
        #expect(store.foodItems.contains { $0.isRecipeFood })
        #expect(store.macroTotals(for: parent).fat == 30)
        #expect(store.logRecipe(parent) != nil)
    }

    @Test func aRecipeThatStillCannotStandInSaysWhy() {
        let oil = Self.builtIn("Oil, olive, salad or cooking", protein: 0, carbs: 0, fat: 100)
        let empty = RecipeDefinition(name: "Empty", servings: 1, ingredients: [], source: "manual",
                                     createdAt: Self.now, updatedAt: Self.now)
        #expect(RecipeFood.gap(in: empty, foodItems: []) == .noIngredients)
        let missing = RecipeDefinition(name: "Ghost", servings: 1,
                                       ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "g")],
                                       source: "manual", createdAt: Self.now, updatedAt: Self.now)
        #expect(RecipeFood.gap(in: missing, foodItems: [oil]) == .unresolvedLine(foodName: nil))
        let fine = RecipeDefinition(name: "Oil", servings: 1,
                                    ingredients: [RecipeIngredient(foodItemId: oil.id, quantity: 10, unit: "g")],
                                    source: "manual", createdAt: Self.now, updatedAt: Self.now)
        #expect(RecipeFood.gap(in: fine, foodItems: [oil]) == nil)
        let store = makeTestStore(bundledFoodItems: [oil])
        #expect(store.recipeFoodGap(for: fine) == nil)
        #expect(store.recipeFoodGap(for: missing) == .unresolvedLine(foodName: nil))
    }
}
