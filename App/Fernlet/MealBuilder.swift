import Foundation
import FernletDomainModel
import AIProviders

/// Pure meal-construction helpers shared by every resolution tier: turning selection plans, recipes,
/// and resolved ingredient pairs into fully snapshotted `Meal`s, and building the reusable recipe a
/// multi-ingredient log OFFERS for review (never mints).
///
/// All inputs are passed in (recipes, catalog items, candidates) — nothing here reads or mutates the
/// store; `@MainActor` because callers hand it main-actor store snapshots mid-resolve. Key
/// invariants: a recipe meal divides by the recipe yield so one log is one plated serving, and a
/// built recipe's stored quantities are the per-serving portion × yield so re-logging it reproduces
/// exactly one plate (decision §11.5). Macros and micronutrients always come from catalog-bound
/// `FoodItem`s, never from model output. Used by ``MealResolutionService``,
/// ``MealDecompositionResolver``, and ``DishTemplateLexicon``.
@MainActor
struct MealBuilder {
    /// The outcome of building meals from a selection plan.
    ///
    /// Carries the meals plus the recipes built for multi-ingredient items. Those are OFFERS for the
    /// pre-log review (`MealResolution.offeredRecipes`), never minted by resolution or an auto-commit,
    /// which is why no meal here claims to come from one.
    struct PlanResult {
        let meals: [Meal]
        let offeredRecipes: [RecipeDefinition]
    }

    /// Builds meals from a candidate-constrained selection plan: each plan item logs via the best
    /// matching SAVED recipe when one exists, otherwise from its resolved (and relevance-filtered)
    /// ingredients as the matched foods they are — and when several ingredients back one item, the
    /// recipe they make is offered alongside, for the review to save or not.
    ///
    /// An offered recipe never backs a later item of the same plan: it is not in the book, so a meal
    /// logged "from" it would claim a recipe the person never saved (until 2026-10-16 it did, and every
    /// such meal read "From your recipe"; bug confirmation 2026-10-15, food-ai §4).
    /// - Returns: The meals plus any offered recipes, or `nil` when no item resolves.
    static func meals(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        recipes: [RecipeDefinition],
        foodItems: [FoodItem]
    ) -> PlanResult? {
        var offeredRecipes: [RecipeDefinition] = []
        var meals: [Meal] = []
        for item in plan.items {
            guard let result = resolvedMeal(
                for: item, savedRecipes: recipes, candidates: candidates, foodItems: foodItems,
                mealType: plan.mealType
            ) else { return nil }
            meals.append(result.meal)
            if let recipe = result.offeredRecipe { offeredRecipes.append(recipe) }
        }
        return meals.isEmpty ? nil : PlanResult(meals: meals, offeredRecipes: offeredRecipes)
    }

    /// One plan item's meal: one serving of the best-matching saved recipe, else its resolved foods —
    /// plus, when several foods back it, the recipe they make, offered and not saved.
    private static func resolvedMeal(
        for item: FoodSelectionMealItem, savedRecipes: [RecipeDefinition], candidates: [FoodSelectionCandidate],
        foodItems: [FoodItem], mealType: MealType
    ) -> (meal: Meal, offeredRecipe: RecipeDefinition?)? {
        if let recipe = bestRecipeMatch(for: item.name, in: savedRecipes),
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
        guard resolved.isEmpty == false,
              let meal = mealFromIngredients(itemName: item.name, resolvedIngredients: resolved, mealType: mealType)
        else { return nil }
        guard resolved.count > 1 else { return (meal, nil) }
        let recipe = createRecipe(
            for: item.name, resolvedIngredients: resolved, servings: defaultRecipeServings(description: item.name)
        )
        return (meal, recipe)
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
    /// per-serving == the resolved portion is what lets the recipe's yield change from a hardcoded 1
    /// to the F1(c) default chain WITHOUT altering any logged meal's macros (decision §11.5).
    ///
    /// Every caller OFFERS the result for review: the plan tiers through `PlanResult.offeredRecipes`,
    /// and the dish-decomposition resolver, which builds its review-offered recipe from the same deduped
    /// ingredient pairs it already computes (F1(a) wire, §2.2a). None of them saves it.
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

    /// The default yield for a recipe built from a meal log (decision §11.5): the model's explicit
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

/// The English notes Fernlet itself writes onto a logged meal or a recipe, and the localized line a
/// screen draws for each (Spanish round step 2, 2026-10-20).
///
/// A meal's `note` and a recipe's `notes` are stored text, synced and read back later, and the stored
/// bytes are also matched: `MealRow` tells a seeded demo meal by its exact note, and a legacy row's
/// component breakdown is read out of the ``matchedFromFoodSelectionPrefix`` note. So every note
/// below stays the English it was written in, on every device and in every language, and is never
/// localized at write time; a screen swaps an exact stored note for its localized line at draw time,
/// the way `Workout.displayedNotes` draws a plan completion's note. A note the person typed, or one
/// edited away from the default, draws as stored.
///
/// The writers are `MealBuilder`, `MealResolutionService`, `FoodPlanning`, the meal correction in
/// `FernletStore` and the demo seed in the app, and `DiaryStore`, `SavedRecipeService` and
/// `MealParser` in FernletKit. The two notes that carry a component list ("Matched locally from food
/// selection: …", "Corrected components: …") are never drawn as stored: a row with components draws
/// its breakdown and a "From your recipe" / "Matched from your foods" line instead.
///
/// Display only: what this returns is never persisted, exported, matched or put in a prompt. Pinned
/// by `LocalizationBoundaryTests.frozenStoredFoodNotes`.
nonisolated enum StoredFoodNote {
    /// The note the demo seed writes, which `MealRow` matches to hide the row's provenance tag.
    static let seededDemoMeal = "Seeded demo meal."

    /// The frozen start of the note `MealBuilder.mealFromIngredients` writes ahead of its component list.
    static let matchedFromFoodSelectionPrefix = "Matched locally from food selection: "

    /// Every meal note drawn through ``displayedMealNote(_:)``: the frozen English and its display line.
    private static let mealNotes: [(frozen: String, display: LocalizedStringResource)] = [
        ("Logged from saved recipe.", LocalizedStringResource("food.mealNote.loggedFromSavedRecipe",
            defaultValue: "Logged from saved recipe.", comment: "Note under a logged meal that came from one of the person's recipes")),
        ("Logged as one meal from your description.", LocalizedStringResource("food.mealNote.loggedAsOneMeal",
            defaultValue: "Logged as one meal from your description.", comment: "Note under a meal Fernlet logged as one dish from what the person typed")),
        ("Entered by hand.", LocalizedStringResource("food.mealNote.enteredByHand",
            defaultValue: "Entered by hand.", comment: "Note under a meal whose protein, carbs and fat the person typed in")),
        ("Corrected manually after quick logging.", LocalizedStringResource("food.mealNote.correctedManually",
            defaultValue: "Corrected manually after quick logging.", comment: "Note under a meal the person adjusted after logging it")),
        ("Seeded demo meal.", LocalizedStringResource("food.mealNote.seededDemo",
            defaultValue: "Seeded demo meal.", comment: "Note under a sample meal in the app's demo data")),
        ("Logged from saved product.", LocalizedStringResource("food.mealNote.loggedFromSavedProduct",
            defaultValue: "Logged from saved product.", comment: "Note under a meal logged from a packaged product saved from the web")),
        ("Selected from the food catalog.", LocalizedStringResource("food.mealNote.selectedFromCatalog",
            defaultValue: "Selected from the food catalog.", comment: "Note under a meal the person picked from the food search list")),
        ("Logged from a barcode scan.", LocalizedStringResource("food.mealNote.barcodeScan",
            defaultValue: "Logged from a barcode scan.", comment: "Note under a meal logged by scanning a product's barcode")),
        ("Logged from a nutrition label scan.", LocalizedStringResource("food.mealNote.labelScan",
            defaultValue: "Logged from a nutrition label scan.", comment: "Note under a meal logged by photographing a nutrition label")),
        ("Added from a gentle nutrient nudge.", LocalizedStringResource("food.mealNote.nutrientNudge",
            defaultValue: "Added from a gentle nutrient nudge.", comment: "Note under a food logged from the suggestion that a nutrient has been low lately")),
        ("Logged from URL recipe.", LocalizedStringResource("food.mealNote.urlRecipe",
            defaultValue: "Logged from URL recipe.", comment: "Note under a meal logged from a recipe saved from a web page")),
        ("Logged from URL recipe. Macros not available.", LocalizedStringResource("food.mealNote.urlRecipeNoMacros",
            defaultValue: "Logged from URL recipe. Macros not available.", comment: "Note under a meal logged from a web recipe whose page gave no nutrition")),
        ("Estimated locally from the description. Add API lookup later for branded meals.",
         LocalizedStringResource("food.mealNote.estimatedLocally",
            defaultValue: "Estimated locally from the description. Add API lookup later for branded meals.",
            comment: "Note under a meal whose nutrition Fernlet estimated on the phone from what the person typed")),
    ]

    /// Every recipe note drawn through ``displayedRecipeNotes(_:)``: the one a recipe saved from a
    /// meal log starts with (`MealBuilder.createRecipe`).
    private static let recipeNotes: [(frozen: String, display: LocalizedStringResource)] = [
        ("Created from meal logging.", LocalizedStringResource("food.recipeNote.createdFromMealLogging",
            defaultValue: "Created from meal logging.", comment: "The starting note on a recipe the person saved while logging a meal")),
    ]

    /// The frozen meal notes, in table order (for the boundary pin).
    static var frozenMealNotes: [String] { mealNotes.map(\.frozen) }

    /// The frozen recipe notes, in table order (for the boundary pin).
    static var frozenRecipeNotes: [String] { recipeNotes.map(\.frozen) }

    /// The catalog key `frozen` draws through, or nil when it is not a note Fernlet writes.
    static func displayKey(forStoredNote frozen: String) -> String? {
        (mealNotes + recipeNotes).first { $0.frozen == frozen }?.display.key
    }

    /// The line a meal row draws for a stored `note`: the localized line for a note Fernlet wrote,
    /// else the note exactly as stored.
    static func displayedMealNote(_ note: String) -> String {
        guard let row = mealNotes.first(where: { $0.frozen == note }) else { return note }
        return String(localized: row.display)
    }

    /// The notes a recipe screen draws for stored `notes`, by the same rule as ``displayedMealNote(_:)``.
    static func displayedRecipeNotes(_ notes: String) -> String {
        guard let row = recipeNotes.first(where: { $0.frozen == notes }) else { return notes }
        return String(localized: row.display)
    }

    /// The notes to SAVE when an editor seeded with ``displayedRecipeNotes(_:)`` comes back as `typed`:
    /// the stored English while the person left the drawn text alone, else what they typed. Opening and
    /// saving a recipe on a translated device never stores the translation.
    static func savedRecipeNotes(editing typed: String, stored: String) -> String {
        typed == displayedRecipeNotes(stored) ? stored : typed
    }
}
