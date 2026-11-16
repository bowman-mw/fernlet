import Foundation

// Recipes as reusable building blocks (owner-approved design 2026-11-15,
// Docs/Recipes-As-Building-Blocks-Design-2026-11-15.md).
//
// A saved recipe used as an ingredient of another recipe is represented to everything that totals
// nutrition as an ordinary ``FoodItem``: its RECIPE FOOD. The recipe food's `id` IS the recipe's `id`,
// so a parent line `RecipeIngredient(foodItemId: sauce.id, ...)` is a recipe line by construction, and
// no field on ``RecipeIngredient`` changes. An older build, which cannot know any of this, still sees a
// valid food line with the sauce's whole-batch nutrition and totals the parent correctly; it cannot
// strip the link, because the link is the line's required `foodItemId`.
//
// The recipe food declares the WHOLE BATCH as its serving, counted in servings (`servingSize` =
// the recipe's servings, `servingUnit` "serving"), the shape ``RecipeServingConversion`` already reads
// for custom editor rows: "N servings" of it is N ÷ servings of the batch. Its macros are the batch's
// whole-gram line sums, the same numbers ``MealBuilder`` adds up, so a line of "all N servings" totals
// exactly what the sub-recipe's own rows did. A line to a recipe food is always stored in servings;
// cups or grams are entry and display only (the "Makes" amount), so a later change to how much a
// recipe makes never changes another recipe's numbers.
//
// Nothing here recurses (Power of 10, rule 1). Every walk over the "uses" graph is an explicit
// level-by-level work list, cut off at ``RecipeNestingLimits`` and guarded by a visited set, so a
// cycle that arrives anyway (two devices editing at once) is broken where it is found.

/// The named bounds on recipes used inside other recipes.
public nonisolated enum RecipeNestingLimits {
    /// Most levels a chain of recipes may have, counting the top recipe: cake → frosting → caramel.
    public static let maxDepth = 3
    /// Most recipes one graph walk visits. Generous: every saved recipe the store will hold, and each
    /// level of a walk is one pass over at most this many.
    public static let maxRecipesWalked = 5_000
}

extension FoodItem {
    /// The category every recipe food is saved under. A frozen token: it rides the synced blob.
    public static let recipeFoodCategory = "recipe"

    /// True for a recipe's own stand-in food (``RecipeFood``).
    public var isRecipeFood: Bool { source == .recipe }
}

/// Builds the ``FoodItem`` that stands in for a saved recipe wherever another recipe uses it.
public nonisolated enum RecipeFood {
    /// The recipe food for `recipe`, given the foods its own lines point at (recipe foods included).
    ///
    /// Returns nil when a structured line cannot be resolved against `foodItems` (the caller keeps the
    /// recipe food it already has rather than writing zeros over it), or when the recipe has no
    /// nutrition source at all (no lines and no web import).
    public static func make(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> FoodItem? {
        guard let batch = batchNutrition(of: recipe, foodItems: foodItems) else { return nil }
        return FoodItem(
            id: recipe.id,
            name: recipe.name,
            servingSize: Double(max(recipe.servings, 1)),
            servingUnit: RecipeUnit.serving.rawValue,
            macros: batch.macros,
            micronutrients: batch.micronutrients,
            category: FoodItem.recipeFoodCategory,
            source: .recipe,
            tags: []
        )
    }

    /// The whole batch's macros and micronutrients: the sum of each line's own conversion, as
    /// ``MealBuilder`` sums them, or a web import's per-serving nutrition times its servings.
    public static func batchNutrition(
        of recipe: RecipeDefinition, foodItems: [FoodItem]
    ) -> (macros: Macros, micronutrients: Micronutrients)? {
        if let webImport = recipe.webImport {
            let servings = Double(max(recipe.servings, 1))
            return (webImport.macros.scaled(by: servings), webImport.micronutrients.scaled(by: servings))
        }
        guard !recipe.ingredients.isEmpty else { return nil }
        let byID = Dictionary(foodItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var protein = 0, carbs = 0, fat = 0
        var micronutrients = Micronutrients()
        for line in recipe.ingredients {
            guard let food = byID[line.foodItemId], let conversion = line.servingConversion(using: food) else {
                return nil
            }
            let macros = conversion.scaledMacros(for: food)
            protein = Macros.clampedInt(Double(protein) + Double(macros.protein))
            carbs = Macros.clampedInt(Double(carbs) + Double(macros.carbs))
            fat = Macros.clampedInt(Double(fat) + Double(macros.fat))
            micronutrients.add(conversion.scaledMicronutrients(for: food))
        }
        return (Macros(protein: protein, carbs: carbs, fat: fat), micronutrients)
    }

    /// The line that uses `servings` servings of `recipe`: always counted in servings (see the file
    /// note), so it converts identically on every build.
    public static func line(using recipe: RecipeDefinition, servings: Double, id: UUID = UUID()) -> RecipeIngredient {
        RecipeIngredient(id: id, foodItemId: recipe.id, quantity: servings, unit: RecipeUnit.serving.rawValue)
    }
}

/// The "uses" graph over a set of saved recipes: which recipe lines point at which other recipes.
///
/// Built once per recipe-list change and read by the editor's picker, the store's refresher, the
/// steps view and the low-totals note. Every walk is bounded (see the file note).
public nonisolated struct RecipeNestingGraph: Sendable {
    /// Each recipe's distinct child recipe ids, in the order its lines first use them.
    public let children: [UUID: [UUID]]
    /// Each recipe's distinct parent recipe ids (the recipes that use it).
    public let parents: [UUID: [UUID]]

    public init(recipes: [RecipeDefinition]) {
        let ids = Set(recipes.prefix(RecipeNestingLimits.maxRecipesWalked).map(\.id))
        var children: [UUID: [UUID]] = [:]
        var parents: [UUID: [UUID]] = [:]
        for recipe in recipes.prefix(RecipeNestingLimits.maxRecipesWalked) {
            var seen = Set<UUID>()
            for line in recipe.ingredients where ids.contains(line.foodItemId) && seen.insert(line.foodItemId).inserted {
                children[recipe.id, default: []].append(line.foodItemId)
                parents[line.foodItemId, default: []].append(recipe.id)
            }
        }
        self.children = children
        self.parents = parents
    }

    /// True when `id` is a saved recipe some other recipe uses.
    public func isUsed(_ id: UUID) -> Bool { !(parents[id] ?? []).isEmpty }

    /// The recipes that use `id`, directly or through others, in the order to refresh their recipe
    /// foods after `id` changed: each one after every recipe between it and `id`. `id` itself is not
    /// included, and a recipe met again on a later level moves to that later place.
    public func refreshOrder(after id: UUID) -> [UUID] {
        let levels = walkLevels(from: id, along: parents, levelCap: RecipeNestingLimits.maxDepth + 1)
        var order: [UUID] = []
        for level in levels {
            order.removeAll { level.contains($0) }
            order += level.filter { $0 != id }
        }
        return order
    }

    /// Levels in the chain below `id`, counting `id`: 1 for a recipe that uses no recipe. Returns
    /// `maxDepth + 1` for anything deeper, or for a cycle, which never ends.
    public func height(of id: UUID) -> Int {
        let levels = walkLevels(from: id, along: children, levelCap: RecipeNestingLimits.maxDepth + 1)
        if levels.last?.contains(id) == true { return RecipeNestingLimits.maxDepth + 1 }
        return min(levels.count + 1, RecipeNestingLimits.maxDepth + 1)
    }

    /// Longest chain of recipes above `id` (0 when nothing uses it), capped at `maxDepth + 1`.
    public func levelsAbove(_ id: UUID) -> Int {
        walkLevels(from: id, along: parents, levelCap: RecipeNestingLimits.maxDepth + 1).count
    }

    /// Why `child` may not be added as an ingredient of `parent`, or nil when it may.
    public func refusal(adding child: UUID, to parent: UUID) -> RecipeNestingRefusal? {
        if child == parent || descendants(of: child).contains(parent) { return .loop }
        let existingBelowParent = height(of: parent) - 1
        let below = max(existingBelowParent, height(of: child))
        return levelsAbove(parent) + 1 + below > RecipeNestingLimits.maxDepth ? .tooDeep : nil
    }

    /// Every recipe `id` uses, directly or through others, up to the walk's cap.
    public func descendants(of id: UUID) -> Set<UUID> {
        Set(walkLevels(from: id, along: children, levelCap: RecipeNestingLimits.maxDepth + 1).flatMap { $0 })
    }

    /// The recipes whose steps `root` shows before its own, in making order: deepest first, then in
    /// the order the lines use them; each once. `root` itself is not included. Stops at `maxDepth`
    /// levels and never revisits a recipe, so a cycle shows each recipe at most once.
    public func makingOrder(below root: UUID) -> [UUID] {
        var order: [UUID] = []
        var placed: Set<UUID> = [root]
        // Post-order without recursion: a stack of (recipe, next child index, level).
        var stack: [(id: UUID, next: Int, level: Int)] = [(root, 0, 1)]
        var steps = 0
        let stepCap = RecipeNestingLimits.maxRecipesWalked * RecipeNestingLimits.maxDepth
        while let top = stack.last, steps < stepCap {
            steps += 1
            let kids = top.level < RecipeNestingLimits.maxDepth ? (children[top.id] ?? []) : []
            if top.next < kids.count {
                stack[stack.count - 1].next += 1
                let kid = kids[top.next]
                if placed.insert(kid).inserted { stack.append((kid, 0, top.level + 1)) }
            } else {
                stack.removeLast()
                if top.id != root { order.append(top.id) }
            }
        }
        return order
    }

    /// Breadth-first levels from `start` along `edges`, each level the ids first reached there, at
    /// most `levelCap` levels and ``RecipeNestingLimits/maxRecipesWalked`` ids per level. `start`
    /// appears in a level only when a cycle leads back to it.
    private func walkLevels(from start: UUID, along edges: [UUID: [UUID]], levelCap: Int) -> [[UUID]] {
        var levels: [[UUID]] = []
        var frontier: [UUID] = [start]
        var seenOnLevel = Set<UUID>()
        for _ in 0..<levelCap {
            seenOnLevel.removeAll(keepingCapacity: true)
            var next: [UUID] = []
            for id in frontier {
                for neighbour in edges[id] ?? [] where next.count < RecipeNestingLimits.maxRecipesWalked
                    && seenOnLevel.insert(neighbour).inserted {
                    next.append(neighbour)
                }
            }
            guard !next.isEmpty else { break }
            levels.append(next)
            // A cycle back to the start ends the walk: its levels would only repeat.
            if next.contains(start) { break }
            frontier = next
        }
        return levels
    }
}

/// Why a recipe cannot be used as an ingredient of another.
public nonisolated enum RecipeNestingRefusal: Equatable, Sendable {
    /// The recipe already uses the one being edited, directly or through another (or is that recipe).
    case loop
    /// The chain would pass ``RecipeNestingLimits/maxDepth`` levels.
    case tooDeep
}

extension RecipeNutritionGaps {
    /// The sub-recipes of `recipe` (through `graph`, in making order) that have lines with no
    /// nutrition of their own, each with its count, so the parent's note can name them.
    public static func subRecipeGaps(
        in recipe: RecipeDefinition, graph: RecipeNestingGraph,
        recipesByID: [UUID: RecipeDefinition], foodItems: [FoodItem]
    ) -> [(recipe: RecipeDefinition, lines: Int)] {
        graph.makingOrder(below: recipe.id).compactMap { id in
            guard let child = recipesByID[id] else { return nil }
            let count = linesWithoutNutrition(in: child, foodItems: foodItems)
            return count > 0 ? (child, count) : nil
        }
    }
}
