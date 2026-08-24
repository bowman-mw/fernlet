import Foundation

/// Upsert logic turning manual recipe-ingredient inputs into catalog ``FoodItem``s and bound
/// ``RecipeIngredient``s.
///
/// `resolve` de-duplicates by normalized name against existing manual foods — preserving the stable
/// food id, previously scanned micronutrients, and a remembered barcode when the new save carries
/// none — while `recipeIngredients(from:...)` maps a whole editor form into bound ingredients,
/// creating any missing custom foods along the way. Pure value logic; the caller owns persistence.
public nonisolated struct CustomIngredientUpsert {

    /// The plausibility + completeness report for one editor row, before it is saved (fix 1.14).
    ///
    /// Deliberately NOT wired into ``resolve(ingredient:in:verifiedAt:)``: the gate warns and routes
    /// to review, it never blocks or rewrites a save, so it is the presenting surface — not the
    /// upsert — that decides what to do with a finding. Call this, show what it found, and let the
    /// user save anyway if they want to.
    ///
    /// - Important: only the ARITHMETIC half of the gate runs here, and that is deliberate.
    ///   ``ManualRecipeIngredientInput`` stores protein/carbs/fat as non-optional `Int`, so by the
    ///   time a value arrives the absent-versus-zero distinction is already gone and all three
    ///   always read as *reported*; calories are never collected by this form at all; and
    ///   `quantity` is the RECIPE amount (defaulting to 1), not a nutrition-panel serving size.
    ///   Running the completeness half over that would report "calories missing" on every single
    ///   row — the same answer for every record, which is noise wearing a finding's clothes. So the
    ///   scope is ``NutritionCompletenessScope/notApplicable`` and an untouched row surfaces through
    ///   the all-zero rule instead. Any caller that still holds the optional-typed source of the
    ///   numbers (an OCR scan, a product record) should report from THAT — see
    ///   `NutritionLabelResult.plausibilityReport(foodName:)`, which keeps nil as nil and does run
    ///   completeness — and use this overload only for hand-typed rows.
    ///
    /// - Parameters:
    ///   - ingredient: the editor row about to be saved.
    ///   - declaredCalories: an independently declared energy value, when one exists (a scanned
    ///     panel, a product record). Pass nil for a hand-typed row: ``Macros/calories`` is derived
    ///     via 4/4/9, so feeding it back in would compare the identity with itself and always pass.
    public static func plausibility(
        of ingredient: ManualRecipeIngredientInput,
        declaredCalories: Double? = nil
    ) -> NutritionPlausibilityReport {
        let facts = NutritionFacts(
            macros: ingredient.macros,
            micronutrients: ingredient.scannedMicronutrients ?? Micronutrients(),
            declaredCalories: declaredCalories,
            hasServingSize: false
        )
        return NutritionPlausibility.report(
            for: facts,
            exemption: NutritionPlausibility.exemption(forFoodNamed: ingredient.trimmedName),
            completeness: .notApplicable
        )
    }

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
