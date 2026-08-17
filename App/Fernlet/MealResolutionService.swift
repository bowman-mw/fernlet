import Foundation
import AIContext
import AIProviders
import FernletDomainModel
import FernletFoundation
import FernletScoring
import FoodCatalog
import HealthKitGateway

/// Read-side context the meal resolver needs from the app store.
///
/// Mirrors the `WorkoutSyncContext` host-protocol pattern so ``MealResolutionService`` depends on
/// this seam rather than the concrete `FernletStore` (plan §5d) — tests drive the cascade with a fake
/// host. `FernletStore` is the production conformer.
@MainActor
protocol MealResolutionContext: AnyObject {
    var settings: FernletSettings { get }
    var recipes: [RecipeDefinition] { get }
    var foodCatalog: FoodCatalog { get }
    var todayKey: String { get }
    /// Routes the on-device meal-resolution model calls through the provider ladder (capability cap +
    /// device-local quota + audit). Rebuilt per read so a mid-session AI-toggle is reflected.
    var aiGate: FernletAIGate { get }
}

/// Ceilings above which a single quick-log is treated as an implausible resolution — almost always a
/// hallucinated multi-ingredient decomposition (the "2 burger patties" → 81,688 kcal bug) rather than
/// one real large meal.
///
/// Deliberately generous so a genuine big restaurant plate still passes. Shared by the decompose-tier
/// total guard (``MealDecompositionResolver``) and the resolution-level plausibility gate below so
/// both tiers agree on what "too big for one log" means.
enum MealPlausibility {
    /// A single quick-log whose meals sum past this many kcal is downgraded to review (gate) or
    /// rejected (decompose tier).
    static let maxSingleLogCalories = 4000
    /// A single AI decomposition summing past this many total grams (3 kg) is almost certainly bad.
    static let maxSingleLogGrams = 3000.0
}

/// The quick-log meal resolution cascade (AI dish decomposition → candidate-
/// constrained AI selection → deterministic lexicon → deterministic plan →
/// keyword-heuristic fallback) plus the catalog-grounded micronutrient fallback,
/// extracted from `FernletStore` (plan §5d).
///
/// Owns the FoundationModels meal dependencies
/// (``FoundationDishDecompositionModel``/`FoundationFoodSelectionModel`)
/// + ``MealBuilder`` + the `FoodCatalog` reads — keeping the AI providers off the
/// store/core path. Pure (no diary mutation); the store keeps the commit half.
/// `@MainActor`, holding its host `unowned` (the store owns the service). Every
/// multi-item resolution is folded to ONE meal, and every high-confidence result
/// passes the calorie plausibility gate before it may auto-commit.
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
    func resolveMeals(from rawDescription: String, type: MealType? = nil, date: String? = nil) async -> MealResolution {
        let targetDate = date ?? host.todayKey
        assert(!targetDate.isEmpty, "meal date required")
        // R5: an empty description has nothing to resolve — return the keyword fallback (always
        // reviewed) rather than dispatching, and charging, the AI gate on an empty prompt.
        guard rawDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            let empty = MealParser.parse(rawDescription, fallbackType: type)
            return MealResolution(meals: [empty], createdRecipes: [], confidence: .low, isFallback: true)
        }
        // Rewrite colloquial ingredient phrasing to the catalog's vocabulary before matching, so the
        // resolver binds the MEAT rather than an assembled fast-food dish ("burger patties" → "beef
        // patties", which the FNDDS "hamburger, on wheat bun" entries can't match).
        let description = Self.canonicalizedQuery(rawDescription)

        if host.settings.aiStatus != .off {
            // The two on-device meal-resolution model calls both route through the store's AI gate
            // (`standard` tier, user-invoked): the gate applies the sleepy/resting budget and charges
            // one call per model dispatch. The outer `.off` short-circuit is kept so an off user builds
            // no AI candidates at all — the gate would also fall back, but this avoids the work.
            let gate = host.aiGate
            // Primary (M1): model decomposes the dish from world knowledge, catalog supplies macros.
            do {
                if let resolved = try await FoundationDishDecompositionModel.decompose(
                    MealDecompositionPayload(mealDescription: description, fallbackMealType: type),
                    catalog: host.foodCatalog,
                    gate: gate
                ) {
                    return Self.plausibilityGated(MealResolution(meals: [resolved.meal], createdRecipes: [], confidence: resolved.confidence, isFallback: false, suggestedRecipe: resolved.suggestedRecipe))
                }
            } catch {
                // Recovery: the cascade continues to the next tier; name the fall-through so a model
                // failure is not indistinguishable from "the tier had nothing to say".
                FernletAuditLog.log(
                    "mealResolution.decomposeTier.failed",
                    context: ["error": error.localizedDescription]
                )
            }

            // Secondary AI: candidate-constrained selection (catalog-grounded, high confidence).
            let candidates = host.foodCatalog.candidates(for: description)
            do {
                if let plan = try await FoundationFoodSelectionModel.resolve(
                    FoodSelectionPayload(mealDescription: description, candidates: candidates, fallbackMealType: type),
                    gate: gate
                ), let resolution = highConfidenceResolution(from: plan, candidates: candidates) {
                    return Self.plausibilityGated(Self.mergedIntoSingleMeal(resolution, description: description))
                }
            } catch {
                // Recovery: fall through to the deterministic tiers below.
                FernletAuditLog.log(
                    "mealResolution.selectionTier.failed",
                    context: ["error": error.localizedDescription]
                )
            }
        }

        // Deterministic tier 1 (M2): dish template lexicon — handles composite dishes when AI is off.
        if let lexiconMeals = DishTemplateLexicon.resolve(description: description, mealType: type, catalog: host.foodCatalog) {
            let resolution = MealResolution(meals: lexiconMeals, createdRecipes: [], confidence: .high, isFallback: false)
            return Self.plausibilityGated(Self.mergedIntoSingleMeal(resolution, description: description))
        }

        // Deterministic tier 2: candidate-constrained plan.
        let candidates = host.foodCatalog.candidates(for: description)
        if let plan = FoundationFoodSelectionModel.deterministicPlan(description: description, candidates: candidates, fallbackType: type),
           let resolution = highConfidenceResolution(from: plan, candidates: candidates) {
            return Self.plausibilityGated(Self.mergedIntoSingleMeal(resolution, description: description))
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
        candidates: [FoodSelectionCandidate]
    ) -> MealResolution? {
        guard let result = MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: host.recipes,
            foodItems: candidates.map(\.foodItem) + host.foodCatalog.items(forRecipes: host.recipes)
        ), result.meals.isEmpty == false else { return nil }
        return MealResolution(meals: result.meals, createdRecipes: result.createdRecipes, confidence: .high, isFallback: false)
    }

    /// A single quick-log is ONE meal. The AI-selection, lexicon, and deterministic tiers each split a
    /// description into several plan items (e.g. "burger patties with cottage cheese and ketchup" → 3
    /// items) and `MealBuilder` turns each item into its OWN `Meal` — so one log fanned out into three
    /// separate diary entries. This folds a multi-meal resolution back into a single meal whose
    /// components are the UNION of the parts (macros + micronutrients summed). Single-meal resolutions
    /// (the AI decomposition tier and the keyword fallback) pass through unchanged. Static/pure so
    /// `MealBuilderTests` can exercise it directly.
    static func mergedIntoSingleMeal(_ resolution: MealResolution, description: String) -> MealResolution {
        guard resolution.meals.count > 1 else { return resolution }
        let parts = resolution.meals
        let components = parts.flatMap { $0.componentSnapshots }
        let macros = parts.reduce(Macros(protein: 0, carbs: 0, fat: 0)) { sum, meal in
            Macros(protein: sum.protein + meal.macros.protein,
                   carbs: sum.carbs + meal.macros.carbs,
                   fat: sum.fat + meal.macros.fat)
        }
        var micronutrients = Micronutrients()
        for meal in parts { micronutrients.add(meal.micronutrientSnapshot) }
        // Name from the food components when we have them (accurate), else from the raw description.
        let name = components.isEmpty
            ? MealParser.mealName(from: description)
            : components.prefix(3).map(\.name).joined(separator: ", ")
        let merged = Meal(
            name: name,
            mealType: parts[0].mealType,
            macros: macros,
            macroSnapshot: macros,
            micronutrientSnapshot: micronutrients,
            componentSnapshots: components,
            mealSource: .manual,
            isAIFallback: parts.contains { $0.isAIFallback },
            quality: macros.protein >= Macros.goodProteinThreshold ? .good : .ok,
            confidence: parts[0].confidence,
            note: "Logged as one meal from your description.",
            source: parts[0].source
        )
        return MealResolution(
            meals: [merged],
            createdRecipes: resolution.createdRecipes,
            confidence: resolution.confidence,
            isFallback: resolution.isFallback,
            suggestedRecipe: resolution.suggestedRecipe
        )
    }

    /// Rewrites colloquial ingredient phrasing to the catalog's vocabulary so the resolver matches the
    /// MEAT, not an assembled fast-food dish. The FNDDS `survey` set has entries like "Double hamburger,
    /// on wheat bun, 2 large patties" that outrank the plain `srLegacy` "Beef, ground, patty" — and since
    /// data-type is sorted ABOVE relevance score, no score bias can demote them. Rewriting "burger
    /// patty/patties" → "beef patty/patties" makes the query require the "beef" token, which the
    /// hamburger/bun entries lack, so the token gate excludes them. Only a STANDALONE "burger" (never
    /// "hamburger"/"cheeseburger") directly before "patty/patties" is rewritten, and non-beef patties
    /// (turkey/veggie/…) are left untouched. Internal/static so `MealBuilderTests` can exercise it.
    static func canonicalizedQuery(_ description: String) -> String {
        let lower = description.lowercased()
        guard lower.range(of: #"\bburger\s+patt(?:y|ies)\b"#, options: .regularExpression) != nil else {
            return description
        }
        let nonBeef = ["turkey", "chicken", "veggie", "vegan", "plant", "black bean", "impossible",
                       "beyond", "salmon", "tuna", "pork", "bison", "lentil", "quinoa", "fish", "mushroom"]
        if nonBeef.contains(where: lower.contains) { return description }
        return description.replacingOccurrences(
            of: #"\bburger(\s+patt(?:y|ies))"#,
            with: "beef$1",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Belt-and-suspenders plausibility gate applied to every high-confidence resolution before it can
    /// auto-commit — the one guard that catches EVERY tier, including the AI candidate-selection path.
    /// When a single quick-log's meals sum past `MealPlausibility.maxSingleLogCalories` the resolution
    /// is almost certainly wrong (a hallucinated multi-item decomposition — the "2 burger patties" →
    /// 81,688 kcal bug), so it is DOWNGRADED to `.low` rather than dropped: that flips `needsReview`
    /// on, pausing the flow at the pre-log review sheet instead of silently logging tens of thousands
    /// of calories. Already-low resolutions (e.g. the keyword fallback) pass through unchanged.
    /// Internal (not private) so `MealBuilderTests` can exercise it directly. Pure/static — no host state.
    static func plausibilityGated(_ resolution: MealResolution) -> MealResolution {
        guard resolution.confidence != .low else { return resolution }
        let totalCalories = resolution.meals.reduce(0) { $0 + $1.macros.calories }
        guard totalCalories > MealPlausibility.maxSingleLogCalories else { return resolution }
        return MealResolution(
            meals: resolution.meals,
            createdRecipes: resolution.createdRecipes,
            confidence: .low,
            isFallback: resolution.isFallback,
            suggestedRecipe: resolution.suggestedRecipe
        )
    }
}
