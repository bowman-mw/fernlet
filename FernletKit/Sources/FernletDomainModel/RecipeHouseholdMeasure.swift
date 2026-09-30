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
// household choice only this round's readers convert is saved as the grams it converts to, with the
// choice kept beside them as display metadata — never as a new `RecipeUnit` token (a token an older
// peer does not know fails the same way). A choice an older build already reads the same way ("1 cup"
// of a food stating one cup, "2 slice") is kept as typed, so every other surface still shows it.
//
// Every path that MINTS a recipe line applies it (fix round 1, finding u2-C-U2-3): the editor
// (`CustomIngredientUpsert`), a substitution fork (`RecipeSubstitution.substitutedIngredient`), and a
// recipe a meal log creates (`FernletStore.commitResolution`, via `RecipeDefinition.savingHouseholdAsGrams`).
// A fork saved as grams saves the ORIGINAL line's grams, not its rounded count's (fix round 2, N-1).

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

    /// The line as it is SAVED — from the recipe editor, a substitution fork, or a recipe a meal log
    /// mints: a count or volume amount of a mass-served food that converts through one of the food's
    /// USDA portions ONLY on this round's readers becomes the grams it converts to, with the choice in
    /// ``householdMeasure`` ("1 each" of a banana → `118 g`, "medium"; "1 cup" of honey, whose cup and
    /// tablespoon an older build found ambiguous → `339 g`, "cup").
    ///
    /// A line an older build already converts to the same grams is kept as typed (report §6.3: "use
    /// `2 each` only when today's reader already resolves it") — "1 cup" of cooked rice (one stated
    /// cup), "2 slice" of bread, so the grocery list, share text and export still read "1 cup", and
    /// fix round 1's finding u2-L-M2 (every such line had turned into grams) stays closed. Every other
    /// line — grams, ounces, servings, a custom food's own serving, a volume-served food — is returned
    /// unchanged, as is one whose conversion fails.
    public func savingHouseholdAsGrams(using foodItem: FoodItem) -> RecipeIngredient {
        guard let saved = householdGrams(using: foodItem) else { return self }
        if let strict = strictlyReadGrams(using: foodItem),
           abs(strict - saved.quantity) <= Self.householdRestoreTolerance * saved.quantity {
            return self
        }
        return saved
    }

    /// The line as its grams with the choice beside them — a count or volume amount of a mass-served
    /// food that converts through one of its USDA portions — whether or not an older build reads it
    /// too; nil for every other line. ``savingHouseholdAsGrams(using:)`` keeps a line an older build
    /// reads; a substitution fork whose computed count is not a cook's amount ("0.027 cup") takes
    /// this form regardless (fix round 2, finding N-1).
    func householdGrams(using foodItem: FoodItem) -> RecipeIngredient? {
        guard foodItem.id == foodItemId,
              let requested = RecipeUnit.normalized(unit), requested.isCount || requested.isVolume,
              RecipeUnit.normalized(foodItem.servingUnit)?.dimension == .mass,
              let conversion = servingConversion(using: foodItem), conversion.provenance == .sourcePortion,
              let grams = conversion.grams, let portion = conversion.sourcePortion,
              let label = Self.householdLabel(for: requested, portion: portion) else { return nil }
        let measure = RecipeHouseholdMeasure(label: label, gramsPerUnit: grams / quantity)
        guard measure.isValid else { return nil }
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

    /// Mass-served source-portion lines rewritten by ``savingHouseholdAsGrams(using:)``; a line whose
    /// food is absent from `foodItems` is kept as it is.
    static func savingHouseholdAsGrams(_ lines: [RecipeIngredient], using foodItems: [FoodItem]) -> [RecipeIngredient] {
        lines.map { line in
            foodItems.first { $0.id == line.foodItemId }.map { line.savingHouseholdAsGrams(using: $0) } ?? line
        }
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

extension RecipeDefinition {
    /// The recipe with every line saved as ``RecipeIngredient/savingHouseholdAsGrams(using:)`` saves it,
    /// against `foodItems` (the rows its lines are bound to). For a recipe a MEAL LOG mints — quick log's
    /// multi-ingredient items and the reviewed decomposition — whose lines carry the resolver's units
    /// ("4 each" of a banana), which only this round's readers convert (fix round 1, finding u2-C-U2-3).
    public func savingHouseholdAsGrams(using foodItems: [FoodItem]) -> RecipeDefinition {
        var saved = self
        saved.ingredients = RecipeIngredient.savingHouseholdAsGrams(ingredients, using: foodItems)
        return saved
    }
}
