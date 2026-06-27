import Foundation
import FernletDomainModel

@MainActor
struct MealBuilder {
    static let goodProteinThreshold = 25

    struct PlanResult {
        let meals: [Meal]
        let createdRecipes: [RecipeDefinition]
    }

    static func meals(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        recipes: [RecipeDefinition],
        foodItems: [FoodItem],
        originalDescription: String
    ) -> PlanResult? {
        _ = originalDescription
        var availableRecipes = recipes
        var createdRecipes: [RecipeDefinition] = []
        let meals = plan.items.compactMap { item -> Meal? in
            if let recipe = bestRecipeMatch(for: item.name, in: availableRecipes) {
                return mealFromRecipe(recipe, mealType: plan.mealType, foodItems: foodItems)
            }

            let relevantIngredients = item.ingredients.filter { ingredient in
                guard let foodItem = candidates.first(where: { $0.id == ingredient.candidateId })?.foodItem else { return false }
                return isRelevant(foodItem: foodItem, to: item.name)
            }
            let sourceIngredients = relevantIngredients.isEmpty
                ? FoundationFoodSelectionModel.deterministicPlan(description: item.name, candidates: candidates, fallbackType: plan.mealType)?.ingredients ?? []
                : relevantIngredients
            let resolved = sourceIngredients.compactMap { ingredient -> (FoodSelectionIngredient, FoodItem)? in
                guard let foodItem = candidates.first(where: { $0.id == ingredient.candidateId })?.foodItem else { return nil }
                return (ingredient, foodItem)
            }
            guard resolved.isEmpty == false else { return nil }

            if resolved.count > 1 {
                let recipe = createRecipe(for: item.name, resolvedIngredients: resolved)
                createdRecipes.append(recipe)
                availableRecipes.insert(recipe, at: 0)
                return mealFromRecipe(recipe, mealType: plan.mealType, foodItems: foodItems)
            }

            return mealFromIngredients(itemName: item.name, resolvedIngredients: resolved, mealType: plan.mealType)
        }
        return meals.isEmpty ? nil : PlanResult(meals: meals, createdRecipes: createdRecipes)
    }

    static func mealFromRecipe(
        _ recipe: RecipeDefinition,
        mealType: MealType,
        foodItems: [FoodItem]
    ) -> Meal {
        let divisor = max(recipe.servings, 1)
        let components = componentSnapshots(for: recipe, foodItems: foodItems, divisor: divisor)
        let componentTotals = totals(for: components)
        let perServing = Macros(
            protein: componentTotals.macros.protein,
            carbs: componentTotals.macros.carbs,
            fat: componentTotals.macros.fat
        )
        return Meal(
            name: recipe.name,
            mealType: mealType,
            macros: perServing,
            macroSnapshot: perServing,
            micronutrientSnapshot: componentTotals.micronutrients,
            componentSnapshots: components,
            mealSource: .recipe,
            isAIFallback: false,
            quality: perServing.protein >= goodProteinThreshold ? .good : .ok,
            confidence: "Recipe",
            note: "Logged from saved recipe.",
            source: mealLogSource(for: recipe, foodItems: foodItems)
        )
    }

    static func mealFromIngredients(
        itemName: String,
        resolvedIngredients: [(FoodSelectionIngredient, FoodItem)],
        mealType: MealType,
        confidenceLabel: String = "Food match"
    ) -> Meal {
        let components = componentSnapshots(for: resolvedIngredients)
        let totals = totals(for: components)
        let ingredientText = components
            .prefix(3)
            .map { "\($0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit) \($0.name)" }
            .joined(separator: ", ")

        return Meal(
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? resolvedIngredients[0].1.name : itemName.capitalized,
            mealType: mealType,
            macros: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            macroSnapshot: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            micronutrientSnapshot: totals.micronutrients,
            componentSnapshots: components,
            mealSource: .manual,
            isAIFallback: false,
            quality: totals.macros.protein >= goodProteinThreshold ? .good : .ok,
            confidence: confidenceLabel,
            note: "Matched locally from food selection: \(ingredientText).",
            source: MealLogSource.foundationModelFoodSelection
        )
    }

    private static func mealLogSource(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> String {
        if recipe.source == MealLogSource.webImport || recipe.source == "imported" {
            return MealLogSource.webImport
        }

        let recipeFoodItems = recipe.ingredients.compactMap { ingredient in
            foodItems.first(where: { $0.id == ingredient.foodItemId })
        }
        if recipeFoodItems.contains(where: { $0.source == .usda }) {
            return MealLogSource.usdaRecipe
        }
        if recipeFoodItems.contains(where: { $0.micronutrients.populatedFieldCount >= 5 }) {
            return MealLogSource.labelScan
        }
        return MealLogSource.manual
    }

    private static func createRecipe(
        for itemName: String,
        resolvedIngredients: [(FoodSelectionIngredient, FoodItem)]
    ) -> RecipeDefinition {
        let now = Date()
        let recipeIngredients = resolvedIngredients.map { resolvedIngredient in
            RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit
            )
        }
        return RecipeDefinition(
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meal item" : itemName.capitalized,
            servings: 1,
            ingredients: recipeIngredients,
            notes: "Created from meal logging.",
            source: "meal-log",
            createdAt: now,
            updatedAt: now
        )
    }

    static func totals(
        for components: [MealComponentSnapshot]
    ) -> (macros: MacroTotals, micronutrients: Micronutrients) {
        components.reduce(into: (macros: MacroTotals(), micronutrients: Micronutrients())) { totals, component in
            totals.macros.protein += component.macros.protein
            totals.macros.carbs += component.macros.carbs
            totals.macros.fat += component.macros.fat
            totals.micronutrients.add(component.micronutrients)
        }
    }

    static func componentSnapshots(
        for resolvedIngredients: [(FoodSelectionIngredient, FoodItem)]
    ) -> [MealComponentSnapshot] {
        resolvedIngredients.map { resolvedIngredient in
            let ingredient = RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit
            )
            return MealComponentSnapshot(
                foodItemId: resolvedIngredient.1.id,
                name: resolvedIngredient.1.name,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit,
                macros: ingredient.scaledMacros(using: resolvedIngredient.1),
                micronutrients: ingredient.scaledMicronutrients(using: resolvedIngredient.1)
            )
        }
    }

    private static func componentSnapshots(
        for recipe: RecipeDefinition,
        foodItems: [FoodItem],
        divisor: Int
    ) -> [MealComponentSnapshot] {
        recipe.ingredients.compactMap { ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return nil }
            let scale = 1 / Double(max(divisor, 1))
            return MealComponentSnapshot(
                foodItemId: foodItem.id,
                name: foodItem.name,
                quantity: ingredient.quantity * scale,
                unit: ingredient.unit,
                macros: ingredient.scaledMacros(using: foodItem).scaled(by: scale),
                micronutrients: ingredient.scaledMicronutrients(using: foodItem).scaled(by: scale)
            )
        }
    }

    static func macroTotals(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> MacroTotals {
        recipe.ingredients.reduce(into: MacroTotals()) { totals, ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return }
            let macros = ingredient.scaledMacros(using: foodItem)
            totals.protein += macros.protein
            totals.carbs += macros.carbs
            totals.fat += macros.fat
        }
    }

    static func micronutrientTotals(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> Micronutrients {
        recipe.ingredients.reduce(into: Micronutrients()) { totals, ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return }
            totals.add(ingredient.scaledMicronutrients(using: foodItem))
        }
    }

    private static func bestRecipeMatch(for itemName: String, in recipes: [RecipeDefinition]) -> RecipeDefinition? {
        let normalizedItem = FoodItemSearch.normalized(itemName)
        guard normalizedItem.count >= 3 else { return nil }
        let itemTokens = meaningfulRecipeTokens(in: normalizedItem)
        return recipes
            .map { recipe -> (recipe: RecipeDefinition, score: Int)? in
                let normalizedRecipe = FoodItemSearch.normalized(recipe.name)
                if normalizedRecipe == normalizedItem { return (recipe, 1_000) }
                let recipeTokens = meaningfulRecipeTokens(in: normalizedRecipe)
                if !itemTokens.isEmpty, !recipeTokens.isEmpty,
                    itemTokens.isSubset(of: recipeTokens) || recipeTokens.isSubset(of: itemTokens) {
                    return (recipe, 700)
                }
                guard itemTokens.isEmpty == false, recipeTokens.isEmpty == false else { return nil }
                let overlap = itemTokens.intersection(recipeTokens).count
                guard overlap >= max(1, min(itemTokens.count, recipeTokens.count) - 1) else { return nil }
                return (recipe, overlap * 100)
            }
            .compactMap { $0 }
            .sorted { first, second in
                if first.score != second.score { return first.score > second.score }
                return first.recipe.updatedAt > second.recipe.updatedAt
            }
            .first?.recipe
    }

    private static func meaningfulRecipeTokens(in normalizedText: String) -> Set<String> {
        Set(normalizedText.split(separator: " ").map(String.init).filter {
            $0.count >= 3 && Double($0) == nil
        })
    }

    private static func isRelevant(foodItem: FoodItem, to itemName: String) -> Bool {
        let itemTokens = Set(FoodItemSearch.normalized(itemName).split(separator: " ").map(String.init).filter { $0.count >= 3 })
        let foodText = FoodItemSearch.normalized("\(foodItem.name) \(foodItem.category) \(foodItem.tags.joined(separator: " "))")
        let foodTokens = Set(foodText.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        guard itemTokens.isEmpty == false else { return true }
        if itemTokens.intersection(foodTokens).isEmpty == false { return true }
        if itemTokens.contains("sandwich") && (foodTokens.contains("bread") || foodTokens.contains("cheese")) { return true }
        if itemTokens.contains("grilled") && itemTokens.contains("cheese") && (foodTokens.contains("bread") || foodTokens.contains("sourdough")) { return true }
        return false
    }
}
