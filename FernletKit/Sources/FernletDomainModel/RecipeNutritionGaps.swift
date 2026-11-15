// RecipeNutritionGaps.swift
// FernletDomainModel
//
// Recipe lines saved with no nutrition (owner decision 2026-11-15, AI recipe paste-and-parse): a
// pasted line nothing matched ("salt and pepper to taste", "1 cup dragonfruit sauce") saves as a
// custom ingredient with zero macros, and the recipe's totals say they are low until every such line
// has a food or its own macros. Counted from what is already stored — no new field travels.

import Foundation

extension FoodItem {
    /// The categories a recipe's own lines are saved under: an editor custom ingredient
    /// (``CustomIngredientUpsert``) and a line of a recipe shared in (paste text, nearby, Messages).
    static let recipeLineCategories: Set<String> = ["custom ingredient", "recipe ingredient"]

    /// A recipe's own line saved with no protein, carbs or fat (its typed tenths of a gram, so a
    /// 0.4 g line is not "none").
    public var isCustomIngredientWithoutNutrition: Bool {
        guard source == .manual, FoodItem.recipeLineCategories.contains(category) else { return false }
        let grams = exactMacros
        return grams.protein <= 0 && grams.carbs <= 0 && grams.fat <= 0
    }
}

public nonisolated enum RecipeNutritionGaps {
    /// Lines of `recipe` whose food is a custom ingredient with no nutrition. `foodItems` is the
    /// recipe's own foods (`FoodCatalog.items(forRecipe:)`).
    public static func linesWithoutNutrition(in recipe: RecipeDefinition, foodItems: [FoodItem]) -> Int {
        let empty = Set(foodItems.filter(\.isCustomIngredientWithoutNutrition).map(\.id))
        return recipe.ingredients.reduce(0) { count, line in count + (empty.contains(line.foodItemId) ? 1 : 0) }
    }

    /// Recipe-editor rows that would save that way: named, bound to no food, no macros typed.
    public static func rowsWithoutNutrition(_ rows: [ManualRecipeIngredientInput]) -> Int {
        rows.reduce(0) { count, row in
            let grams = row.preciseMacros
            let empty = !row.trimmedName.isEmpty && row.selectedFoodItemId == nil
                && grams.protein <= 0 && grams.carbs <= 0 && grams.fat <= 0
            return count + (empty ? 1 : 0)
        }
    }
}
