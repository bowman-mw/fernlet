import Foundation
import AIContext
import FoodCatalog

#if canImport(FoundationModels)
import FoundationModels
import FernletDomainModel
import FernletScoring
#endif

// MARK: - M1: AI dish decomposition model

enum FoundationDishDecompositionModel {
    /// Decomposes `payload.mealDescription` into primary components using on-device Foundation Models,
    /// resolves each component against the food catalog `index`, and returns a fully scaled `Meal`
    /// together with a confidence in how well it matches what was eaten.
    /// Returns `nil` when the model is unavailable, the result fails plausibility checks, or
    /// no components can be resolved to catalog entries.
    static func decompose(_ payload: MealDecompositionPayload, catalog: FoodCatalog) async throws -> ResolvedMeal? {
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
            You are a nutrition assistant. Break a meal description into the foods that were actually eaten.
            Return each food as ONE component with: the ingredient (a simple, common name, e.g. "egg", \
            "sushi rice", "avocado"), the preparation state (raw, grilled, baked, fried, steamed, canned, \
            or "none"), and your best estimate of the edible grams of that food across the whole dish.
            Treat a plainly named whole food as a SINGLE component — "2 eggs" is one "egg" component (~100 g), \
            NOT separate yolk and white. Only split a food into parts when the person explicitly names the part.
            Include implied staples: rice in a bowl, bread in a sandwich, tortilla in a taco, beans in a burrito.
            Honor explicit counts, including spelled-out numbers: "two eggs" ≈ 2 × 50 g = 100 g; \
            "6 pieces nigiri" ≈ 6 × 35 g across fish and rice.
            Keep to 2–6 primary ingredients. Skip sauces, condiments, and garnishes unless they add meaningful \
            macros (e.g. cheese, cooking oil).
            Do NOT invent specific ingredients for a vague description. If the dish is generic ("a healthy bowl", \
            "lunch", "leftovers"), return few low-confidence components or none rather than guessing a detailed recipe.
            For each component set confidence (high/medium/low) and whether the person explicitly stated it. \
            Set overallConfidence for how well the whole breakdown matches what was eaten.
            """
            let prompt = """
            Dish: \(payload.mealDescription)
            Preferred meal type: \(payload.fallbackMealType?.rawValue ?? "Auto")
            """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: FoundationDishDecomposition.self)
            return MealDecompositionResolver.resolve(from: response.content, payload: payload, catalog: catalog)
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
    @Guide(description: "Overall confidence the breakdown matches what was eaten: high, medium, or low")
    var overallConfidence: String
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
    @Guide(description: "How sure you are this exact ingredient is in the dish: high, medium, or low")
    var confidence: String
    @Guide(description: "True only if the person's text explicitly named this ingredient or its amount")
    var explicitlyStated: Bool
}
#endif

// MARK: - Resolver

enum MealDecompositionResolver {
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    static func resolve(
        from decomposition: FoundationDishDecomposition,
        payload: MealDecompositionPayload,
        catalog: FoodCatalog
    ) -> ResolvedMeal? {
        let gramBounds = DishTemplateLexicon.componentGramBounds(description: payload.mealDescription)
        var minBindScore = Int.max
        var droppedComponents = 0
        var weakComponents = 0

        var resolvedIngredients: [(FoodSelectionIngredient, FoodItem)] = []
        for component in decomposition.components {
            let ing = component.ingredient.trimmingCharacters(in: .whitespaces)
            guard !ing.isEmpty else { continue }
            let prep = component.preparation.trimmingCharacters(in: .whitespaces)
            let query = (prep.isEmpty || prep.caseInsensitiveCompare("none") == .orderedSame)
                ? ing
                : "\(prep) \(ing)"
            // Bind to the best catalog hit, but drop the component when even the top match is junk
            // (matched only via category/tags with no real name signal).
            guard let match = catalog.scoredResults(for: query, limit: 1).first,
                  match.score >= FoodItemSearch.minimumBindScore else {
                droppedComponents += 1
                continue
            }
            minBindScore = min(minBindScore, match.score)
            if match.score < FoodItemSearch.confidentBindScore { weakComponents += 1 }
            if MealResolutionConfidence.fromModelWord(component.confidence) == .low { weakComponents += 1 }
            let foodItem = match.item
            let boundedGrams = boundedComponentGrams(component.grams, query: query, gramBounds: gramBounds)
            let clampedGrams = max(1, min(1500, boundedGrams))
            let ingredient = FoodSelectionIngredient(
                candidateId: 0,
                foodName: foodItem.name,
                quantity: clampedGrams,
                unit: RecipeUnit.gram.rawValue
            )
            resolvedIngredients.append((ingredient, foodItem))
        }

        // Collapse components that bound to the same catalog item (defends against the model
        // emitting e.g. yolk + white + whole that all resolve to one egg row).
        let deduped = dedupedByFoodItem(resolvedIngredients)
        guard !deduped.isEmpty else { return nil }

        // Sanity check: total caloric density must be plausible (0.3–9 kcal/g).
        let totalGrams = deduped.reduce(0.0) { $0 + $1.0.quantity }
        let totalCalories = deduped.reduce(0.0) { cal, pair in
            let ri = RecipeIngredient(foodItemId: pair.1.id, quantity: pair.0.quantity, unit: pair.0.unit)
            let m = ri.scaledMacros(using: pair.1)
            return cal + Double(m.protein * 4 + m.carbs * 4 + m.fat * 9)
        }
        let caloriesPerGram = totalCalories / max(totalGrams, 1)
        guard caloriesPerGram >= 0.3 && caloriesPerGram <= 9 else { return nil }

        let confidence = resolutionConfidence(
            model: decomposition.overallConfidence,
            minBindScore: minBindScore == Int.max ? 0 : minBindScore,
            droppedComponents: droppedComponents,
            weakComponents: weakComponents
        )

        let dishName = decomposition.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? MealParser.mealName(from: payload.mealDescription)
            : decomposition.name
        let mealType = MealType(rawValue: decomposition.mealType)
            ?? payload.fallbackMealType
            ?? MealParser.classifyMealType(payload.mealDescription)

        let meal = MealBuilder.mealFromIngredients(
            itemName: dishName,
            resolvedIngredients: deduped,
            mealType: mealType,
            confidenceLabel: confidence.mealLabel
        )
        return ResolvedMeal(meal: meal, confidence: confidence)
    }

    /// Merges resolved components that point at the same catalog item, summing their grams.
    @available(iOS 26.0, *)
    private static func dedupedByFoodItem(
        _ pairs: [(FoodSelectionIngredient, FoodItem)]
    ) -> [(FoodSelectionIngredient, FoodItem)] {
        var order: [UUID] = []
        var merged: [UUID: (FoodSelectionIngredient, FoodItem)] = [:]
        for (ingredient, foodItem) in pairs {
            if let existing = merged[foodItem.id] {
                var combined = existing.0
                combined.quantity = min(1500, existing.0.quantity + ingredient.quantity)
                merged[foodItem.id] = (combined, existing.1)
            } else {
                merged[foodItem.id] = (ingredient, foodItem)
                order.append(foodItem.id)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Combines the model's self-reported confidence with how strongly each ingredient bound to the
    /// catalog and whether any components were dropped/weak, into a single resolution confidence.
    @available(iOS 26.0, *)
    private static func resolutionConfidence(
        model: String,
        minBindScore: Int,
        droppedComponents: Int,
        weakComponents: Int
    ) -> MealResolutionConfidence {
        let modelLevel = MealResolutionConfidence.fromModelWord(model)
        let bindLevel: MealResolutionConfidence
        if minBindScore >= FoodItemSearch.confidentBindScore { bindLevel = .high }
        else if minBindScore >= 60 { bindLevel = .medium }
        else { bindLevel = .low }
        var level = MealResolutionConfidence.combine(modelLevel, bindLevel)
        if droppedComponents > 0 || weakComponents > 0 { level = level.lowered }
        return level
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
