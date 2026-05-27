import Foundation
import Testing
@testable import Fernlet

@MainActor
struct MealBuilderTests {
    @Test func planWithNoCandidatesReturnsNil() {
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: []
        )

        let result = MealBuilder.meals(
            from: plan,
            candidates: [],
            recipes: [],
            foodItems: [],
            originalDescription: "turkey sandwich"
        )

        #expect(result == nil)
    }

    @Test func planMatchingExistingRecipeReturnsRecipeMeal() throws {
        let turkey = foodItem(name: "Turkey", source: .manual, macros: Macros(protein: 24, carbs: 0, fat: 2))
        let bread = foodItem(name: "Bread", source: .manual, macros: Macros(protein: 4, carbs: 22, fat: 1))
        let recipe = recipe(
            name: "Turkey Sandwich",
            ingredients: [
                RecipeIngredient(foodItemId: turkey.id, quantity: 1, unit: RecipeUnit.serving.rawValue),
                RecipeIngredient(foodItemId: bread.id, quantity: 1, unit: RecipeUnit.serving.rawValue)
            ]
        )
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: [FoodSelectionMealItem(name: "turkey sandwich", ingredients: [])]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: [],
            recipes: [recipe],
            foodItems: [turkey, bread],
            originalDescription: "turkey sandwich"
        ))

        #expect(result.createdRecipes.isEmpty)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.name == "Turkey Sandwich")
        #expect(meal.mealSource == .recipe)
        #expect(meal.source == MealLogSource.manual)
    }

    @Test func multipleResolvedIngredientsCreateRecipeAndRecipeMeal() throws {
        let oats = foodItem(name: "Oats", source: .manual, macros: Macros(protein: 5, carbs: 27, fat: 3))
        let yogurt = foodItem(name: "Greek yogurt", source: .manual, macros: Macros(protein: 18, carbs: 6, fat: 0))
        let candidates = [
            FoodSelectionCandidate(id: 1, foodItem: oats),
            FoodSelectionCandidate(id: 2, foodItem: yogurt)
        ]
        let plan = FoodSelectionPlan(
            mealName: "Breakfast",
            mealType: .breakfast,
            items: [
                FoodSelectionMealItem(
                    name: "oats yogurt",
                    ingredients: [
                        ingredient(candidateId: 1, foodName: "Oats", quantity: 1, unit: RecipeUnit.serving.rawValue),
                        ingredient(candidateId: 2, foodName: "Greek yogurt", quantity: 1, unit: RecipeUnit.serving.rawValue)
                    ]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [oats, yogurt],
            originalDescription: "protein oats"
        ))

        #expect(result.createdRecipes.count == 1)
        let createdRecipe = try #require(result.createdRecipes.first)
        #expect(createdRecipe.name == "Oats Yogurt")
        #expect(createdRecipe.source == "meal-log")
        #expect(createdRecipe.ingredients.count == 2)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .recipe)
        #expect(meal.macros == Macros(protein: 23, carbs: 33, fat: 3))
    }

    @Test func singleResolvedIngredientProducesManualMealWithoutRecipe() throws {
        let banana = foodItem(name: "Banana", source: .manual, macros: Macros(protein: 1, carbs: 27, fat: 0))
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: banana)]
        let plan = FoodSelectionPlan(
            mealName: "Snack",
            mealType: .snack,
            items: [
                FoodSelectionMealItem(
                    name: "banana",
                    ingredients: [ingredient(candidateId: 1, foodName: "Banana")]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [banana],
            originalDescription: "banana"
        ))

        #expect(result.createdRecipes.isEmpty)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .manual)
        #expect(meal.source == MealLogSource.foundationModelFoodSelection)
        #expect(meal.name == "Banana")
    }

    @Test func sandwichAcceptsBreadOrCheeseIngredientsAsRelevant() throws {
        let bread = foodItem(name: "Sourdough bread", source: .manual, macros: Macros(protein: 4, carbs: 22, fat: 1), category: "bread")
        let cheese = foodItem(name: "Cheddar cheese", source: .manual, macros: Macros(protein: 7, carbs: 1, fat: 9), category: "cheese")
        let candidates = [
            FoodSelectionCandidate(id: 1, foodItem: bread),
            FoodSelectionCandidate(id: 2, foodItem: cheese)
        ]
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: [
                FoodSelectionMealItem(
                    name: "sandwich",
                    ingredients: [
                        ingredient(candidateId: 1, foodName: "Sourdough bread"),
                        ingredient(candidateId: 2, foodName: "Cheddar cheese")
                    ]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [bread, cheese],
            originalDescription: "sandwich"
        ))

        #expect(result.createdRecipes.count == 1)
        let createdRecipe = try #require(result.createdRecipes.first)
        #expect(createdRecipe.ingredients.count == 2)
        #expect(Set(createdRecipe.ingredients.map(\.foodItemId)) == Set([bread.id, cheese.id]))
    }

    @Test func grilledCheeseAcceptsBreadOrSourdoughIngredientsAsRelevant() throws {
        let sourdough = foodItem(name: "Sourdough", source: .manual, macros: Macros(protein: 4, carbs: 22, fat: 1), category: "bread")
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: sourdough)]
        let plan = FoodSelectionPlan(
            mealName: "Lunch",
            mealType: .lunch,
            items: [
                FoodSelectionMealItem(
                    name: "grilled cheese",
                    ingredients: [ingredient(candidateId: 1, foodName: "Sourdough")]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [sourdough],
            originalDescription: "grilled cheese"
        ))

        #expect(result.createdRecipes.isEmpty)
        #expect(result.meals.count == 1)
        let meal = try #require(result.meals.first)
        #expect(meal.mealSource == .manual)
    }

    @Test func mealFromRecipeClassifiesLogSource() {
        let usda = foodItem(name: "USDA chicken", source: .usda, macros: Macros(protein: 26, carbs: 0, fat: 3))
        let scanned = foodItem(
            name: "Scanned bar",
            source: .manual,
            macros: Macros(protein: 12, carbs: 22, fat: 6),
            micronutrients: Micronutrients(fiber: 4, sugar: 8, saturatedFat: 2, potassium: 80, sodium: 120)
        )
        let manual = foodItem(name: "Manual rice", source: .manual, macros: Macros(protein: 4, carbs: 45, fat: 1))

        let usdaMeal = MealBuilder.mealFromRecipe(
            recipe(name: "Chicken", ingredients: [RecipeIngredient(foodItemId: usda.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]),
            mealType: .lunch,
            foodItems: [usda]
        )
        let scannedMeal = MealBuilder.mealFromRecipe(
            recipe(name: "Scanned Bar", ingredients: [RecipeIngredient(foodItemId: scanned.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]),
            mealType: .snack,
            foodItems: [scanned]
        )
        let webImportMeal = MealBuilder.mealFromRecipe(
            recipe(name: "Web Bowl", ingredients: [RecipeIngredient(foodItemId: manual.id, quantity: 1, unit: RecipeUnit.serving.rawValue)], source: MealLogSource.webImport),
            mealType: .dinner,
            foodItems: [manual]
        )
        let manualMeal = MealBuilder.mealFromRecipe(
            recipe(name: "Manual Bowl", ingredients: [RecipeIngredient(foodItemId: manual.id, quantity: 1, unit: RecipeUnit.serving.rawValue)]),
            mealType: .dinner,
            foodItems: [manual]
        )

        #expect(usdaMeal.source == MealLogSource.usdaRecipe)
        #expect(scannedMeal.source == MealLogSource.labelScan)
        #expect(webImportMeal.source == MealLogSource.webImport)
        #expect(manualMeal.source == MealLogSource.manual)
    }

    private func ingredient(
        candidateId: Int,
        foodName: String,
        quantity: Double = 1,
        unit: String = RecipeUnit.serving.rawValue
    ) -> FoodSelectionIngredient {
        FoodSelectionIngredient(candidateId: candidateId, foodName: foodName, quantity: quantity, unit: unit)
    }

    private func recipe(
        name: String,
        ingredients: [RecipeIngredient],
        source: String = "manual",
        updatedAt: Date = Date(timeIntervalSince1970: 1_779_664_800)
    ) -> RecipeDefinition {
        RecipeDefinition(
            name: name,
            servings: 1,
            ingredients: ingredients,
            source: source,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private func foodItem(
        name: String,
        source: FoodItemSource,
        macros: Macros,
        micronutrients: Micronutrients = Micronutrients(),
        category: String = "test",
        tags: [String] = []
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 1,
            servingUnit: RecipeUnit.serving.rawValue,
            macros: macros,
            micronutrients: micronutrients,
            category: category,
            source: source,
            tags: tags
        )
    }
}
