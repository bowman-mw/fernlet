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

/// The quick-log meal resolution cascade (cold whole-description catalog probe → AI dish
/// decomposition → candidate-constrained AI selection → deterministic lexicon → deterministic plan
/// → keyword-heuristic fallback) plus the catalog-grounded micronutrient fallback,
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
        if let best = host.foodCatalog.results(
            for: description, limit: 1, context: .machineGenerated
        ).first, best.micronutrients.hasAnyValue {
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

        // Whole-description short-circuit (research §26 item 1.12): this must run before either AI
        // or deterministic decomposition so a catalog row that confidently represents the typed
        // food and household portion is not split into fabricated ingredients.
        if let resolution = wholeDescriptionResolution(description, type: type) { return resolution }

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
                ), let resolution = builtResolution(
                    from: plan,
                    candidates: candidates,
                    confidence: Self.retrievalGatedConfidence(.high, for: plan, candidates: candidates)
                ) {
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
        // The confidence comes from how well the template's components actually bound to catalog rows
        // (research §26 fixes 1.1/1.2): this tier used to assert `.high` unconditionally, which is how
        // a three-ingredient pizza decomposition — one component bound at score 58 against a floor of
        // 250 — auto-committed with no review sheet.
        if let lexicon = DishTemplateLexicon.resolve(description: description, mealType: type, catalog: host.foodCatalog) {
            // The dropped components and unbuildable dishes ride out as `unmatchedItems` so the review
            // sheet's existing "Couldn't find" card names them: a burger whose patty bound to nothing
            // must not present as a two-row meal with 62% of its declared mass silently gone.
            let resolution = MealResolution(
                meals: lexicon.meals,
                createdRecipes: [],
                confidence: lexicon.confidence,
                isFallback: false,
                unmatchedItems: lexicon.unmatchedItems
            )
            return Self.plausibilityGated(Self.mergedIntoSingleMeal(resolution, description: description))
        }

        // Deterministic tier 2: candidate-constrained plan. Its confidence is DERIVED from the binds
        // (research §26 fix 1.8's ledger), not asserted: this rung is where everything the template
        // tier declines lands, so hardcoding `.high` here simply relocated the defect fixes 1.1/1.2
        // closed one rung down — "burger and fries" answered with a Burger King burger plus chili
        // fries at `.high` and `unmatchedItems == []`, more confident and less disclosed than the
        // partial the template tier would have produced.
        let candidates = host.foodCatalog.candidates(for: description)
        if let plan = FoundationFoodSelectionModel.deterministicPlan(description: description, candidates: candidates, fallbackType: type),
           let resolution = builtResolution(from: plan, candidates: candidates, confidence: Self.bindConfidence(for: plan, candidates: candidates)) {
            return Self.plausibilityGated(Self.mergedIntoSingleMeal(resolution, description: description))
        }

        // Keyword-heuristic fallback: fabricated macros, no catalog grounding — always reviewed.
        // Still try to ground its micronutrients in the catalog so the snapshot isn't fully empty.
        let fallback = enrichingFallbackMicronutrients(MealParser.parse(description, fallbackType: type), description: description)
        return MealResolution(meals: [fallback], createdRecipes: [], confidence: .low, isFallback: true)
    }

    private func wholeDescriptionResolution(_ description: String, type: MealType?) -> MealResolution? {
        guard let probe = WholeDescriptionFoodProbe.match(
            description: description, catalog: host.foodCatalog
        ), let resolution = Self.probeResolution(probe, description: description, type: type) else { return nil }
        return Self.plausibilityGated(resolution)
    }

    /// Builds the one-row whole-description result in the food's validated nutrition basis. A
    /// stripped brand is both surfaced and stamped `.low`; an unstripped high-floor match remains a
    /// normal catalog food match. Internal so focused tests can verify synthetic basis edge cases.
    static func probeResolution(
        _ probe: WholeDescriptionFoodProbe.Match,
        description: String,
        type: MealType?
    ) -> MealResolution? {
        let confidence: MealResolutionConfidence = probe.unmatchedItems.isEmpty ? .high : .low
        let ingredient = FoodSelectionIngredient(
            candidateId: 1,
            foodName: probe.item.name,
            quantity: probe.ingredientQuantity,
            unit: probe.ingredientUnit,
            bindScore: probe.score
        )
        guard let meal = MealBuilder.mealFromIngredients(
            itemName: description,
            resolvedIngredients: [(ingredient, probe.item)],
            mealType: type ?? MealParser.classifyMealType(description),
            confidenceToken: confidence.mealConfidence.token,
            source: MealLogSource.manual
        ) else { return nil }
        return MealResolution(
            meals: [meal],
            createdRecipes: [],
            confidence: confidence,
            isFallback: false,
            unmatchedItems: probe.unmatchedItems
        )
    }

    /// Builds a resolution from a candidate-constrained selection plan, or `nil` when the plan yields
    /// no meals. Shared by the AI-secondary and deterministic tier-2 paths, which differ in how they
    /// obtain `plan` AND in what `confidence` they can honestly claim.
    ///
    /// **`confidence` is a parameter, and that is the fix.** It was hardcoded `.high` here — for both
    /// callers — which is the same defect research §26 fix 1.1 closed one rung up in the template
    /// tier. The AI-selection caller still claims `.high` (a model that picked from a constrained
    /// candidate list is claiming the pick, and re-judging that claim is not this fix's business) —
    /// but since research §26 fix 1.10 that claim passes through
    /// ``retrievalGatedConfidence(_:for:candidates:)``, which caps it at `.low` when the pick is a row
    /// a CORRECTION promoted into the pool rather than one retrieval found. The deterministic caller
    /// passes ``bindConfidence(for:candidates:)``.
    private func builtResolution(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        confidence: MealResolutionConfidence
    ) -> MealResolution? {
        guard let result = MealBuilder.meals(
            from: plan,
            candidates: candidates,
            recipes: host.recipes,
            foodItems: candidates.map(\.foodItem) + host.foodCatalog.items(forRecipes: host.recipes)
        ), result.meals.isEmpty == false else { return nil }
        // The plan's unmatched split items ride along: `MealResolution.needsReview` treats partial
        // coverage as review-worthy, so a meal missing half of what was typed pauses instead of
        // committing at high confidence.
        return MealResolution(
            meals: result.meals,
            createdRecipes: result.createdRecipes,
            confidence: confidence,
            isFallback: false,
            unmatchedItems: plan.unmatchedItems
        )
    }

    /// The confidence a deterministic tier-2 plan's binds actually justify: `.high` only when every
    /// item bound at least one food AND every bound food cleared `FoodItemSearch.confidentBindScore`
    /// against the item it was bound for; `.low` otherwise.
    ///
    /// The same discipline `DishTemplateBindQuality` gives the template tier: `.high` only when every
    /// component bound, and every bind cleared the confident floor. `.medium` is deliberately never
    /// produced, for the reason `DishTemplateBindQuality.confidence` states — `needsReview` is
    /// `== .low`, so a `.medium` would still auto-commit and close nothing.
    ///
    /// **Scored against the WHOLE item name, not its sub-phrases.** `deterministicIngredients`
    /// admits a candidate on its best score over any sub-phrase of the item, which is right for
    /// admission (a composite item legitimately reaches its food through a shorter phrase) and far
    /// too generous for confidence: any row merely CONTAINING one typed word earns the +250 substring
    /// bonus for that one-word phrase, so every bind would look confident. Scoring the full item name
    /// asks the question confidence actually turns on — how well does this row match what was typed?
    ///
    /// **What this does NOT catch, measured:** `burger and fries` still resolves `.high`, because
    /// *Hamburger (Burger King)* and *Potato, french fries, with chili* each clear 250 on the whole
    /// item name via that same substring bonus. The remaining defect there is a bind that is
    /// confident and still the wrong VARIETY — the category `DishTemplateBindAuditTests`' header
    /// already names and `verdict` has no word for — not an unhonest confidence stamp.
    /// `planTierStillCommitsBurgerAndFriesAtHighConfidence` pins it.
    ///
    /// Caps a tier's claimed confidence at `.low` when the plan bound a food that never earned its
    /// place in the candidate pool by RETRIEVAL — the correction-memory gate on the AI-selection tier
    /// (research §26 fix 1.10, review finding M5).
    ///
    /// **Why the AI tier needs one and the deterministic tiers do not.** Both draw from
    /// `FoodCatalog.candidates(for:)`, and since fix 1.10 that pool can contain one row the user's own
    /// correction PROMOTED — placed at rank 1 by id, deliberately bypassing the FTS gate and the
    /// scorer's floors. The deterministic tier re-derives every bind from an alias-free index
    /// (`FoundationFoodSelectionModel.deterministicIngredients`) and re-scores it in
    /// ``bindConfidence(for:candidates:)``, so a promoted row that matches nothing typed can never
    /// bind, let alone bind confidently. The model tier had no such re-derivation: it saw the promoted
    /// row as candidate #1 of its prompt and `.high` was stamped unconditionally, so a stale or
    /// mistaken correction could auto-commit a meal with no review sheet — precisely the class of
    /// silent wrong answer fixes 1.1/1.2 closed one rung down.
    ///
    /// **Deliberately narrow.** It does not re-judge the model's pick (the doc on
    /// ``builtResolution(from:candidates:confidence:)`` explains why that is not this fix's business);
    /// it asks only whether the picked row could have been retrieved for that item at all — so it is
    /// **a no-op for any ingredient that clears the retrieval floor against the item it is bound to**.
    ///
    /// That is deliberately NOT the same as "a no-op on uncorrected devices", and the 2026-08-23
    /// review measured the difference: pool admission scores sub-phrases of the whole DESCRIPTION,
    /// while this scores sub-phrases of the SPLIT ITEM NAME the row was bound to, so a cross-item bind
    /// — a row admitted for "fries" and then bound to the "burger" item — demotes even with no
    /// correction in play. Measured at roughly 1 in 15 ordinary multi-item plans, and every demotion
    /// the review produced deserved a review sheet, so the asymmetry errs in the safe direction: the
    /// cost is a pause, never a silent commit.
    static func retrievalGatedConfidence(
        _ claimed: MealResolutionConfidence,
        for plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate]
    ) -> MealResolutionConfidence {
        let foodItems = candidates.map(\.foodItem)
        guard foodItems.isEmpty == false else { return claimed }
        // R2: bounded by the plan's split items, each carrying a bounded ingredient list.
        for item in plan.items {
            let scores = FoundationFoodSelectionModel.bestSubPhraseScores(for: item.name, foodItems: foodItems)
            for ingredient in item.ingredients {
                guard let bound = candidates.first(where: { $0.id == ingredient.candidateId }) else { continue }
                guard (scores[bound.foodItem.id] ?? Int.min) >= FoodItemSearch.minimumBindScore else { return .low }
            }
        }
        return claimed
    }

    /// Static/pure so `DishTemplateBindAuditTests` can exercise it without a host.
    static func bindConfidence(for plan: FoodSelectionPlan, candidates: [FoodSelectionCandidate]) -> MealResolutionConfidence {
        guard plan.items.isEmpty == false, plan.unmatchedItems.isEmpty else { return .low }
        let foodItems = candidates.map(\.foodItem)
        let index = FoodItemSearch.Index(foodItems: foodItems)
        // R2: bounded by the split items, each bound to at most one food by `deterministicIngredients`.
        for item in plan.items {
            guard item.ingredients.isEmpty == false else { return .low }
            let scores = Dictionary(
                FoodItemSearch.scoredResults(for: item.name, in: index, limit: foodItems.count)
                    .map { ($0.item.id, $0.score) },
                uniquingKeysWith: max
            )
            for ingredient in item.ingredients {
                guard let bound = candidates.first(where: { $0.id == ingredient.candidateId }),
                      let score = scores[bound.foodItem.id],
                      score >= FoodItemSearch.confidentBindScore else { return .low }
            }
        }
        return .high
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
            confidence: Self.pessimisticConfidenceToken(of: parts),
            note: "Logged as one meal from your description.",
            source: parts[0].source
        )
        return MealResolution(
            meals: [merged],
            createdRecipes: resolution.createdRecipes,
            confidence: resolution.confidence,
            isFallback: resolution.isFallback,
            suggestedRecipe: resolution.suggestedRecipe,
            unmatchedItems: resolution.unmatchedItems
        )
    }

    /// The stamp a merged meal carries: the least-confident of its parts when they are all
    /// *estimate-grade*, and otherwise the first part's stamp exactly as before.
    ///
    /// **What this fixes.** `parts[0].confidence` made the persisted stamp depend on WORD ORDER:
    /// "smoothie and taco" wrote `foodMatch` while "taco and smoothie" wrote `roughEstimate` for the
    /// identical food. Among the three estimate-grade stamps the resolver tiers produce — `foodMatch`
    /// (matched a catalog row), `estimated`, `roughEstimate` (a low-confidence guess) — there IS an
    /// ordering, stated in their own `label` comments, and a merged row can only honestly carry the
    /// weakest one. `MealConfidence(persistedToken:)` resolves the legacy English spellings, so an
    /// older part cannot dodge the fold.
    ///
    /// **What this deliberately does NOT decide.** ``MealConfidence`` is documented as "the provenance
    /// stamp on a logged meal — how this row got its numbers", and most of its cases (`recipe`,
    /// `savedProduct`, `scannedLabel`, `repeated`, `corrected`…) name a SOURCE, not a rung on a
    /// confidence ladder — that ladder is ``MealResolutionConfidence``. `MealBuilder.mealFromRecipe`
    /// stamps `recipe`, and those meals do reach this fold through `MealBuilder.meals(from:)` on both
    /// the AI-selection and deterministic tiers. Ranking `recipe` against `foodMatch` would be
    /// inventing an order the enum does not define, so any part carrying a stamp outside the
    /// estimate-grade set short-circuits to the pre-existing `parts[0]` behaviour: this function never
    /// relabels a recipe-backed merge, and never changes an answer this codebase gave before.
    /// `[recipe, roughEstimate]` therefore still stamps `recipe`, and `[foodMatch, recipe]` still
    /// depends on word order — an OPEN owner question, flagged rather than settled here.
    static func pessimisticConfidenceToken(of parts: [Meal]) -> String {
        guard let first = parts.first else { return MealConfidence.roughEstimate.token }
        let leastConfidentFirst: [MealConfidence] = [.roughEstimate, .estimated, .foodMatch]
        let stamps = parts.map { MealConfidence(persistedToken: $0.confidence) }
        guard stamps.allSatisfy({ stamp in stamp.map(leastConfidentFirst.contains) == true }) else {
            return first.confidence
        }
        for candidate in leastConfidentFirst where stamps.contains(candidate) {
            return candidate.token
        }
        return first.confidence
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
            suggestedRecipe: resolution.suggestedRecipe,
            unmatchedItems: resolution.unmatchedItems
        )
    }
}
