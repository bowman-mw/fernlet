//
//  GroceryListComposer.swift
//  Fernlet
//
//  F3 — grocery list (decision §11.3). The app-target glue between the recipe stores and the pure,
//  below-the-wall `GroceryAggregation` engine: it does the catalog resolution the engine deliberately
//  refuses to do (§4.2), applies the F4 "cook for N" scaling, and routes web-imports through the
//  shipped both-shapes unifier `DataExportBuilder.recipeIngredientLines`. No persistence lives here —
//  the generated list is one-shot share text (check-off happens in Notes/Reminders). The only
//  persisted state is the weekly PLAN, which rides `FernletDay.plannedRecipeIDs` (Phase B).
//

import Foundation
import FernletDomainModel
import FoodCatalog

extension FernletStore {
    /// One recipe the user picked for a shopping list, with an optional "cook for N" yield override
    /// fed through the F4 scaling engine. `yieldOverride == nil` uses the recipe's stored servings.
    struct GrocerySelection: Equatable {
        var recipe: RecipeDefinition
        var yieldOverride: Int?

        init(recipe: RecipeDefinition, yieldOverride: Int? = nil) {
            self.recipe = recipe
            self.yieldOverride = yieldOverride
        }
    }

    /// Aggregates the selected recipes into a consolidated + per-recipe list (pure engine).
    func groceryList(for selections: [GrocerySelection]) -> GroceryAggregation.GroceryList {
        GroceryAggregation.build(from: selections.map { groceryRecipeSource(for: $0.recipe, yieldOverride: $0.yieldOverride) })
    }

    /// The share-sheet text for a set of selected recipes (Notes is the primary target — the share
    /// sheet IS the push-to-Notes mechanism; there is no public Notes-write API, §11.3).
    func groceryListText(for selections: [GrocerySelection], title: String = "Shopping list") -> String {
        GroceryAggregation.plainText(groceryList(for: selections), title: title)
    }

    /// Resolves the recipe ids planned across a set of day rows into `GrocerySelection`s, unioning both
    /// recipe stores exactly as the recipe-book UI does. A DANGLING id (recipe since deleted) resolves
    /// to nothing in either store and is dropped silently (§4.3). De-duplicates ids so a recipe planned
    /// on two days is aggregated once — the planner's job is the shopping list, not portion counting.
    func grocerySelections(forPlannedRecipeIDs ids: [UUID]) -> [GrocerySelection] {
        let byID = Dictionary(
            (recipes + savedRecipes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted, let recipe = byID[id] else { return nil }
            return GrocerySelection(recipe: recipe)
        }
    }

    private func groceryRecipeSource(for recipe: RecipeDefinition, yieldOverride: Int?) -> GroceryAggregation.RecipeSource {
        if recipe.isWebImport {
            // Web imports carry no structured ingredients (§4.2) and cannot be proportionally scaled —
            // their free-text lines pass through the shipped unifier unchanged, under a per-recipe
            // heading, until STEP 0 backfills structure.
            let lines = Self.recipeIngredientLines(recipe) ?? []
            return GroceryAggregation.RecipeSource(recipeName: recipe.name, freeTextLines: lines)
        }
        // Resolve foods once from the base recipe: scaling changes quantities, never `foodItemId`s.
        let foods = foodCatalog.items(forRecipe: recipe)
        let nameByID = Dictionary(foods.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let ingredients: [RecipeIngredient]
        if let yieldOverride, RecipeScaling.isScalable(recipe) {
            ingredients = RecipeScaling.scaledIngredients(recipe, forYield: yieldOverride)
        } else {
            ingredients = recipe.ingredients
        }
        let structured = ingredients.map { ing in
            GroceryAggregation.StructuredItem(
                foodItemId: ing.foodItemId,
                name: nameByID[ing.foodItemId] ?? "",
                quantity: ing.quantity,
                unit: ing.unit)
        }
        return GroceryAggregation.RecipeSource(recipeName: recipe.name, structured: structured)
    }
}
