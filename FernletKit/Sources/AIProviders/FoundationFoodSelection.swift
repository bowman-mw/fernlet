import Foundation
import AIContext
import FoodCatalog
import FernletDomainModel
import FernletScoring

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Namespace answering "can this device run the on-device Foundation model right now?".
///
/// App-side call sites (the launch prewarm in `LaunchPreparationService`, the workout-adjust
/// affordance in `MoveView`) consult ``isFoundationModelAvailable`` to show or hide AI affordances
/// before any payload is built. This is a raw capability probe only — actual dispatch decisions
/// (user intent, daily budget, one-call charge) go through `FernletAIGate`, which reads the same
/// signal via ``SystemLanguageModelCapabilityProvider``.
public enum FoodSelectionAvailability {
    /// `true` when the default `SystemLanguageModel` reports `.available` (iOS 26+ with
    /// FoundationModels importable); `false` on incapable hardware, with Apple Intelligence
    /// disabled, or on SDKs without the framework. Delegates to the canonical probe,
    /// `SystemLanguageModelCapabilityProvider.isOnDeviceModelAvailable`, which carries the
    /// `#if canImport` / `#available` guards.
    public static var isFoundationModelAvailable: Bool {
        SystemLanguageModelCapabilityProvider.isOnDeviceModelAvailable
    }
}

/// On-device AI stage for meal food selection: turns a free-text meal description ("grilled cheese
/// and tomato soup") into a structured `FoodSelectionPlan` bound to numbered catalog candidates.
///
/// The app's meal-resolution pipeline calls ``resolve(_:gate:)`` with a de-identified
/// `FoodSelectionPayload` (description + numbered `FoodSelectionCandidate` list built app-side).
/// The model contributes judgment only — how to split the meal and which candidate numbers fit —
/// and can never introduce a food: the `@Generable` response carries candidate NUMBERS, which
/// `FoundationMealSelection` re-binds to real catalog foods, dropping unknown numbers,
/// normalizing units, clamping quantities, and capping items/ingredients before anything persists.
///
/// Every model dispatch routes through `FernletAIGate` (standard tier, user-invoked) — capability
/// cap, sleepy/resting daily budget, exactly one call charged — and every outcome is recorded in
/// `AIAuditLog` with the payload kind and included field names, never the content. A `nil` result
/// (gate fallback, empty candidates, or an unusable response) tells the caller to run its
/// deterministic cascade; ``deterministicPlan(description:candidates:fallbackType:)`` is the
/// AI-free tier of the same contract. MainActor by the module's default isolation; the helpers are
/// pure functions. Errors thrown by the model session are audited and rethrown.
public enum FoundationFoodSelectionModel {
    /// Meal food-selection (`standard` tier, user-invoked). Routes through `gate` right before the
    /// model dispatch: the gate caps by device capability, applies the sleepy/resting budget, and
    /// charges exactly one call. A `nil` gate result (resting / incapable / off) returns `nil` so the
    /// caller's deterministic cascade takes over — the same signal the old availability guard gave.
    public static func resolve(_ payload: FoodSelectionPayload, gate: FernletAIGate) async throws -> FoodSelectionPlan? {
        let description = payload.mealDescription
        let candidates = payload.candidates
        let fallbackType = payload.fallbackMealType
        guard candidates.isEmpty == false else { return nil }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let destination = gate.dispatch(tier: .standard, userInvoked: true) else { return nil }
            let auditKind = payload.payloadKind; let auditFields = payload.includedFieldNames
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
            do {
                let response = try await session.respond(to: prompt, generating: FoundationMealSelection.self)
                let plan = response.content.plan(fallbackDescription: description, fallbackType: fallbackType, candidates: candidates)
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: plan == nil ? .fellBack : .succeeded
                )
                return plan
            } catch {
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: AIAuditOutcome.fromModelError(error)
                )
                throw error
            }
        }
        #endif

        return nil
    }

    /// The AI-free tier of meal selection: splits the description with `MealItemSplitter`, binds each
    /// split item to its single best catalog candidate, and assembles a plan — or `nil` when nothing
    /// binds, ending the cascade.
    ///
    /// Split items that bind to nothing are NOT silently dropped: they are carried out as
    /// ``FoodSelectionPlan/unmatchedItems`` so the caller can demote the resolution and the review
    /// sheet can name them ("2 eggs and toast" that matched only the toast).
    public static func deterministicPlan(description: String, candidates: [FoodSelectionCandidate], fallbackType: MealType?) -> FoodSelectionPlan? {
        var items: [FoodSelectionMealItem] = []
        var unmatched: [String] = []
        for itemName in MealItemSplitter.items(from: description) {
            let ingredients = deterministicIngredients(for: itemName, candidates: candidates)
            if ingredients.isEmpty {
                unmatched.append(itemName.capitalized)
            } else {
                items.append(FoodSelectionMealItem(name: itemName.capitalized, ingredients: ingredients))
            }
        }
        guard items.isEmpty == false else { return nil }
        return FoodSelectionPlan(
            mealName: MealParser.mealName(from: description),
            mealType: fallbackType ?? MealParser.classifyMealType(description),
            items: items,
            unmatchedItems: unmatched
        )
    }

    /// Resolves one split item to at most ONE catalog food (the bind-floor-clearing best), with a
    /// default unit and quantity — the deterministic counterpart of the model's per-item ingredient
    /// picks.
    private static func deterministicIngredients(for itemName: String, candidates: [FoodSelectionCandidate]) -> [FoodSelectionIngredient] {
        let foodItems = candidates.map(\.foodItem)
        // Pull a wider set (not just 4) so the candidate builder's prepared-dish demotion has a raw
        // ingredient to surface before we bind the single best food below — otherwise a top-4 that is
        // all FNDDS dishes leaves nothing to promote.
        let itemCandidates = FoodSelectionCandidateBuilder.candidates(
            for: itemName,
            foodItems: foodItems,
            limit: 12
        )
        // Bind-score floor: mirror the AI decompose path's `minimumBindScore` gate
        // (FoundationDishDecomposition) so a candidate that surfaced only via a category/tags match —
        // with no real name signal ("broccoli slaw" bound to "burger patties") — is dropped rather than
        // logged. With ~50k branded foods in the catalog these weak binds are common; without a floor
        // the deterministic tier commits them at high confidence.
        let cleared = candidatesClearingBindFloor(itemCandidates, itemName: itemName, foodItems: foodItems)
        // One food per split item. Taking the top 3 for any "composite"-looking token (e.g. "burger
        // patties") bound unrelated look-alikes — a branded "double hamburger on wheat bun, 2 large
        // patties" — into a bogus multi-ingredient recipe. Genuine composite DISHES are handled upstream
        // by DishTemplateLexicon with real components; this deterministic fallback resolves each split
        // item to its single best food, and the caller merges the items into one meal.
        let candidateLimit = 1
        return cleared.prefix(candidateLimit).compactMap { localCandidate in
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

    /// Keeps only the candidates that clear `FoodItemSearch.minimumBindScore`, preserving the builder's
    /// ordering. The builder surfaced each candidate through a sub-phrase of `itemName`
    /// (`FoodSelectionCandidateBuilder.searchPhrases`), so score each candidate against those same
    /// phrases and keep it iff its BEST phrase score clears the floor — a candidate that matched only
    /// via category/tags scores at or below the floor and is dropped, while legitimate multi-word /
    /// composite matches (found via a shorter sub-phrase) score well above it and survive.
    private static func candidatesClearingBindFloor(
        _ itemCandidates: [FoodSelectionCandidate],
        itemName: String,
        foodItems: [FoodItem]
    ) -> [FoodSelectionCandidate] {
        guard itemCandidates.isEmpty == false, foodItems.isEmpty == false else { return itemCandidates }
        let index = FoodItemSearch.Index(foodItems: foodItems)
        var bestScore: [UUID: Int] = [:]
        for phrase in FoodSelectionCandidateBuilder.searchPhrases(from: itemName) {
            // `stripsStopwords: false` — sub-phrases from `searchPhrases`, not a typed query.
            for scored in FoodItemSearch.scoredResults(for: phrase, in: index, limit: foodItems.count, stripsStopwords: false) {
                bestScore[scored.item.id] = max(bestScore[scored.item.id] ?? Int.min, scored.score)
            }
        }
        return itemCandidates.filter { (bestScore[$0.foodItem.id] ?? Int.min) >= FoodItemSearch.minimumBindScore }
    }

    /// Picks the unit for a deterministic bind: sandwich bread/cheese counts as `.each`, an explicit
    /// spelled-out unit wins, and otherwise the food's preferred recipe unit applies.
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

    /// Derives the quantity for a deterministic bind, treating a bare count with a weight/volume unit
    /// ("2 eggs" whose unit resolves to grams) as a count of SERVINGS — see the inline note on the
    /// ~99% calorie-undercount this prevents.
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

    /// The first bare number in the item text ("2 eggs" → 2), or `nil` when the person gave no count.
    private static func explicitCount(in itemName: String) -> Double? {
        FoodItemSearch.normalized(itemName)
            .split(separator: " ")
            .compactMap { LocaleTolerantNumber.double(from: String($0)) }
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
/// The `@Generable` response schema the Foundation model fills in for a meal selection: a meal name,
/// a meal-type string, and the selected items built from candidate numbers.
///
/// Guided generation guarantees shape, never validity — ``plan(fallbackDescription:fallbackType:candidates:)``
/// is the validation pass that stands between the raw response and a `FoodSelectionPlan`, so nothing
/// the model emitted reaches the caller unchecked.
@available(iOS 26.0, *)
@Generable
private struct FoundationMealSelection {
    var mealName: String
    var mealType: String
    var items: [FoundationMealItem]

    /// Binds the raw response to real catalog foods: unknown candidate numbers are dropped, units
    /// normalized (falling back to the food's preferred unit), quantities clamped (1500 for
    /// weight/volume units, 20 for counts), ingredients capped at 5 per item and items at 6, blank
    /// names defaulted. Returns `nil` when no item survives — the fell-back signal.
    func plan(fallbackDescription: String, fallbackType: MealType?, candidates: [FoodSelectionCandidate]) -> FoodSelectionPlan? {
        // Named, not dropped: an item whose every ingredient failed validation is food the user typed
        // that this plan does not carry, so it leaves as `unmatchedItems` (see the deterministic tier).
        var droppedItemNames: [String] = []
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
            let trimmedItemName = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validIngredients.isEmpty == false else {
                if !trimmedItemName.isEmpty { droppedItemNames.append(trimmedItemName) }
                return nil
            }
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
            items: Array(validItems.prefix(6)),
            unmatchedItems: droppedItemNames
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

/// One meal item in the model's `FoundationMealSelection` response — a display name plus its
/// candidate-number ingredient picks.
///
/// Purely a guided-generation shape; binding to real catalog foods (and every clamp/cap) happens in
/// `FoundationMealSelection.plan`.
@available(iOS 26.0, *)
@Generable
private struct FoundationMealItem {
    var name: String
    var ingredients: [FoundationMealIngredient]
}

/// One ingredient pick in the model's response: a number from the prompt's numbered candidate list
/// plus the model's quantity and unit strings.
///
/// The number is re-bound to a real `FoodSelectionCandidate` during validation; a pick whose number
/// matches no candidate is silently dropped, so the model cannot invent a food.
@available(iOS 26.0, *)
@Generable
private struct FoundationMealIngredient {
    var candidateNumber: Int
    var quantity: Double
    var unit: String
}
#endif
