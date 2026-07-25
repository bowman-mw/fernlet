import Foundation

/// A single bound substitution suggestion: a catalog `FoodItem` the model (or the deterministic
/// fallback) proposes as a replacement for one recipe ingredient, plus an optional short human reason.
///
/// The `FoodItem` is always resolved from local data — the model never invents a food, it only picks a
/// candidate NUMBER, and code binds that number back to the catalog item here (mirroring
/// `FoodSelectionCandidate`). The `reason` is free-form model copy for display only; it never feeds any
/// number, macro, or persisted field.
public nonisolated struct IngredientSubstitutionSuggestion: Identifiable, Equatable, Sendable {
    public var id: UUID { foodItem.id }
    public let foodItem: FoodItem
    public let reason: String?

    public init(foodItem: FoodItem, reason: String? = nil) {
        self.foodItem = foodItem
        self.reason = reason
    }
}

/// Pure, value-level ingredient substitution for recipes (F4, decision §11.4).
///
/// **Substitution FORKS a new recipe — it never mutates the source.** This namespace holds only the
/// arithmetic and value assembly: it takes a source `RecipeDefinition`, an ingredient to replace, and a
/// substitute `FoodItem`, and returns a *new* `RecipeDefinition` carrying `parentRecipeID = source.id`.
/// It performs no store writes, resolves nothing from the catalog itself (the caller passes the already-
/// resolved `FoodItem`s in), and — per the handoff invariant — the MODEL never contributes a quantity or
/// a macro: the replacement quantity is computed here by gram-equivalence, and macros are recomputed
/// downstream from the bound `foodItemId` by `MealBuilder`.
///
/// Living in `FernletDomainModel` (below the S3 wall, value-only) is deliberate: the app-target UI and a
/// future below-the-wall aggregation can both call it, and — like `RecipeScaling` — it adds no stored
/// state to any existing type, so it is not the enum-case / stored-property clean-build hazard.
public nonisolated enum RecipeSubstitution {

    /// The maximum sensible replacement quantity in any unit — a guard against a degenerate
    /// gram-equivalence (e.g. a near-zero grams-per-unit) producing an absurd amount. Matches the loose
    /// upper clamp used across the recipe binders.
    public static let maxReplacementQuantity: Double = 5000

    /// A replacement quantity + unit for `substitute` that approximates the ORIGINAL ingredient's gram
    /// weight, so swapping (say) butter for olive oil keeps the recipe's scale roughly intact.
    ///
    /// Gram-equivalence, code-only (no model number): convert the original amount to grams via the
    /// original food's own portion data, then divide by the substitute's grams-per-preferred-unit. When
    /// either side has no gram mapping (a `.serving`/`.each`-only food with no portion table, or an
    /// unresolved original), fall back to the substitute's natural `defaultRecipeQuantity` at its
    /// `preferredRecipeUnit` — a sane "1 serving / 1 each" default rather than a fabricated weight.
    ///
    /// - Parameters:
    ///   - original: the recipe ingredient being replaced (its stored base quantity/unit).
    ///   - originalFoodItem: the food `original` is bound to, resolved by the caller; `nil` when it
    ///     could not be resolved (then the gram match is skipped and the default is used).
    ///   - substitute: the replacement food.
    public static func replacementQuantity(
        for original: RecipeIngredient,
        originalFoodItem: FoodItem?,
        substitute: FoodItem
    ) -> (quantity: Double, unit: String) {
        let unit = substitute.preferredRecipeUnit
        let fallback = (max(substitute.defaultRecipeQuantity(for: unit), 0.01), unit.rawValue)

        guard let originalFoodItem,
              let originalGrams = originalFoodItem.gramsEquivalent(quantity: original.quantity, unit: original.unit),
              originalGrams > 0,
              let gramsPerUnit = substitute.gramsEquivalent(quantity: 1, unit: unit.rawValue),
              gramsPerUnit > 0 else {
            return fallback
        }

        let raw = originalGrams / gramsPerUnit
        let clamped = min(max(raw, 0.01), maxReplacementQuantity)
        return (roundedQuantity(clamped), unit.rawValue)
    }

    /// The bound replacement `RecipeIngredient` (fresh id, substitute's `foodItemId`, gram-matched
    /// quantity/unit). Convenience over `replacementQuantity` for the fork call site.
    public static func substitutedIngredient(
        replacing original: RecipeIngredient,
        originalFoodItem: FoodItem?,
        with substitute: FoodItem
    ) -> RecipeIngredient {
        let (quantity, unit) = replacementQuantity(
            for: original,
            originalFoodItem: originalFoodItem,
            substitute: substitute
        )
        return RecipeIngredient(foodItemId: substitute.id, quantity: quantity, unit: unit)
    }

    /// Forks a NEW recipe from `source` with exactly one ingredient replaced. Returns `nil` when
    /// `originalIngredientID` is not in the source (nothing to replace) — the caller then does nothing,
    /// so there is no auto-fork on a stale target.
    ///
    /// The source is copied, never mutated: the new recipe gets a fresh `id`, `parentRecipeID =
    /// source.id`, its own `createdAt`/`updatedAt`, and a name suffixed once (repeated forks do not stack
    /// the suffix). This is the ONLY place a fork is minted, and callers invoke it only on an explicit
    /// user save from the preview — there is no unbounded auto-forking.
    public static func fork(
        source: RecipeDefinition,
        replacing originalIngredientID: UUID,
        with newIngredient: RecipeIngredient,
        now: Date = Date()
    ) -> RecipeDefinition? {
        guard let index = source.ingredients.firstIndex(where: { $0.id == originalIngredientID }) else {
            return nil
        }
        var ingredients = source.ingredients
        ingredients[index] = newIngredient
        return RecipeDefinition(
            id: UUID(),
            name: forkedName(from: source.name),
            servings: source.servings,
            ingredients: ingredients,
            notes: source.notes,
            source: source.source,
            createdAt: now,
            updatedAt: now,
            webImport: nil,
            parentRecipeID: source.id
        )
    }

    /// A "(adapted)" suffix, applied at most once so forking a fork does not grow "(adapted) (adapted)".
    public static func forkedName(from name: String) -> String {
        let suffix = " (adapted)"
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Recipe" : trimmed
        return base.hasSuffix(suffix) ? base : base + suffix
    }

    /// Round to a single decimal place — enough precision for a cooking amount without exposing the raw
    /// gram-equivalence float.
    private static func roundedQuantity(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
