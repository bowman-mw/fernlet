import Foundation
import FernletDomainModel
import AIProviders

/// Pure meal-construction helpers shared by every resolution tier: turning selection plans, recipes,
/// and resolved ingredient pairs into fully snapshotted `Meal`s, and minting reusable recipes from
/// multi-ingredient logs.
///
/// All inputs are passed in (recipes, catalog items, candidates) — nothing here reads or mutates the
/// store; `@MainActor` because callers hand it main-actor store snapshots mid-resolve. Key
/// invariants: a recipe meal divides by the recipe yield so one log is one plated serving, and a
/// minted recipe's stored quantities are the per-serving portion × yield so re-logging it reproduces
/// exactly one plate (decision §11.5). Macros and micronutrients always come from catalog-bound
/// `FoodItem`s, never from model output. Used by ``MealResolutionService``,
/// ``MealDecompositionResolver``, and ``DishTemplateLexicon``.
@MainActor
struct MealBuilder {
    /// The outcome of building meals from a selection plan.
    ///
    /// Carries the meals plus any recipes auto-minted for multi-ingredient items, so the caller can
    /// persist both together.
    struct PlanResult {
        let meals: [Meal]
        let createdRecipes: [RecipeDefinition]
    }

    /// Builds meals from a candidate-constrained selection plan: each plan item logs via the best
    /// matching saved recipe when one exists, otherwise from its resolved (and relevance-filtered)
    /// ingredients — minting a new recipe when several ingredients back one item.
    /// - Returns: The meals plus any created recipes, or `nil` when no item resolves.
    static func meals(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        recipes: [RecipeDefinition],
        foodItems: [FoodItem]
    ) -> PlanResult? {
        var availableRecipes = recipes
        var createdRecipes: [RecipeDefinition] = []
        var meals: [Meal] = []
        for item in plan.items {
            guard let result = resolvedMeal(
                for: item, availableRecipes: availableRecipes, candidates: candidates, foodItems: foodItems,
                mealType: plan.mealType
            ) else { return nil }
            meals.append(result.meal)
            if let recipe = result.createdRecipe {
                createdRecipes.append(recipe)
                availableRecipes.insert(recipe, at: 0)
            }
        }
        return meals.isEmpty ? nil : PlanResult(meals: meals, createdRecipes: createdRecipes)
    }

    private static func resolvedMeal(
        for item: FoodSelectionMealItem, availableRecipes: [RecipeDefinition], candidates: [FoodSelectionCandidate],
        foodItems: [FoodItem], mealType: MealType
    ) -> (meal: Meal, createdRecipe: RecipeDefinition?)? {
        if let recipe = bestRecipeMatch(for: item.name, in: availableRecipes),
           let meal = mealFromRecipe(recipe, mealType: mealType, foodItems: foodItems) {
            return (meal, nil)
        }
        let relevant = item.ingredients.filter { ingredient in
            guard let food = candidates.first(where: { $0.id == ingredient.candidateId })?.foodItem else { return false }
            return isRelevant(foodItem: food, to: item.name)
        }
        let source = relevant.isEmpty
            ? FoundationFoodSelectionModel.deterministicPlan(
                description: item.name, candidates: candidates, fallbackType: mealType
            )?.ingredients ?? [] : relevant
        let resolved = source.compactMap { ingredient -> (FoodSelectionIngredient, FoodItem)? in
            guard let food = candidates.first(where: { $0.id == ingredient.candidateId })?.foodItem else { return nil }
            return (ingredient, food)
        }
        guard resolved.isEmpty == false else { return nil }
        guard resolved.count > 1 else {
            return mealFromIngredients(itemName: item.name, resolvedIngredients: resolved, mealType: mealType)
                .map { ($0, nil) }
        }
        let recipe = createRecipe(
            for: item.name, resolvedIngredients: resolved, servings: defaultRecipeServings(description: item.name)
        )
        return mealFromRecipe(recipe, mealType: mealType, foodItems: foodItems).map { ($0, recipe) }
    }

    /// One logged serving of `recipe`: component snapshots scaled to 1/servings, with macro and
    /// micronutrient totals summed from them and the log source derived truthfully from the recipe's
    /// provenance.
    static func mealFromRecipe(
        _ recipe: RecipeDefinition,
        mealType: MealType,
        foodItems: [FoodItem]
    ) -> Meal? {
        let divisor = max(recipe.servings, 1)
        guard let components = componentSnapshots(for: recipe, foodItems: foodItems, divisor: divisor),
              components.isEmpty == false else { return nil }
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
            quality: perServing.protein >= Macros.goodProteinThreshold ? .good : .ok,
            confidence: MealConfidence.recipe.token,
            note: "Logged from saved recipe.",
            source: mealLogSource(for: recipe, foodItems: foodItems)
        )
    }

    /// A meal assembled directly from resolved (ingredient, food item) pairs, with component
    /// snapshots, summed totals, and a note naming the first few components; `confidenceLabel` names
    /// the tier that produced it.
    static func mealFromIngredients(
        itemName: String,
        resolvedIngredients: [(FoodSelectionIngredient, FoodItem)],
        mealType: MealType,
        confidenceToken: String = MealConfidence.foodMatch.token,
        source: String = MealLogSource.foundationModelFoodSelection
    ) -> Meal? {
        guard let components = componentSnapshots(for: resolvedIngredients), components.isEmpty == false else { return nil }
        let totals = totals(for: components)
        let ingredientText = components
            .prefix(3)
            .map { "\($0.quantity.formatted(.number.precision(.fractionLength(0...1)))) \($0.unit) \($0.name)" }
            .joined(separator: ", ")

        return Meal(
            // R5: the non-empty precondition is stated here rather than trusted — an empty pair list
            // falls back to the same generic name `createRecipe` uses instead of trapping on [0].
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (resolvedIngredients.first?.1.name ?? "Meal item")
                : itemName.capitalized,
            mealType: mealType,
            macros: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            macroSnapshot: Macros(protein: totals.macros.protein, carbs: totals.macros.carbs, fat: totals.macros.fat),
            micronutrientSnapshot: totals.micronutrients,
            componentSnapshots: components,
            mealSource: .manual,
            isAIFallback: false,
            quality: totals.macros.protein >= Macros.goodProteinThreshold ? .good : .ok,
            confidence: confidenceToken,
            note: "Matched locally from food selection: \(ingredientText).",
            source: source
        )
    }

    /// The truthful provenance tag for a recipe log: web import, USDA-backed recipe, label-scan, or
    /// plain manual — decided from the recipe's source and its ingredients' data quality.
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

    /// Builds a reusable recipe from catalog-bound ingredients that describe ONE plated serving (the
    /// as-eaten portion the resolver produced). The recipe yields `servings` of that plate, so its
    /// stored ingredient quantities are the per-serving portion scaled up by the yield: logging it back
    /// through `mealFromRecipe` (which divides by `servings`) reproduces exactly one plate. Keeping
    /// per-serving == the resolved portion is what lets the auto-mint's yield change from a hardcoded 1
    /// to the F1(c) default chain WITHOUT altering any logged meal's macros (decision §11.5).
    ///
    /// Internal (was `private`) so the dish-decomposition resolver can build a review-offered recipe
    /// from the same deduped ingredient pairs it already computes (F1(a) wire, §2.2a).
    static func createRecipe(
        for itemName: String,
        resolvedIngredients: [(FoodSelectionIngredient, FoodItem)],
        servings: Int = 4
    ) -> RecipeDefinition {
        let now = Date()
        let yield = max(servings, 1)
        let recipeIngredients = resolvedIngredients.map { resolvedIngredient in
            RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                // Per-serving plate portion × yield = the full batch the recipe makes.
                quantity: resolvedIngredient.0.quantity * Double(yield),
                unit: resolvedIngredient.0.unit
            )
        }
        return RecipeDefinition(
            name: itemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Meal item" : itemName.capitalized,
            servings: yield,
            ingredients: recipeIngredients,
            notes: "Created from meal logging.",
            source: "meal-log",
            createdAt: now,
            updatedAt: now
        )
    }

    /// The default yield for a recipe minted from a meal log (decision §11.5): the model's explicit
    /// hint when present, else the matching dish template's natural unit count, else 4. A plate is one
    /// serving of a recipe that usually makes several, so 4 is a saner reusable-recipe default than the
    /// old hardcoded 1. Always ≥ 1.
    static func defaultRecipeServings(description: String, hint: Int? = nil) -> Int {
        if let hint, hint >= 1 { return hint }
        if let template = DishTemplateLexicon.matchWithCount(description).0 {
            return max(1, Int(template.defaultCount.rounded()))
        }
        return 4
    }

    /// Sums component snapshots into macro and micronutrient totals.
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

    /// Freezes resolved (ingredient, food item) pairs from one shared source-backed conversion.
    static func componentSnapshots(
        for resolvedIngredients: [(FoodSelectionIngredient, FoodItem)]
    ) -> [MealComponentSnapshot]? {
        var snapshots: [MealComponentSnapshot] = []
        for resolvedIngredient in resolvedIngredients {
            let ingredient = RecipeIngredient(
                foodItemId: resolvedIngredient.1.id,
                quantity: resolvedIngredient.0.quantity,
                unit: resolvedIngredient.0.unit
            )
            guard let conversion = ingredient.servingConversion(using: resolvedIngredient.1) else { return nil }
            snapshots.append(MealComponentSnapshot(
                foodItemId: resolvedIngredient.1.id,
                name: resolvedIngredient.1.name,
                quantity: conversion.componentQuantity,
                unit: conversion.componentUnit,
                macros: conversion.scaledMacros(for: resolvedIngredient.1),
                micronutrients: conversion.scaledMicronutrients(for: resolvedIngredient.1),
                bindScore: resolvedIngredient.0.bindScore
            ))
        }
        return snapshots
    }

    /// Component snapshots for one serving of a recipe: each ingredient resolved against `foodItems`
    /// and scaled down by `divisor` (the recipe yield). Any unresolvable ingredient rejects the meal.
    private static func componentSnapshots(
        for recipe: RecipeDefinition,
        foodItems: [FoodItem],
        divisor: Int
    ) -> [MealComponentSnapshot]? {
        var snapshots: [MealComponentSnapshot] = []
        for ingredient in recipe.ingredients {
            guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }),
                  let conversion = ingredient.servingConversion(using: foodItem) else { return nil }
            let scale = 1 / Double(max(divisor, 1))
            snapshots.append(MealComponentSnapshot(
                foodItemId: foodItem.id,
                name: foodItem.name,
                quantity: conversion.componentQuantity * scale,
                unit: conversion.componentUnit,
                macros: conversion.scaledMacros(for: foodItem).scaled(by: scale),
                micronutrients: conversion.scaledMicronutrients(for: foodItem).scaled(by: scale)
            ))
        }
        return snapshots
    }

    /// Whole-recipe macro totals from the same component conversions used for a logged recipe.
    static func macroTotals(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> MacroTotals {
        guard let components = componentSnapshots(for: recipe, foodItems: foodItems, divisor: 1) else {
            return MacroTotals()
        }
        return totals(for: components).macros
    }

    /// Whole-recipe micronutrient totals from the same component conversions as `macroTotals`.
    static func micronutrientTotals(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> Micronutrients {
        guard let components = componentSnapshots(for: recipe, foodItems: foodItems, divisor: 1) else {
            return Micronutrients()
        }
        return totals(for: components).micronutrients
    }

    /// The saved recipe that best matches a plan item's name, by exact normalized match (1000),
    /// token-subset match (700), or near-total token overlap — most recently updated wins ties.
    /// Returns `nil` for names too short or too dissimilar to bind safely.
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

    /// Tokens worth matching on: length ≥ 3 and non-numeric, so "2" and "of" never drive a bind.
    private static func meaningfulRecipeTokens(in normalizedText: String) -> Set<String> {
        Set(normalizedText.split(separator: " ").map(String.init).filter {
            $0.count >= 3 && Double($0) == nil
        })
    }

    /// Whether a candidate food plausibly belongs to the named item — token overlap against the
    /// item's name/category/tags, plus a couple of sandwich-shaped special cases.
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
