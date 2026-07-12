import Foundation
import AIContext
import FoodCatalog
import FernletDomainModel
import FernletScoring

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum FoodSelectionAvailability {
    public static var isFoundationModelAvailable: Bool {
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

public enum FoundationFoodSelectionModel {
    public static func resolve(_ payload: FoodSelectionPayload) async throws -> FoodSelectionPlan? {
        let description = payload.mealDescription
        let candidates = payload.candidates
        let fallbackType = payload.fallbackMealType
        guard candidates.isEmpty == false else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard FoodSelectionAvailability.isFoundationModelAvailable else { return nil }
            let auditKind = payload.payloadKind; let auditFields = payload.includedFieldNames
            Task { await AIAuditLog.shared.record(payloadKind: auditKind, destination: .onDeviceFoundationModels, includedFields: auditFields) }
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

    public static func deterministicPlan(description: String, candidates: [FoodSelectionCandidate], fallbackType: MealType?) -> FoodSelectionPlan? {
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
        let candidateLimit = CompositeFoodLexicon.isComposite(itemName) ? 3 : 1
        return itemCandidates.prefix(candidateLimit).compactMap { localCandidate in
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
        // A unit the person spelled out ("100 g", "2 cups", "3 slices") wins over the food's preferred
        // unit so their weight / volume / count is applied verbatim.
        if let explicitUnit = explicitUnit(in: itemName) {
            return explicitUnit
        }
        return foodItem.preferredRecipeUnit
    }

    private static func defaultQuantity(for foodItem: FoodItem, itemName: String, unit: RecipeUnit) -> Double {
        let normalizedItem = FoodItemSearch.normalized(itemName)
        let normalizedFood = FoodItemSearch.normalized(foodItem.name)
        let count = explicitCount(in: itemName)
        if normalizedItem.contains("sandwich") || normalizedItem.contains("grilled cheese") {
            if unit == .each || normalizedFood.contains("slice") || normalizedFood.contains("bread") || normalizedFood.contains("cheese") {
                return count ?? 2
            }
        }
        guard let count else {
            return foodItem.defaultRecipeQuantity(for: unit)
        }
        // An explicit unit ("100 g", "2 cups") or a count-like unit (each / serving) uses the number as
        // the quantity in that unit. But a bare count with a weight / volume unit ("2 eggs", whose
        // preferred unit is grams) is a number of *servings*, not a number of grams — applying it as
        // grams scales macros by count / servingSize (~0.04 for two eggs) and silently loses ~99% of
        // the calories, so scale the count up by one serving's worth in the resolved unit instead.
        if explicitUnit(in: itemName) != nil || unit == .each || unit == .serving {
            return count
        }
        return count * foodItem.defaultRecipeQuantity(for: unit)
    }

    private static func explicitCount(in itemName: String) -> Double? {
        FoodItemSearch.normalized(itemName)
            .split(separator: " ")
            .compactMap { Double($0) }
            .first
    }

    /// The first measurement unit the person spelled out ("100 g", "2 cups", "3 slices"), mapped to a
    /// `RecipeUnit`, or nil when the text carries no unit token (a bare count like "2 eggs", or no
    /// number at all). `piece` / `slice` map to `.each`; every other token defers to
    /// `RecipeUnit.normalized`.
    private static func explicitUnit(in itemName: String) -> RecipeUnit? {
        for token in FoodItemSearch.normalized(itemName).split(separator: " ") {
            let word = String(token)
            switch word {
            case "piece", "pieces", "slice", "slices":
                return .each
            default:
                if let unit = RecipeUnit.normalized(word) {
                    return unit
                }
            }
        }
        return nil
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
                let normalizedUnitStr = normalizedUnit(ingredient.unit, fallback: candidate.foodItem.preferredRecipeUnit.rawValue)
                let isWeightOrVolume = [RecipeUnit.gram.rawValue, RecipeUnit.milliliter.rawValue,
                                        RecipeUnit.ounce.rawValue, RecipeUnit.pound.rawValue,
                                        RecipeUnit.cup.rawValue].contains(normalizedUnitStr)
                let quantityCap = isWeightOrVolume ? 1500.0 : 20.0
                return FoodSelectionIngredient(
                    candidateId: candidate.id,
                    foodName: candidate.foodItem.name,
                    quantity: min(max(ingredient.quantity, 0.01), quantityCap),
                    unit: normalizedUnitStr
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
