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

    /// How far rounding may move a replacement amount off the exact gram match before a finer
    /// rounding is used (``replacementQuantity(for:originalFoodItem:substitute:)``).
    public static let roundingTolerance = 0.01

    /// A replacement quantity + unit for `substitute` that approximates the ORIGINAL ingredient's gram
    /// weight, so swapping (say) butter for olive oil keeps the recipe's scale roughly intact.
    ///
    /// Gram-equivalence, code-only (no model number): convert the original amount to grams via the
    /// original food's own portion data, then divide by the substitute's grams-per-preferred-unit. When
    /// either side has no gram mapping (a `.serving`/`.each`-only food with no portion table, or an
    /// unresolved original), fall back to the substitute's natural `defaultRecipeQuantity` at its
    /// `preferredRecipeUnit` — a sane "1 serving / 1 each" default rather than a fabricated weight.
    ///
    /// The amount is rounded to one decimal when that stays within ``roundingTolerance`` of the gram
    /// match, else to two or three decimals, and never to zero (fix round 2 of the ingredient-search
    /// round, finding N-1). Since F4a a substitute's unit is often a whole item — an apple is 182 g, an
    /// onion 110 g, a pineapple 905 g — and one decimal of one moved 118 g of banana to 0.6 of an apple
    /// (109.2 g) and a clove of garlic (3 g) to "0 each" of onion, a line that converts on no build.
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

        guard let originalGrams = matchedGrams(of: original, on: originalFoodItem),
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
    ///
    /// Saved the way the recipe editor saves a line (``RecipeIngredient/savingHouseholdAsGrams(using:)``):
    /// a substitute whose preferred unit only this round's readers convert (a medium apple is USDA's
    /// "medium (3" dia)") becomes grams with "medium" kept for display, so the fork does not total zero
    /// on a paired device still on an older build (fix round 1, finding u2-C-U2-3). Those grams are the
    /// ORIGINAL line's, not the rounded count's (fix round 2, finding N-1): 118 g of banana swaps for
    /// `118 g` of apple, shown "0.65 medium (118 g)". A count that is not a one-decimal cook's amount
    /// ("0.032 cup" of rice for a teaspoon of something) is saved the same way even where an older
    /// build reads the unit; a one-decimal count an older build reads ("1 cup", "2 slice") stays as is.
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
        let line = RecipeIngredient(foodItemId: substitute.id, quantity: quantity, unit: unit)
        let saved = line.savingHouseholdAsGrams(using: substitute)
        let tenths = quantity * 10
        let isCooksAmount = abs(tenths - tenths.rounded()) < 1e-9
        guard saved.householdMeasure != nil || !isCooksAmount,
              let originalGrams = matchedGrams(of: original, on: originalFoodItem),
              let household = line.householdGrams(using: substitute) else { return saved }
        let grams = roundedQuantity(min(originalGrams, RecipeConversionLimits.maxGrams))
        return RecipeIngredient(id: household.id, foodItemId: household.foodItemId, quantity: grams,
                                unit: household.unit, householdMeasure: household.householdMeasure)
    }

    /// The grams `original` weighs on its own food, or nil when the food is unresolved or the line
    /// does not convert to grams.
    private static func matchedGrams(of original: RecipeIngredient, on originalFoodItem: FoodItem?) -> Double? {
        guard let originalFoodItem,
              let grams = originalFoodItem.gramsEquivalent(quantity: original.quantity, unit: original.unit),
              grams.isFinite, grams > 0 else { return nil }
        return grams
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
            parentRecipeID: source.id,
            // F5: carry the source's cooking steps into the fork. A one-ingredient swap leaves the
            // step text broadly valid (and user-editable), so the "(adapted)" copy keeps its Cook
            // walker instead of silently losing it. Without this the added `steps` field defaults to
            // nil and manual-recipe steps vanish on fork.
            steps: source.steps,
            // Multipart: the fork keeps its parts, and the substitute takes the replaced row's place
            // in whichever part owned it (its id is fresh, so the claim is re-pointed, not dropped).
            components: source.components.map { parts in
                parts.map { part in
                    var remapped = part
                    remapped.ingredientIDs = part.ingredientIDs.map { $0 == originalIngredientID ? newIngredient.id : $0 }
                    return remapped
                }
            }
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
    /// gram-equivalence float — when that stays within ``roundingTolerance`` of `value`; else to two,
    /// then three decimals (0.648 of an apple is 0.65, a clove of garlic is 0.027 of an onion). Never
    /// zero: past three decimals the thousandth is kept, floored at one thousandth.
    private static func roundedQuantity(_ value: Double) -> Double {
        let scales: [Double] = [10, 100, 1_000]
        let fitting = scales.lazy
            .map { (value * $0).rounded() / $0 }
            .first { $0 > 0 && abs($0 - value) <= roundingTolerance * value }
        return fitting ?? max((value * 1_000).rounded() / 1_000, 0.001)
    }
}
