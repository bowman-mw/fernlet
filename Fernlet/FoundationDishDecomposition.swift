import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - M1: AI dish decomposition model

enum FoundationDishDecompositionModel {
    /// Decomposes `payload.mealDescription` into primary components using on-device Foundation Models,
    /// resolves each component against the food catalog `index`, and returns a fully scaled `Meal`.
    /// Returns `nil` when the model is unavailable, the result fails plausibility checks, or
    /// no components can be resolved to catalog entries.
    static func decompose(_ payload: MealDecompositionPayload, index: FoodItemSearch.Index) async throws -> Meal? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard FoodSelectionAvailability.isFoundationModelAvailable else { return nil }
            Task {
                await AIAuditLog.shared.record(
                    payloadKind: payload.payloadKind,
                    destination: .onDeviceFoundationModels,
                    includedFields: payload.includedFieldNames
                )
            }
            let instructions = """
            You are a nutrition assistant. Break down meal descriptions into their primary edible components.
            For each component give: the ingredient (simple name, e.g. "salmon", "sushi rice", "avocado"), \
            the preparation state (raw, grilled, baked, fried, steamed, canned, or "none"), \
            and your best estimate of the edible grams of that component across the whole dish as described.
            Include implied staples: rice in a bowl, bread in a sandwich, tortilla in a taco, beans in a burrito.
            Honor explicit counts: "6 pieces nigiri" means roughly 6 × 35 g = 210 g across fish and rice components.
            Keep components to 2–6 primary ingredients only. Do not include sauces, condiments, or garnishes \
            unless they contribute meaningfully to macros (e.g. cheese, oil used for cooking).
            """
            let prompt = """
            Dish: \(payload.mealDescription)
            Preferred meal type: \(payload.fallbackMealType?.rawValue ?? "Auto")
            """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: FoundationDishDecomposition.self)
            return MealDecompositionResolver.meal(from: response.content, payload: payload, index: index)
        }
        #endif
        return nil
    }
}

// MARK: - @Generable schema

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
struct FoundationDishDecomposition {
    @Guide(description: "Short dish name, e.g. 'Salmon nigiri'")
    var name: String
    @Guide(description: "Meal type if clear from context, else 'Auto'")
    var mealType: String
    var components: [FoundationDishComponent]
}

@available(iOS 26.0, *)
@Generable
struct FoundationDishComponent {
    @Guide(description: "One primary edible ingredient, e.g. 'salmon', 'sushi rice', 'avocado'")
    var ingredient: String
    @Guide(description: "Preparation or state: raw, grilled, baked, fried, steamed, canned, or none")
    var preparation: String
    @Guide(description: "Best estimate of edible grams of THIS component for the whole dish as described")
    var grams: Double
}
#endif

// MARK: - Resolver

enum MealDecompositionResolver {
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func meal(
        from decomposition: FoundationDishDecomposition,
        payload: MealDecompositionPayload,
        index: FoodItemSearch.Index
    ) -> Meal? {
        let gramBounds = DishTemplateLexicon.componentGramBounds(description: payload.mealDescription)
        let resolvedIngredients: [(FoodSelectionIngredient, FoodItem)] = decomposition.components.compactMap { component in
            let ing = component.ingredient.trimmingCharacters(in: .whitespaces)
            guard !ing.isEmpty else { return nil }
            let prep = component.preparation.trimmingCharacters(in: .whitespaces)
            let query = (prep.isEmpty || prep.caseInsensitiveCompare("none") == .orderedSame)
                ? ing
                : "\(prep) \(ing)"
            guard let foodItem = FoodItemSearch.results(for: query, in: index, limit: 1).first else { return nil }
            let boundedGrams = boundedComponentGrams(component.grams, query: query, gramBounds: gramBounds)
            let clampedGrams = max(1, min(1500, boundedGrams))
            let ingredient = FoodSelectionIngredient(
                candidateId: 0,
                foodName: foodItem.name,
                quantity: clampedGrams,
                unit: RecipeUnit.gram.rawValue
            )
            return (ingredient, foodItem)
        }
        guard !resolvedIngredients.isEmpty else { return nil }

        // Sanity check: total caloric density must be plausible (0.3–9 kcal/g).
        let totalGrams = resolvedIngredients.reduce(0.0) { $0 + $1.0.quantity }
        let totalCalories = resolvedIngredients.reduce(0.0) { cal, pair in
            let ri = RecipeIngredient(foodItemId: pair.1.id, quantity: pair.0.quantity, unit: pair.0.unit)
            let m = ri.scaledMacros(using: pair.1)
            return cal + Double(m.protein * 4 + m.carbs * 4 + m.fat * 9)
        }
        let caloriesPerGram = totalCalories / max(totalGrams, 1)
        guard caloriesPerGram >= 0.3 && caloriesPerGram <= 9 else { return nil }

        let dishName = decomposition.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? MealParser.mealName(from: payload.mealDescription)
            : decomposition.name
        let mealType = MealType(rawValue: decomposition.mealType)
            ?? payload.fallbackMealType
            ?? MealParser.classifyMealType(payload.mealDescription)

        return MealBuilder.mealFromIngredients(
            itemName: dishName,
            resolvedIngredients: resolvedIngredients,
            mealType: mealType
        )
    }
    private static func boundedComponentGrams(
        _ grams: Double,
        query: String,
        gramBounds: [String: ClosedRange<Double>]
    ) -> Double {
        guard gramBounds.isEmpty == false else { return grams }
        let normalizedQuery = FoodItemSearch.normalized(query)
        let queryTokens = Set(normalizedQuery.split(separator: " ").map(String.init))
        let matchingBounds = gramBounds.compactMap { key, bounds -> ClosedRange<Double>? in
            if normalizedQuery == key || normalizedQuery.contains(key) || key.contains(normalizedQuery) {
                return bounds
            }
            let keyTokens = Set(key.split(separator: " ").map(String.init))
            return queryTokens.intersection(keyTokens).isEmpty ? nil : bounds
        }
        guard matchingBounds.isEmpty == false else { return grams }
        let lower = matchingBounds.map(\.lowerBound).min() ?? grams
        let upper = matchingBounds.map(\.upperBound).max() ?? grams
        return min(max(grams, lower), upper)
    }
    #endif
}
