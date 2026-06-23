import Foundation

@MainActor
struct CustomIngredientUpsert {
    static func resolve(
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
            tags: ["recipe", "custom"]
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
            foodItems[existingIndex] = updatedFoodItem
            return updatedFoodItem
        }
        foodItems.append(foodItem)
        return foodItem
    }

    static func recipeIngredients(
        from inputs: [ManualRecipeIngredientInput],
        selectionCatalog: [FoodItem]? = nil,
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> [RecipeIngredient] {
        let validIngredients = inputs.filter { !$0.trimmedName.isEmpty }
        assert(!validIngredients.isEmpty, "recipe ingredients required")
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
