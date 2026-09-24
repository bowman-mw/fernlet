//
//  RecipePartsDraft.swift
//  Fernlet
//
//  Multipart recipes (owner decision 2026-09-24): the recipe editor's builder logic, with no SwiftUI,
//  so every rule the editor applies to parts is testable on its own (RecipeMultipartBuilderTests).
//  The views live in RecipePartsEditor.swift; the stored shape is built by the domain's
//  `RecipeComponentAssembly` when the editor saves.
//

import Foundation
import FernletDomainModel

/// The recipe editor's multipart state, and every edit the editor can make to it.
///
/// `parts` is EMPTY for a one-part recipe: the editor's flat ingredient and step lists are then in
/// charge, exactly as before parts existed. Splitting a recipe makes it at least two parts, and
/// removing parts down to one collapses it back to the flat lists. Caps are the editor's
/// whole-recipe caps (``RecipeLimits``), counted across every part, plus
/// ``RecipeComponentLimits/maxComponents`` parts.
struct RecipePartsDraft: Equatable {
    var parts: [RecipeComponentInput] = []

    /// True once the recipe has been split into parts.
    var isMultipart: Bool { !parts.isEmpty }

    /// Every ingredient row across all parts, in making order. The save gate and the per-serving
    /// total read this.
    var allIngredients: [ManualRecipeIngredientInput] { parts.flatMap(\.ingredients) }

    /// Ingredient rows across all parts (blank rows included: each is a row the cap must hold room for).
    var ingredientRowCount: Int { parts.reduce(0) { $0 + $1.ingredients.count } }

    /// Steps across all parts.
    var stepCount: Int { parts.reduce(0) { $0 + $1.steps.count } }

    /// Room for one more part: under the part cap, with room for the blank ingredient row it starts with.
    var canAddPart: Bool {
        parts.count < RecipeComponentLimits.maxComponents && ingredientRowCount < RecipeLimits.maxIngredients
    }

    var canAddIngredient: Bool { ingredientRowCount < RecipeLimits.maxIngredients }

    var canAddStep: Bool { stepCount < RecipeLimits.maxSteps }

    /// Splits a one-part recipe: its current rows become the first part and an empty part follows.
    /// Returns the new part's id, or `nil` when the recipe is already split or no row fits.
    mutating func split(ingredients: [ManualRecipeIngredientInput], steps: [RecipeStep]) -> UUID? {
        guard !isMultipart, ingredients.count < RecipeLimits.maxIngredients else { return nil }
        let first = RecipeComponentInput(ingredients: ingredients.isEmpty ? [ManualRecipeIngredientInput()] : ingredients,
                                         steps: steps)
        let second = RecipeComponentInput()
        parts = [first, second]
        return second.id
    }

    /// Adds an empty part at the end, returning its id; `nil` at a cap or before the recipe is split.
    mutating func addPart() -> UUID? {
        guard isMultipart, canAddPart else { return nil }
        let part = RecipeComponentInput()
        parts.append(part)
        return part.id
    }

    /// Removes a part. When that leaves a single part, the draft collapses back to one-part and returns
    /// the survivor, whose rows the flat editor takes over. Otherwise it returns `nil`.
    mutating func removePart(_ id: UUID) -> RecipeComponentInput? {
        guard let index = parts.firstIndex(where: { $0.id == id }) else { return nil }
        parts.remove(at: index)
        guard parts.count < RecipeComponentLimits.minComponents else { return nil }
        let survivor = parts.first ?? RecipeComponentInput()
        parts = []
        return survivor
    }

    /// Moves a part one place earlier (`offset` −1) or later (+1) in making order.
    mutating func movePart(_ id: UUID, by offset: Int) {
        guard let index = parts.firstIndex(where: { $0.id == id }), parts.indices.contains(index + offset) else { return }
        parts.swapAt(index, index + offset)
    }

    /// Adds a blank ingredient row to a part and returns its id (the editor expands it); `nil` at the cap.
    mutating func addIngredient(to partID: UUID) -> UUID? {
        guard canAddIngredient, let index = parts.firstIndex(where: { $0.id == partID }) else { return nil }
        let row = ManualRecipeIngredientInput()
        parts[index].ingredients.append(row)
        return row.id
    }

    /// Lands a resolved row (a barcode scan) in a part, replacing the part's lone blank row exactly as
    /// the one-part editor does. A scan whose part was removed while the scanner was open lands in the
    /// last part. Past the row cap nothing is added (the Scan button is disabled there).
    mutating func appendIngredient(_ row: ManualRecipeIngredientInput, to partID: UUID?) {
        guard let index = parts.firstIndex(where: { $0.id == partID }) ?? parts.indices.last else { return }
        if parts[index].ingredients.count == 1, parts[index].ingredients[0].trimmedName.isEmpty {
            parts[index].ingredients[0] = row
        } else if canAddIngredient {
            parts[index].ingredients.append(row)
        }
    }

    /// Removes an ingredient row. A part's last row is reset to blank instead, as in the one-part editor.
    mutating func removeIngredient(_ rowID: UUID, from partID: UUID) {
        guard let index = parts.firstIndex(where: { $0.id == partID }) else { return }
        guard parts[index].ingredients.count > 1 else {
            parts[index].ingredients = [ManualRecipeIngredientInput()]
            return
        }
        parts[index].ingredients.removeAll { $0.id == rowID }
    }

    /// Appends a blank step to a part; nothing at the whole-recipe step cap.
    mutating func addStep(to partID: UUID) {
        guard canAddStep, let index = parts.firstIndex(where: { $0.id == partID }) else { return }
        parts[index].steps.append(RecipeStep(text: ""))
    }

    mutating func removeStep(_ stepID: UUID, from partID: UUID) {
        guard let index = parts.firstIndex(where: { $0.id == partID }) else { return }
        parts[index].steps.removeAll { $0.id == stepID }
    }

    /// Moves a step one place within its own part (steps never cross parts by reordering).
    mutating func moveStep(_ stepID: UUID, in partID: UUID, by offset: Int) {
        guard let index = parts.firstIndex(where: { $0.id == partID }),
              let stepIndex = parts[index].steps.firstIndex(where: { $0.id == stepID }),
              parts[index].steps.indices.contains(stepIndex + offset) else { return }
        parts[index].steps.swapAt(stepIndex, stepIndex + offset)
    }

    /// True when a part holds nothing the user typed (every row blank, no step text), so removing it
    /// needs no confirmation.
    func isBlank(_ partID: UUID) -> Bool {
        guard let part = parts.first(where: { $0.id == partID }) else { return true }
        let hasRow = part.ingredients.contains { !$0.trimmedName.isEmpty }
        let hasStep = part.steps.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !hasRow && !hasStep && part.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A saved recipe's parts in editor form, empty for a one-part recipe. Each part lists at least
    /// one row (a blank one for a steps-only part), as the one-part editor does.
    static func parts(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> [RecipeComponentInput] {
        guard recipe.isMultipart else { return [] }
        return recipe.resolvedComponents.map { part in
            let rows = RecipeEditorInputs.inputs(for: part.ingredients, foodItems: foodItems)
            return RecipeComponentInput(id: part.id, name: part.name ?? "",
                                        ingredients: rows.isEmpty ? [ManualRecipeIngredientInput()] : rows,
                                        steps: part.steps)
        }
    }
}

/// Turns stored recipe rows back into the editor's rows, shared by the one-part editor and each part
/// of a multipart one.
enum RecipeEditorInputs {
    /// One editor row per ingredient whose food still resolves. A manual (custom) food re-opens as a
    /// hand-typed row with its macros, and a catalog food re-opens bound to its id.
    static func inputs(for ingredients: [RecipeIngredient], foodItems: [FoodItem]) -> [ManualRecipeIngredientInput] {
        ingredients.compactMap { recipeIngredient -> ManualRecipeIngredientInput? in
            guard let foodItem = foodItems.first(where: { $0.id == recipeIngredient.foodItemId }) else { return nil }
            let selectedFoodItemId = foodItem.source == .manual ? nil : foodItem.id
            return ManualRecipeIngredientInput(
                name: foodItem.name,
                selectedFoodItemId: selectedFoodItemId,
                quantity: recipeIngredient.quantity,
                unit: recipeIngredient.unit,
                protein: foodItem.macros.protein,
                carbs: foodItem.macros.carbs,
                fat: foodItem.macros.fat,
                scannedMicronutrients: foodItem.source == .manual && foodItem.micronutrients.hasAnyValue ? foodItem.micronutrients : nil
            )
        }
    }
}
