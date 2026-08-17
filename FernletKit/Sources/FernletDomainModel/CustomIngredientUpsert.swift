import Foundation

/// Upsert logic turning manual recipe-ingredient inputs into catalog ``FoodItem``s and bound
/// ``RecipeIngredient``s.
///
/// `resolve` de-duplicates by normalized name against existing manual foods — preserving the stable
/// food id, previously scanned micronutrients, and a remembered barcode when the new save carries
/// none — while `recipeIngredients(from:...)` maps a whole editor form into bound ingredients,
/// creating any missing custom foods along the way. Pure value logic; the caller owns persistence.
public nonisolated struct CustomIngredientUpsert {
    public static func resolve(
        ingredient: ManualRecipeIngredientInput,
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> FoodItem {
        let servingUnit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? RecipeUnit.serving.rawValue : ingredient.unit
        let foodItem = FoodItem(
            name: ingredient.trimmedName,
            brandSource: "Custom ingredient",
            servingSize: max(ingredient.quantity, 0.01),
            servingUnit: servingUnit,
            macros: ingredient.macros,
            micronutrients: ingredient.scannedMicronutrients ?? Micronutrients(),
            category: "custom ingredient",
            source: .manual,
            lastVerified: verifiedAt,
            tags: ["recipe", "custom"],
            barcode: FoodBarcode.normalized(ingredient.barcode)
        )
        let normalizedName = FoodItemSearch.normalized(foodItem.name)
        if let existingIndex = foodItems.firstIndex(where: { existing in
            existing.source == .manual && FoodItemSearch.normalized(existing.name) == normalizedName
        }) {
            var updatedFoodItem = foodItem
            updatedFoodItem.id = foodItems[existingIndex].id
            // Preserve existing micronutrients when no fresh label scan was provided.
            if ingredient.scannedMicronutrients == nil {
                updatedFoodItem.micronutrients = foodItems[existingIndex].micronutrients
            }
            // Preserve a previously-remembered barcode when this save didn't come from a scan.
            if updatedFoodItem.barcode == nil {
                updatedFoodItem.barcode = foodItems[existingIndex].barcode
            }
            foodItems[existingIndex] = updatedFoodItem
            return updatedFoodItem
        }
        foodItems.append(foodItem)
        return foodItem
    }

    public static func recipeIngredients(
        from inputs: [ManualRecipeIngredientInput],
        selectionCatalog: [FoodItem]? = nil,
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> [RecipeIngredient] {
        // R5: this is USER input (an editor form whose rows may all be blank), not a programmer
        // invariant, so it gets a guard with an explicit recovery rather than a debug-only assert:
        // an all-blank form yields no ingredients and mints no food items. The caller already
        // refuses to save an empty recipe.
        let validIngredients = inputs.filter { !$0.trimmedName.isEmpty }
        guard !validIngredients.isEmpty else { return [] }
        let selectableFoodItems = selectionCatalog ?? foodItems
        var recipeIngredients: [RecipeIngredient] = []
        for ingredient in validIngredients {
            let foodItem = ingredient.selectedFoodItem(in: selectableFoodItems) ?? resolve(
                ingredient: ingredient,
                in: &foodItems,
                verifiedAt: verifiedAt
            )
            recipeIngredients.append(RecipeIngredient(
                foodItemId: foodItem.id,
                quantity: max(ingredient.quantity, 0.01),
                unit: ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "serving" : ingredient.unit
            ))
        }
        return recipeIngredients
    }
}
