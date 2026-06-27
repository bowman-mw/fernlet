import Foundation

/// Read-side context the meal resolver needs from the app store. Mirrors the
/// `WorkoutSyncContext` host-protocol pattern so `MealResolutionService` depends on
/// this seam rather than the concrete `FernletStore` (plan §5d).
@MainActor
protocol MealResolutionContext: AnyObject {
    var settings: FernletSettings { get }
    var recipes: [RecipeDefinition] { get }
    var foodCatalog: FoodCatalog { get }
    var todayKey: String { get }
}

/// The quick-log meal resolution cascade (AI dish decomposition → candidate-
/// constrained AI selection → deterministic lexicon → deterministic plan →
/// keyword-heuristic fallback) plus the catalog-grounded micronutrient fallback,
/// extracted from `FernletStore` (plan §5d). Owns the FoundationModels meal
/// dependencies (`FoundationDishDecompositionModel`/`FoundationFoodSelectionModel`)
/// + `MealBuilder` + the `FoodCatalog` reads — keeping the AI providers off the
/// store/core path. Pure (no diary mutation); the store keeps the commit half.
@MainActor
final class MealResolutionService {
    private unowned let host: any MealResolutionContext

    init(host: any MealResolutionContext) {
        self.host = host
    }

    /// Best-effort micronutrient estimate for a manually-parsed meal, resolved from the food catalog
    /// so manual / heuristic-fallback meals no longer log an entirely empty micronutrient snapshot
    /// (Item 3). Returns empty `Micronutrients` when nothing usable matches — the gap is then left
    /// honest rather than fabricated. The estimate is the best catalog match's per-serving profile;
    /// macros on these meals are themselves estimates, so an unscaled nutrient profile is consistent.
    func fallbackMicronutrients(for description: String) -> Micronutrients {
        let normalizedName = FoodItemSearch.normalized(MealParser.mealName(from: description))
        if let exact = host.foodCatalog.exactNameMatch(forNormalized: normalizedName), exact.micronutrients.hasAnyValue {
            return exact.micronutrients
        }
        if let best = host.foodCatalog.results(for: description, limit: 1).first, best.micronutrients.hasAnyValue {
            return best.micronutrients
        }
        return Micronutrients()
    }

    /// Returns `meal` with a catalog-derived micronutrient snapshot filled in when it currently has
    /// none. Leaves meals that already carry micronutrients (catalog/AI-resolved) untouched.
    func enrichingFallbackMicronutrients(_ meal: Meal, description: String) -> Meal {
        guard meal.micronutrientSnapshot.hasAnyValue == false else { return meal }
        let micros = fallbackMicronutrients(for: description)
        guard micros.hasAnyValue else { return meal }
        var enriched = meal
        enriched.micronutrientSnapshot = micros
        return enriched
    }

    /// Runs the quick-log resolution cascade WITHOUT writing anything to the diary, returning the
    /// resolved meals plus a confidence. Separating resolve from commit lets the UI review a
    /// low-confidence / fabricated result before it counts toward the day's totals.
    func resolveMeals(from description: String, type: MealType? = nil, date: String? = nil) async -> MealResolution {
        let targetDate = date ?? host.todayKey
        assert(!targetDate.isEmpty, "meal date required")

        if host.settings.aiStatus != .off {
            // Primary (M1): model decomposes the dish from world knowledge, catalog supplies macros.
            do {
                if let resolved = try await FoundationDishDecompositionModel.decompose(
                    MealDecompositionPayload(mealDescription: description, fallbackMealType: type),
                    catalog: host.foodCatalog
                ) {
                    return MealResolution(meals: [resolved.meal], createdRecipes: [], confidence: resolved.confidence, isFallback: false)
                }
            } catch {}

            // Secondary AI: candidate-constrained selection (catalog-grounded, high confidence).
            let candidates = host.foodCatalog.candidates(for: description)
            do {
                if let plan = try await FoundationFoodSelectionModel.resolve(
                    FoodSelectionPayload(mealDescription: description, candidates: candidates, fallbackMealType: type)
                ), let resolution = highConfidenceResolution(from: plan, candidates: candidates, description: description) {
                    return resolution
                }
            } catch {}
        }

        // Deterministic tier 1 (M2): dish template lexicon — handles composite dishes when AI is off.
        if let lexiconMeals = DishTemplateLexicon.resolve(description: description, mealType: type, catalog: host.foodCatalog) {
            return MealResolution(meals: lexiconMeals, createdRecipes: [], confidence: .high, isFallback: false)
        }

        // Deterministic tier 2: candidate-constrained plan.
        let candidates = host.foodCatalog.candidates(for: description)
        if let plan = FoundationFoodSelectionModel.deterministicPlan(description: description, candidates: candidates, fallbackType: type),
           let resolution = highConfidenceResolution(from: plan, candidates: candidates, description: description) {
            return resolution
        }

        // Keyword-heuristic fallback: fabricated macros, no catalog grounding — always reviewed.
        // Still try to ground its micronutrients in the catalog so the snapshot isn't fully empty.
        let fallback = enrichingFallbackMicronutrients(MealParser.parse(description, fallbackType: type), description: description)
        return MealResolution(meals: [fallback], createdRecipes: [], confidence: .low, isFallback: true)
    }

    /// Builds a high-confidence resolution from a candidate-constrained selection plan, or `nil`
    /// when the plan yields no meals. Shared by the AI-secondary and deterministic tier-2 paths,
    /// which differ only in how they obtain `plan`.
    private func highConfidenceResolution(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        description: String
    ) -> MealResolution? {
        guard let result = MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: host.recipes,
            foodItems: candidates.map(\.foodItem) + host.foodCatalog.items(forRecipes: host.recipes),
            originalDescription: description
        ), result.meals.isEmpty == false else { return nil }
        return MealResolution(meals: result.meals, createdRecipes: result.createdRecipes, confidence: .high, isFallback: false)
    }
}
