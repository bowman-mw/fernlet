import Foundation

// Recipes as building blocks, step 2: keeping recipe foods in step with their recipes
// (Docs/Recipes-As-Building-Blocks-Design-2026-11-15.md §3, §6, §10).
//
// A recipe food exists only while some recipe uses its recipe, so an older paired device, which lists
// it among the person's foods, sees one only for a recipe actually used as an ingredient. The store
// runs ``RecipeFoodSync/synced(foodItems:recipes:referenceFoods:)`` after every recipe change and after every sync,
// which is also how an edit made on an older device (which refreshes nothing) is caught up.

/// The pure rules the store applies to keep recipe foods current.
public nonisolated enum RecipeFoodSync {
    /// `foodItems` with every recipe food brought up to date against `recipes`:
    /// - each recipe some recipe uses gets its recipe food, rebuilt deepest first so a parent reads its
    ///   children's fresh numbers; a recipe whose lines no longer resolve keeps the food it had;
    /// - a recipe food whose recipe nothing uses any more is removed;
    /// - a recipe food whose recipe is gone but which a recipe still uses becomes a fixed food
    ///   (``frozen(_:)``), so that recipe keeps its numbers.
    /// Returns `foodItems` unchanged (same order) when nothing differs.
    ///
    /// `referenceFoods` are foods a line may point at that are not the person's own: the built-in
    /// catalog rows, which never enter `foodItems` (release review 2026-11-18, F1). They are read to
    /// resolve lines and never written into the result; a food in `foodItems` wins over one with the
    /// same id here, so a recipe food just rebuilt is the one its parent reads.
    public static func synced(
        foodItems: [FoodItem], recipes: [RecipeDefinition], referenceFoods: [FoodItem] = []
    ) -> [FoodItem] {
        let graph = RecipeNestingGraph(recipes: recipes)
        let recipesByID = Dictionary(recipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let referenced = Set(recipes.flatMap { $0.ingredients.map(\.foodItemId) })
        var foods = foodItems
        // Remove or freeze recipe foods no live recipe needs.
        foods = foods.compactMap { food in
            guard food.isRecipeFood else { return food }
            if recipesByID[food.id] != nil { return graph.isUsed(food.id) ? food : nil }
            return referenced.contains(food.id) ? frozen(food) : nil
        }
        // Rebuild every used recipe's food, deepest first.
        let used = recipes.map(\.id).filter { graph.isUsed($0) }
            .sorted { graph.height(of: $0) < graph.height(of: $1) }
        for id in used {
            guard let recipe = recipesByID[id] else { continue }
            let existing = foods.firstIndex { $0.id == id }
            guard let made = RecipeFood.make(for: recipe, foodItems: foods + referenceFoods) else { continue }
            if let existing {
                if foods[existing] != made { foods[existing] = made }
            } else {
                foods.append(made)
            }
        }
        return foods
    }

    /// Recipe foods for `ids` that are saved recipes and have none yet, built against `foodItems`, so
    /// an editor row picked as a recipe binds to its recipe food rather than minting a custom
    /// ingredient. Deepest first; a recipe whose lines do not resolve is skipped. `referenceFoods` are
    /// read, never added, as in ``synced(foodItems:recipes:referenceFoods:)``.
    public static func ensuring(
        _ ids: [UUID], foodItems: [FoodItem], recipes: [RecipeDefinition], referenceFoods: [FoodItem] = []
    ) -> [FoodItem] {
        let have = Set(foodItems.map(\.id))
        let graph = RecipeNestingGraph(recipes: recipes)
        let wanted = recipes.filter { ids.contains($0.id) && !have.contains($0.id) }
            .sorted { graph.height(of: $0.id) < graph.height(of: $1.id) }
        var foods = foodItems
        for recipe in wanted {
            // Its own sub-recipes first, so its numbers read theirs.
            let below = graph.makingOrder(below: recipe.id).compactMap { id in recipes.first { $0.id == id } }
            for child in below where !foods.contains(where: { $0.id == child.id }) {
                if let made = RecipeFood.make(for: child, foodItems: foods + referenceFoods) { foods.append(made) }
            }
            if let made = RecipeFood.make(for: recipe, foodItems: foods + referenceFoods) { foods.append(made) }
        }
        return foods
    }

    /// A recipe food turned into an ordinary fixed food: the numbers of its last version, saved like
    /// a custom ingredient so it stays among the foods its recipe lines point at.
    public static func frozen(_ food: FoodItem) -> FoodItem {
        var fixed = food
        fixed.source = .manual
        fixed.category = "recipe ingredient"
        fixed.brandSource = "Custom ingredient"
        return fixed
    }

    /// The step label a deleted recipe's steps carry once copied into a recipe that used it:
    /// "Dragonfruit sauce: Blend the fruit". The recipe's name is user content, never localized.
    public static func copiedStep(_ step: RecipeStep, from recipeName: String) -> RecipeStep {
        RecipeStep(text: String("\(recipeName): \(step.text)".prefix(SharedRecipeLimits.maxStepTextCharacters)),
                   durationSeconds: step.durationSeconds)
    }

    /// `parent` after the recipe `deleted` it uses is removed: the deleted recipe's steps, and those
    /// of every recipe it used, are copied in front of the parent's own, each labelled with its
    /// recipe's name, so no instructions are lost (owner pick P06a). The parent's lines are unchanged;
    /// the deleted recipe's food is frozen by ``synced(foodItems:recipes:referenceFoods:)``. Steps stay within
    /// `maxSteps`, the parent's own kept first.
    public static func parent(
        _ parent: RecipeDefinition, afterDeleting deleted: RecipeDefinition,
        allRecipes: [RecipeDefinition], maxSteps: Int
    ) -> RecipeDefinition {
        let graph = RecipeNestingGraph(recipes: allRecipes)
        let byID = Dictionary(allRecipes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sources = graph.makingOrder(below: deleted.id).compactMap { byID[$0] } + [deleted]
        let copied = sources.flatMap { source in (source.steps ?? []).map { copiedStep($0, from: source.name) } }
        let own = parent.steps ?? []
        var updated = parent
        let room = max(maxSteps - own.count, 0)
        let combined = Array(copied.prefix(room)) + own
        updated.steps = combined.isEmpty ? nil : combined
        return updated
    }
}
