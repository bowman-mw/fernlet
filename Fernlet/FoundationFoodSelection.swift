import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum FoodSelectionAvailability {
    static var isFoundationModelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return true
            }
        }
        #endif
        return false
    }
}

enum FoundationFoodSelectionModel {
    static func resolve(description: String, candidates: [FoodSelectionCandidate], fallbackType: MealType?) async throws -> FoodSelectionPlan? {
        guard candidates.isEmpty == false else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard FoodSelectionAvailability.isFoundationModelAvailable else { return nil }
            let instructions = """
            First split a meal description into meal items, like "grilled cheese" and "tomato soup".
            Then turn each meal item into food selections from the numbered candidate list only.
            Use candidateNumber values from the list. Use quantity and unit from the person's text when clear.
            If an item is built from parts, include the parts. Example: grilled cheese on sourdough should include cheese and sourdough bread.
            If quantity is unclear, use 1 serving, except sandwiches usually use 2 bread slices and 2 cheese slices. Keep names short.
            """
            let prompt = """
            Meal: \(description)
            Preferred meal type: \(fallbackType?.rawValue ?? "Auto")

            Candidate foods:
            \(candidates.map(\.promptLine).joined(separator: "\n"))
            """
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, generating: FoundationMealSelection.self)
            return response.content.plan(fallbackDescription: description, fallbackType: fallbackType, candidates: candidates)
        }
        #endif

        return nil
    }

    static func deterministicPlan(description: String, candidates: [FoodSelectionCandidate], fallbackType: MealType?) -> FoodSelectionPlan? {
        let items = MealItemSplitter.items(from: description).compactMap { itemName -> FoodSelectionMealItem? in
            let ingredients = deterministicIngredients(for: itemName, candidates: candidates)
            guard ingredients.isEmpty == false else { return nil }
            return FoodSelectionMealItem(name: itemName.capitalized, ingredients: ingredients)
        }
        guard items.isEmpty == false else { return nil }
        return FoodSelectionPlan(
            mealName: MealParser.mealName(from: description),
            mealType: fallbackType ?? MealParser.classifyMealType(description),
            items: items
        )
    }

    private static func deterministicIngredients(for itemName: String, candidates: [FoodSelectionCandidate]) -> [FoodSelectionIngredient] {
        let itemCandidates = FoodSelectionCandidateBuilder.candidates(
            for: itemName,
            foodItems: candidates.map(\.foodItem),
            limit: 4
        )
        return itemCandidates.prefix(3).compactMap { localCandidate in
            guard let candidate = candidates.first(where: { $0.foodItem.id == localCandidate.foodItem.id }) else { return nil }
            let unit = defaultUnit(for: candidate.foodItem, itemName: itemName)
            let quantity = defaultQuantity(for: candidate.foodItem, itemName: itemName, unit: unit)
            return FoodSelectionIngredient(
                candidateId: candidate.id,
                foodName: candidate.foodItem.name,
                quantity: quantity,
                unit: unit.rawValue
            )
        }
    }

    private static func defaultUnit(for foodItem: FoodItem, itemName: String) -> RecipeUnit {
        let normalizedItem = FoodItemSearch.normalized(itemName)
        let normalizedFood = FoodItemSearch.normalized(foodItem.name)
        if normalizedItem.contains("sandwich") || normalizedItem.contains("grilled cheese") {
            if normalizedFood.contains("slice") || normalizedFood.contains("bread") || normalizedFood.contains("cheese") {
                return .each
            }
        }
        return foodItem.preferredRecipeUnit
    }

    private static func defaultQuantity(for foodItem: FoodItem, itemName: String, unit: RecipeUnit) -> Double {
        let normalizedItem = FoodItemSearch.normalized(itemName)
        let normalizedFood = FoodItemSearch.normalized(foodItem.name)
        if normalizedItem.contains("sandwich") || normalizedItem.contains("grilled cheese") {
            if unit == .each || normalizedFood.contains("slice") || normalizedFood.contains("bread") || normalizedFood.contains("cheese") {
                return 2
            }
        }
        return foodItem.defaultRecipeQuantity(for: unit)
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
private struct FoundationMealSelection {
    var mealName: String
    var mealType: String
    var items: [FoundationMealItem]

    func plan(fallbackDescription: String, fallbackType: MealType?, candidates: [FoodSelectionCandidate]) -> FoodSelectionPlan? {
        let validItems = items.compactMap { item -> FoodSelectionMealItem? in
            let validIngredients = item.ingredients.compactMap { ingredient -> FoodSelectionIngredient? in
                guard let candidate = candidates.first(where: { $0.id == ingredient.candidateNumber }) else { return nil }
                return FoodSelectionIngredient(
                    candidateId: candidate.id,
                    foodName: candidate.foodItem.name,
                    quantity: max(ingredient.quantity, 0.01),
                    unit: normalizedUnit(ingredient.unit, fallback: candidate.foodItem.preferredRecipeUnit.rawValue)
                )
            }
            guard validIngredients.isEmpty == false else { return nil }
            let trimmedItemName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return FoodSelectionMealItem(
                name: trimmedItemName.isEmpty ? "Meal item" : trimmedItemName,
                ingredients: Array(validIngredients.prefix(5))
            )
        }
        guard validItems.isEmpty == false else { return nil }

        let trimmedName = mealName.trimmingCharacters(in: .whitespacesAndNewlines)
        return FoodSelectionPlan(
            mealName: trimmedName.isEmpty ? MealParser.mealName(from: fallbackDescription) : trimmedName,
            mealType: MealType(rawValue: mealType) ?? fallbackType ?? MealParser.classifyMealType(fallbackDescription),
            items: Array(validItems.prefix(6))
        )
    }

    private func normalizedUnit(_ unit: String, fallback: String) -> String {
        let normalized = FoodItemSearch.normalized(unit)
        switch normalized {
        case "g", "gram", "grams":
            return RecipeUnit.gram.rawValue
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres":
            return RecipeUnit.milliliter.rawValue
        case "oz", "ounce", "ounces":
            return RecipeUnit.ounce.rawValue
        case "lb", "lbs", "pound", "pounds":
            return RecipeUnit.pound.rawValue
        case "cup", "cups":
            return RecipeUnit.cup.rawValue
        case "tbsp", "tablespoon", "tablespoons":
            return RecipeUnit.tablespoon.rawValue
        case "tsp", "teaspoon", "teaspoons":
            return RecipeUnit.teaspoon.rawValue
        case "each", "unit", "units", "item", "items":
            return RecipeUnit.each.rawValue
        case "serving", "servings":
            return RecipeUnit.serving.rawValue
        default:
            return fallback
        }
    }
}

@available(iOS 26.0, *)
@Generable
private struct FoundationMealItem {
    var name: String
    var ingredients: [FoundationMealIngredient]
}

@available(iOS 26.0, *)
@Generable
private struct FoundationMealIngredient {
    var candidateNumber: Int
    var quantity: Double
    var unit: String
}
#endif
