import Foundation

// Recipes as building blocks, step 3: which saved recipes the recipe editor offers as an ingredient
// (owner pick P10a: a short "Your recipes" group above food results, plus "From your recipes").

/// The saved recipes the recipe editor may offer as an ingredient of the recipe being edited.
public nonisolated enum RecipeIngredientChoices {
    /// Most recipes the "Your recipes" group shows above food results.
    public static let maxSearchMatches = 3

    /// The recipes `editing` may use, in `recipes` order: every recipe except those that would make a
    /// loop or a chain past ``RecipeNestingLimits/maxDepth`` (``RecipeNestingGraph/refusal(adding:to:)``).
    /// `editing` is nil for a recipe not saved yet, which nothing can use, so only depth applies.
    public static func usable(
        from recipes: [RecipeDefinition], editing: UUID?, graph: RecipeNestingGraph
    ) -> [RecipeDefinition] {
        recipes.filter { candidate in
            guard let editing else {
                return graph.height(of: candidate.id) + 1 <= RecipeNestingLimits.maxDepth
            }
            return graph.refusal(adding: candidate.id, to: editing) == nil
        }
    }

    /// The usable recipes whose names hold every word of `query`, best first: an exact name, then a
    /// name that starts with the query, then the rest in `usable` order. At most ``maxSearchMatches``.
    public static func matches(for query: String, in usable: [RecipeDefinition]) -> [RecipeDefinition] {
        let normalizedQuery = FoodItemSearch.normalized(query)
        let words = normalizedQuery.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let scored: [(recipe: RecipeDefinition, rank: Int, order: Int)] = usable.enumerated().compactMap { order, recipe in
            let name = FoodItemSearch.normalized(recipe.name)
            let nameWords = name.split(separator: " ").map(String.init)
            guard words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) else { return nil }
            let rank = name == normalizedQuery ? 0 : (name.hasPrefix(normalizedQuery) ? 1 : 2)
            return (recipe, rank, order)
        }
        return scored.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .prefix(maxSearchMatches).map(\.recipe)
    }
}

/// How much a recipe makes, as the person states it ("Makes 2 cups", "Makes 480 g"): the optional
/// ``RecipeDefinition/makes`` (owner pick P02a).
///
/// Entry and display only. A line that uses the recipe is always SAVED in servings (see
/// ``RecipeFood``), so this amount converts what the person types ("1 cup") into servings and shows a
/// servings line back in it ("1 cup (2 servings)"); it never reaches nutrition. Persisted, so the
/// decode is tolerant: an amount that is not finite and positive, or a unit that is not a mass or
/// volume ``RecipeUnit``, reads as absent (``isValid``).
public nonisolated struct RecipeYield: Codable, Hashable, Sendable {
    /// The amount the whole recipe makes.
    public var quantity: Double
    /// Its unit: a mass or volume ``RecipeUnit`` raw value ("cup", "g"). A frozen token.
    public var unit: String

    public init(quantity: Double, unit: String) {
        self.quantity = quantity
        self.unit = unit
    }

    /// The unit, when it is a mass or volume ``RecipeUnit``.
    public var recipeUnit: RecipeUnit? {
        guard let unit = RecipeUnit.normalized(unit), unit.dimension == .mass || unit.dimension == .volume else { return nil }
        return unit
    }

    /// A usable amount: finite, positive, within the conversion bound, in a mass or volume unit.
    public var isValid: Bool {
        quantity.isFinite && quantity > 0 && quantity <= SharedRecipeLimits.maxQuantity && recipeUnit != nil
    }

    /// `self` when ``isValid``, else nil: the one gate every reader goes through.
    public var validated: RecipeYield? { isValid ? self : nil }
}

/// The unit a recipe line is typed in, in the editor: servings of the sub-recipe, whole batches, or
/// the unit of its "Makes" amount. Every choice converts to the servings the line is saved in.
public nonisolated enum RecipeAmountUnit: Hashable, Sendable {
    case servings
    case batches
    /// The sub-recipe's ``RecipeYield`` unit ("cup").
    case makes(RecipeYield)

    /// The choices a line using `recipe` offers, servings first.
    public static func choices(for recipe: RecipeDefinition) -> [RecipeAmountUnit] {
        var choices: [RecipeAmountUnit] = [.servings, .batches]
        if let makes = recipe.makes?.validated { choices.append(.makes(makes)) }
        return choices
    }

    /// Servings of `recipe` in one of this unit.
    public func servingsPerUnit(of recipe: RecipeDefinition) -> Double {
        let servings = Double(max(recipe.servings, 1))
        switch self {
        case .servings: return 1
        case .batches: return servings
        case .makes(let yield): return servings / yield.quantity
        }
    }

    /// `servings` of `recipe` expressed in this unit.
    public func amount(forServings servings: Double, of recipe: RecipeDefinition) -> Double {
        servings / servingsPerUnit(of: recipe)
    }
}
