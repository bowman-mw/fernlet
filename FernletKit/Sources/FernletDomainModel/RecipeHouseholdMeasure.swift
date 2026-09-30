// RecipeHouseholdMeasure.swift
// FernletDomainModel
//
// How a recipe line chosen as a household amount ("1 each" of a banana, "½ cup" of butter) is saved —
// Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.3 "Persistence" and §8 F4a.
//
// A recipe line is converted again every time it is read, against the catalog row, on whichever
// build reads it — this device's, a paired device's, a peer's who received the recipe. "1 each" of a
// banana resolves only on a build whose portion reader knows that "medium (7" to 7-7/8" long)" is what
// one banana weighs; on an older build it converts to nothing and the recipe totals ZERO there
// (`MealBuilder` zeroes a recipe with an unconvertible line). Grams resolve on every build. So a
// household choice is saved as the grams it converts to, with the choice kept beside them as display
// metadata — never as a new `RecipeUnit` token (a token an older peer does not know fails the same way).

import Foundation

/// The household amount a recipe line was chosen as, kept beside the grams it is saved as (F4a).
///
/// Persisted inside ``RecipeIngredient`` under the frozen key `householdMeasure`, with frozen keys
/// `label` and `gramsPerUnit`. Display metadata only — nutrition never reads it — and valid only on a
/// grams line (``RecipeIngredient/amountText``, ``RecipeIngredient/restoringHouseholdAmount(using:)``).
/// Stored per ONE unit rather than as a count, so scaling the line (a recipe cooked for six) keeps it
/// true: the count shown is always the line's grams over ``gramsPerUnit``.
public nonisolated struct RecipeHouseholdMeasure: Codable, Equatable, Sendable {
    /// What one is: the food's USDA portion word ("medium", "clove", "medium stalk") or the recipe
    /// unit token the amount was typed in ("cup", "tbsp", "slice"). Source data shown verbatim, like a
    /// food name — never localized.
    public var label: String
    /// The grams one ``label`` weighs, from the food's own USDA portion.
    public var gramsPerUnit: Double

    public init(label: String, gramsPerUnit: Double) {
        self.label = label
        self.gramsPerUnit = gramsPerUnit
    }

    /// Longest label kept (USDA's portion words are a word or two).
    public static let maxLabelCharacters = 40

    /// A usable measure: a non-empty label within ``maxLabelCharacters`` and a finite, positive
    /// weight within the conversion bound. An invalid one reads as absent.
    public var isValid: Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && label.count <= Self.maxLabelCharacters
            && gramsPerUnit.isFinite && gramsPerUnit > 0 && gramsPerUnit <= RecipeConversionLimits.maxGrams
    }

    /// The unit the line re-opens in: the label's own unit when it is one ("cup", "slice"), else
    /// "each" (a size word or count noun).
    public var recipeUnit: RecipeUnit {
        RecipeUnit.normalized(label) ?? .each
    }
}

extension RecipeIngredient {
    /// How far the grams a re-opened household choice converts to may drift from the saved grams
    /// before the line re-opens as grams instead (the food's portions changed under it).
    public static let householdRestoreTolerance = 0.005

    /// The line as it is SAVED from the recipe editor: a count or volume amount of a mass-served food
    /// that converts through one of the food's USDA portions becomes the grams it converts to, with
    /// the choice in ``householdMeasure`` ("1 each" of a banana → `118 g`, "medium"). Every other line
    /// — grams, ounces, servings, a custom food's own serving, a volume-served food — is returned
    /// unchanged, as is one whose conversion fails.
    public func savingHouseholdAsGrams(using foodItem: FoodItem) -> RecipeIngredient {
        guard foodItem.id == foodItemId,
              let requested = RecipeUnit.normalized(unit), requested.isCount || requested.isVolume,
              RecipeUnit.normalized(foodItem.servingUnit)?.dimension == .mass,
              let conversion = servingConversion(using: foodItem), conversion.provenance == .sourcePortion,
              let grams = conversion.grams, let portion = conversion.sourcePortion,
              let label = Self.householdLabel(for: requested, portion: portion) else { return self }
        let measure = RecipeHouseholdMeasure(label: label, gramsPerUnit: grams / quantity)
        guard measure.isValid else { return self }
        return RecipeIngredient(id: id, foodItemId: foodItemId, quantity: grams, unit: RecipeUnit.gram.rawValue,
                                householdMeasure: measure)
    }

    /// The line as the recipe editor RE-OPENS it: a grams line saved from a household choice goes
    /// back to that choice ("1 each"), provided its food still converts the choice to the saved grams
    /// (within ``householdRestoreTolerance``); otherwise it stays grams.
    public func restoringHouseholdAmount(using foodItems: [FoodItem]) -> RecipeIngredient {
        guard let measure = householdMeasure, measure.isValid, RecipeUnit.normalized(unit) == .gram,
              quantity.isFinite, quantity > 0,
              let foodItem = foodItems.first(where: { $0.id == foodItemId }) else { return self }
        let count = (quantity / measure.gramsPerUnit * 1_000).rounded() / 1_000
        let chosen = RecipeIngredient(id: id, foodItemId: foodItemId, quantity: count, unit: measure.recipeUnit.rawValue)
        guard let grams = chosen.servingConversion(using: foodItem)?.grams,
              abs(grams - quantity) <= Self.householdRestoreTolerance * quantity else { return self }
        return chosen
    }

    /// The line's amount as the recipe page and cooking mode show it: "118 g", or — for a grams line
    /// saved from a household choice — "1 medium (118 g)". Numbers follow the person's locale; the
    /// label and unit are source tokens shown verbatim.
    public var amountText: String {
        let amount = quantity.formatted(.number.precision(.fractionLength(0...1)))
        guard let measure = householdMeasure, measure.isValid, RecipeUnit.normalized(unit) == .gram,
              quantity.isFinite else { return "\(amount) \(unit)" }
        let count = (quantity / measure.gramsPerUnit).formatted(.number.precision(.fractionLength(0...2)))
        return "\(count) \(measure.label) (\(amount) \(unit))"
    }

    /// What one of `requested` is on `portion`: the size and noun the portion states for "each"
    /// ("medium", "clove", "medium stalk"; "each" for a portion stated as `each`), else the unit token.
    private static func householdLabel(for requested: RecipeUnit, portion: FoodPortion) -> String? {
        guard requested == .each else { return requested.rawValue }
        guard case .count(let noun, let size)? = portion.measure else { return RecipeUnit.each.rawValue }
        let words = [size, noun].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
