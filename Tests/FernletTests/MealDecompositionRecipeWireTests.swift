import Foundation
import Testing
import FernletDomainModel
import AIContext
import FoodCatalog
@testable import Fernlet

#if canImport(FoundationModels)
import FoundationModels
#endif

/// F1(a) — the dish-decomposition → recipe wire (AI-Feature-Expansion §2.2a/§2.5, decision §11.5).
/// Covers: the default-yield chain, `createRecipe`'s per-serving-preserving yield scaling, the auto-mint
/// yield change (with the logged meal's macros held invariant), the resolution transforms carrying the
/// suggested recipe out of the cascade, the review-gated mint (a suggested recipe is NEVER minted by
/// `commitResolution` — only a user-confirmed one, routed through `createdRecipes`), and — behind the
/// FoundationModels gate — the resolver actually building the recipe from its deduped ingredient pairs.
@MainActor
struct MealDecompositionRecipeWireTests {

    // MARK: - Fixtures

    private func foodItem(
        name: String,
        source: FoodItemSource = .usda,
        macros: Macros,
        micronutrients: Micronutrients = Micronutrients(),
        category: String = "test",
        tags: [String] = []
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: macros,
            micronutrients: micronutrients,
            category: category,
            source: source,
            tags: tags
        )
    }

    private func ingredient(candidateId: Int, foodName: String, quantity: Double = 1) -> FoodSelectionIngredient {
        FoodSelectionIngredient(candidateId: candidateId, foodName: foodName, quantity: quantity, unit: RecipeUnit.serving.rawValue)
    }

    // MARK: - Default-yield chain (decision §11.5)

    @Test func defaultRecipeServingsFollowsHintThenTemplateThenFour() {
        // 1) An explicit hint wins outright.
        #expect(MealBuilder.defaultRecipeServings(description: "anything at all", hint: 6) == 6)
        #expect(MealBuilder.defaultRecipeServings(description: "pizza", hint: 3) == 3)
        // A non-positive hint is ignored (falls through the chain).
        #expect(MealBuilder.defaultRecipeServings(description: "grilled chicken and broccoli", hint: 0) == 4)

        // 2) A matching dish template contributes its natural unit count.
        #expect(MealBuilder.defaultRecipeServings(description: "pizza") == 2)        // template defaultCount 2
        #expect(MealBuilder.defaultRecipeServings(description: "sushi roll") == 8)   // template defaultCount 8
        #expect(MealBuilder.defaultRecipeServings(description: "burger") == 1)       // template defaultCount 1

        // 3) No template → 4.
        #expect(MealBuilder.defaultRecipeServings(description: "grilled chicken and broccoli") == 4)
    }

    // MARK: - createRecipe yield scaling (per-serving == the resolved plate)

    @Test func createRecipeScalesIngredientsByYieldSoPerServingIsThePlate() throws {
        let oats = foodItem(name: "Oats", macros: Macros(protein: 5, carbs: 27, fat: 3))
        let yogurt = foodItem(name: "Greek yogurt", macros: Macros(protein: 18, carbs: 6, fat: 0))
        // One plated serving: 1 serving of each.
        let plate: [(FoodSelectionIngredient, FoodItem)] = [
            (ingredient(candidateId: 1, foodName: "Oats"), oats),
            (ingredient(candidateId: 2, foodName: "Greek yogurt"), yogurt)
        ]

        let recipe = MealBuilder.createRecipe(for: "Oats & yogurt", resolvedIngredients: plate, servings: 4)
        #expect(recipe.servings == 4)
        // Stored quantities are the plate portion × yield (the full batch).
        #expect(recipe.ingredients.map(\.quantity) == [4, 4])

        // Logging it back divides by servings → exactly one plate. per-serving is invariant to the yield.
        let logged = try #require(MealBuilder.mealFromRecipe(
            recipe, mealType: .breakfast, foodItems: [oats, yogurt]
        ))
        #expect(logged.macros == Macros(protein: 23, carbs: 33, fat: 3))
    }

    // MARK: - Auto-mint yield change WITHOUT regressing the logged meal (§10 guard)

    @Test func autoMintUsesDefaultYieldButLeavesLoggedMealMacrosUnchanged() throws {
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
                    name: "oats yogurt",   // no dish template → default yield 4
                    ingredients: [
                        ingredient(candidateId: 1, foodName: "Oats"),
                        ingredient(candidateId: 2, foodName: "Greek yogurt")
                    ]
                )
            ]
        )

        let result = try #require(MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: [],
            foodItems: [oats, yogurt]
        ))

        let createdRecipe = try #require(result.createdRecipes.first)
        // Yield now comes from the default chain (4), not the old hardcoded 1 — with ingredients scaled up.
        #expect(createdRecipe.servings == 4)
        #expect(createdRecipe.ingredients.map(\.quantity) == [4, 4])
        // The logged meal is still exactly one plate — the servings change must not alter it.
        let meal = try #require(result.meals.first)
        #expect(meal.macros == Macros(protein: 23, carbs: 33, fat: 3))
    }

    // MARK: - The suggested recipe is carried OUT of the resolution transforms

    @Test func plausibilityGateAndMergePreserveSuggestedRecipe() {
        let suggested = RecipeDefinition(
            name: "Carried Recipe",
            servings: 4,
            ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 100, unit: RecipeUnit.gram.rawValue)],
            source: "meal-log",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
        func meal(_ p: Int, _ c: Int, _ f: Int) -> Meal {
            Meal(name: "Dish", mealType: .lunch, macros: Macros(protein: p, carbs: c, fat: f),
                 quality: .ok, confidence: "Food match", note: "", source: MealLogSource.manual)
        }

        // The gate downgrades an implausible resolution but must not drop the recipe it carried.
        let implausible = MealResolution(
            meals: [meal(3_000, 3_000, 6_000)], createdRecipes: [], confidence: .high,
            isFallback: false, suggestedRecipe: suggested
        )
        let gated = MealResolutionService.plausibilityGated(implausible)
        #expect(gated.confidence == .low)
        #expect(gated.suggestedRecipe?.id == suggested.id)

        // A plausible single-meal resolution passes the gate AND the merge untouched, recipe intact.
        let plausible = MealResolution(
            meals: [meal(20, 10, 5)], createdRecipes: [], confidence: .high,
            isFallback: false, suggestedRecipe: suggested
        )
        #expect(MealResolutionService.plausibilityGated(plausible).suggestedRecipe?.id == suggested.id)
        #expect(MealResolutionService.mergedIntoSingleMeal(plausible, description: "dish").suggestedRecipe?.id == suggested.id)
    }

    // MARK: - Review-gated mint: commit never persists a SUGGESTED recipe (only a confirmed one)

    @Test func commitResolutionNeverMintsTheSuggestedRecipe() {
        let store = makeTestStore()
        let suggested = RecipeDefinition(
            name: "Should Not Persist",
            servings: 4,
            ingredients: [],
            source: "meal-log",
            createdAt: Date(),
            updatedAt: Date()
        )
        let meal = Meal(name: "Bowl", mealType: .lunch, macros: Macros(protein: 20, carbs: 20, fat: 5),
                        quality: .ok, confidence: "Food match", note: "", source: MealLogSource.manual)

        // A resolution that carries a suggested recipe but was NOT confirmed (createdRecipes empty):
        // committing it logs the meal but must NOT touch the recipe book.
        store.commitResolution(MealResolution(
            meals: [meal], createdRecipes: [], confidence: .high, isFallback: false, suggestedRecipe: suggested
        ))
        #expect(store.recipes.contains { $0.id == suggested.id } == false)
        #expect(store.day.meals.contains { $0.id == meal.id })

        // The user-confirmed path routes the recipe through createdRecipes (what the review sheet does) —
        // that IS persisted, proving the mint happens only on confirm.
        let confirmed = RecipeDefinition(
            name: "Confirmed", servings: 2, ingredients: [], source: "meal-log", createdAt: Date(), updatedAt: Date()
        )
        store.commitResolution(MealResolution(
            meals: [], createdRecipes: [confirmed], confidence: .high, isFallback: false, suggestedRecipe: suggested
        ))
        #expect(store.recipes.contains { $0.id == confirmed.id })
        #expect(store.recipes.contains { $0.id == suggested.id } == false)
    }

    // MARK: - The resolver builds the recipe from its deduped ingredient pairs (FoundationModels-gated)

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Test func decompositionResolverCarriesAMultiIngredientRecipeOut() throws {
        let chicken = foodItem(name: "Chicken breast, roasted", macros: Macros(protein: 31, carbs: 0, fat: 4), tags: ["chicken"])
        let rice = foodItem(name: "Rice, white, cooked", macros: Macros(protein: 3, carbs: 28, fat: 0), tags: ["rice"])
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([chicken, rice]))

        let decomposition = FoundationDishDecomposition(
            name: "Chicken and rice",
            mealType: "Dinner",
            components: [
                FoundationDishComponent(ingredient: "chicken breast", preparation: "roasted", grams: 150, confidence: "high", explicitlyStated: true),
                FoundationDishComponent(ingredient: "white rice", preparation: "cooked", grams: 150, confidence: "high", explicitlyStated: true)
            ],
            overallConfidence: "high"
        )
        let payload = MealDecompositionPayload(mealDescription: "chicken and rice", fallbackMealType: .dinner)

        let resolved = try #require(MealDecompositionResolver.resolve(from: decomposition, payload: payload, catalog: catalog))
        // The meal binds both foods (as-eaten plate).
        #expect(resolved.meal.componentSnapshots.count == 2)
        // And the recipe was carried out — built from the SAME deduped pairs, at the default yield.
        let recipe = try #require(resolved.suggestedRecipe)
        #expect(recipe.ingredients.count == 2)
        #expect(recipe.name == "Chicken And Rice")   // createRecipe title-cases the dish name
        #expect(recipe.servings == MealBuilder.defaultRecipeServings(description: "chicken and rice"))
        // Macros stay catalog-bound (never model-emitted): logging one serving reproduces the plate.
        let logged = try #require(MealBuilder.mealFromRecipe(
            recipe, mealType: .dinner, foodItems: [chicken, rice]
        ))
        #expect(logged.macros == resolved.meal.macros)
    }

    @available(iOS 26.0, *)
    @Test func decompositionResolverBuildsNoRecipeForASingleIngredient() throws {
        let banana = foodItem(name: "Banana, raw", macros: Macros(protein: 1, carbs: 27, fat: 0), tags: ["banana"])
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([banana]))
        let decomposition = FoundationDishDecomposition(
            name: "Banana",
            mealType: "Snack",
            components: [FoundationDishComponent(ingredient: "banana", preparation: "none", grams: 118, confidence: "high", explicitlyStated: true)],
            overallConfidence: "high"
        )
        let payload = MealDecompositionPayload(mealDescription: "a banana", fallbackMealType: .snack)

        let resolved = try #require(MealDecompositionResolver.resolve(from: decomposition, payload: payload, catalog: catalog))
        // A single bound food is a meal, not a recipe.
        #expect(resolved.suggestedRecipe == nil)
    }
    #endif
}
