import Foundation

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
        let totals = macroTotals(for: recipe, foodItems: foodItems)
        let micronutrients = micronutrientTotals(for: recipe, foodItems: foodItems)
        let divisor = max(recipe.servings, 1)
        let perServing = Macros(
            protein: Int((Double(totals.protein) / Double(divisor)).rounded()),
            carbs: Int((Double(totals.carbs) / Double(divisor)).rounded()),
            fat: Int((Double(totals.fat) / Double(divisor)).rounded())
        )
        return Meal(
            name: recipe.name,
            mealType: mealType,
            macros: perServing,
            macroSnapshot: perServing,
            micronutrientSnapshot: micronutrients.scaled(by: 1 / Double(divisor)),
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
        mealType: MealType
    ) -> Meal {
        let totals = totals(for: resolvedIngredients)
        let ingredientText = resolvedIngredients
            .prefix(3)
            .map { "\($0.0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.0.unit) \($0.1.name)" }
            .joined(separator: ", ")

        return Meal(
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? resolvedIngredients[0].1.name : itemName.capitalized,
            mealType: mealType,
            macros: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            macroSnapshot: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            micronutrientSnapshot: totals.micronutrients,
            mealSource: .manual,
            isAIFallback: false,
            quality: totals.macros.protein >= goodProteinThreshold ? .good : .ok,
            confidence: "Food match",
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

    private static func totals(
        for resolvedIngredients: [(FoodSelectionIngredient, FoodItem)]
    ) -> (macros: MacroTotals, micronutrients: Micronutrients) {
        resolvedIngredients.reduce(into: (macros: MacroTotals(), micronutrients: Micronutrients())) { totals, resolvedIngredient in
            let ingredient = RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit
            )
            let scaled = ingredient.scaledMacros(using: resolvedIngredient.1)
            totals.macros.protein += scaled.protein
            totals.macros.carbs += scaled.carbs
            totals.macros.fat += scaled.fat
            totals.micronutrients.add(ingredient.scaledMicronutrients(using: resolvedIngredient.1))
        }
    }

    private static func macroTotals(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> MacroTotals {
        recipe.ingredients.reduce(into: MacroTotals()) { totals, ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return }
            let macros = ingredient.scaledMacros(using: foodItem)
            totals.protein += macros.protein
            totals.carbs += macros.carbs
            totals.fat += macros.fat
        }
    }

    private static func micronutrientTotals(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> Micronutrients {
        recipe.ingredients.reduce(into: Micronutrients()) { totals, ingredient in
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return }
            totals.add(ingredient.scaledMicronutrients(using: foodItem))
        }
    }

    private static func bestRecipeMatch(for itemName: String, in recipes: [RecipeDefinition]) -> RecipeDefinition? {
        let normalizedItem = FoodItemSearch.normalized(itemName)
        guard normalizedItem.count >= 3 else { return nil }
        let itemTokens = Set(normalizedItem.split(separator: " ").map(String.init))
        return recipes
            .map { recipe -> (recipe: RecipeDefinition, score: Int)? in
                let normalizedRecipe = FoodItemSearch.normalized(recipe.name)
                let recipeTokens = Set(normalizedRecipe.split(separator: " ").map(String.init))
                if normalizedRecipe == normalizedItem { return (recipe, 1_000) }
                if normalizedRecipe.contains(normalizedItem) || normalizedItem.contains(normalizedRecipe) { return (recipe, 700) }
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
