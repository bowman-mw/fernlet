import Testing
import Foundation
@testable import FernletDomainModel
import FernletScoring
import FoodCatalog

/// F2 suggestion feature (deterministic-only): the §3.5 dedup fix, the 7-vs-14-day
/// gating, the curated good-sources table (loads + every id resolves + copy safety),
/// and the suggestion/suppression behavior. The shared-DV-table reconciliation and its
/// pinned scoring/direction tests live in `FDADailyValuesTests`.
@MainActor
struct NutrientSuggestionTests {

    // MARK: - §3.5 dedup fix at the card

    @Test func dedupCollapsesSevenAndFourteenDayIntoOneEntry() {
        // The old card did a raw flatMap/filter/first, double-counting a nutrient present in
        // BOTH windows. The card now routes through this helper: one entry per key, the
        // longer window surviving when both are gaps.
        let both = [
            NutrientGap(nutrientKey: "iron", nutrientName: "Iron", unit: "mg", windowDays: 7, coverageRatio: 0.1, dataCoverageRatio: 1.0, status: .gap),
            NutrientGap(nutrientKey: "iron", nutrientName: "Iron", unit: "mg", windowDays: 14, coverageRatio: 0.1, dataCoverageRatio: 1.0, status: .gap)
        ]
        let deduped = FernletScoring.dedupedNutrientGaps(from: both)
        #expect(deduped.count == 1)
        #expect(deduped.first?.windowDays == 14)
    }

    // MARK: - 7-vs-14-day gating + suppression

    private func gap(_ key: String, window: Int) -> NutrientGap {
        NutrientGap(nutrientKey: key, nutrientName: key.capitalized, unit: "mg", windowDays: window, coverageRatio: 0.1, dataCoverageRatio: 1.0, status: .gap)
    }

    @Test func sevenDayGapShowsPassiveWithNoFood() throws {
        let sources = CuratedNutrientSources.bundled()
        let plan = try #require(NutrientNudgePlanner.plan(from: [gap("iron", window: 7)], sources: sources, isActive: { _ in true }))
        #expect(plan.namesFoods == false)
        #expect(plan.foods.isEmpty)
    }

    @Test func fourteenDayGapNamesCuratedFoods() throws {
        let sources = CuratedNutrientSources.bundled()
        // Both windows present (as they are in production) → dedup keeps the 14-day gap.
        let plan = try #require(NutrientNudgePlanner.plan(
            from: [gap("iron", window: 7), gap("iron", window: 14)],
            sources: sources,
            isActive: { _ in true }
        ))
        #expect(plan.namesFoods)
        // Deterministic table order: iron's first two curated foods.
        let expected = Array(sources.sources(for: "iron").prefix(2).map(\.displayName))
        #expect(plan.foods.map(\.displayName) == expected)
    }

    @Test func suppressedNutrientProducesNoPlan() {
        let sources = CuratedNutrientSources.bundled()
        let plan = NutrientNudgePlanner.plan(
            from: [gap("iron", window: 14)],
            sources: sources,
            isActive: { _ in false } // per-nutrient-key suppression active
        )
        #expect(plan == nil)
    }

    @Test func onlyGapStatusEligible() {
        let sources = CuratedNutrientSources.bundled()
        let covered = NutrientGap(nutrientKey: "iron", nutrientName: "Iron", unit: "mg", windowDays: 14, coverageRatio: 0.9, dataCoverageRatio: 1.0, status: .covered)
        #expect(NutrientNudgePlanner.plan(from: [covered], sources: sources, isActive: { _ in true }) == nil)
    }

    // MARK: - Curated table: loads, ~5 per nutrient, every id resolves

    @Test func curatedTableLoadsWithRoughlyFivePerNutrient() {
        let sources = CuratedNutrientSources.bundled()
        #expect(sources.all.isEmpty == false)
        for key in MicronutrientGapAnalyzer.trackedNutrients.map(\.key) {
            let count = sources.sources(for: key).count
            #expect(count >= 4 && count <= 6, "\(key) has \(count) curated sources")
        }
    }

    @Test func everyCuratedIdResolvesAgainstBundledCatalog() throws {
        let sources = CuratedNutrientSources.bundled()
        let catalog = FoodCatalog.bundled()
        #expect(catalog.bundledCount > 0)
        for source in sources.all {
            let resolvedById = catalog.item(id: source.foodItemId)
            #expect(resolvedById != nil, "id did not resolve: \(source.displayName) (\(source.foodItemId))")
            // The normalized-name fallback (regeneration safety net) also resolves.
            let resolvedByName = catalog.exactNameMatch(forNormalized: source.normalizedNameFallback)
            #expect(resolvedByName != nil, "fallback name did not resolve: \(source.normalizedNameFallback)")
        }
    }

    /// Every curated row's PINNED catalog `FoodItem` must actually carry a nonzero amount of the
    /// nutrient it is a "good source" for. Resolving-but-empty rows were the F2-review bug: three
    /// plant omega-3 rows (walnuts / chia / flaxseed) resolved fine yet carried no `omega3` in the
    /// catalog (the catalog tags only fish with the `omega3` key), so logging them would credit zero
    /// of the nutrient and then suppress the nudge for 14 days without moving the gap. This is also
    /// what makes the future AI stage — which selects among all five per nutrient — safe.
    @Test func everyCuratedRowsCatalogProfileCarriesItsNutrient() throws {
        let sources = CuratedNutrientSources.bundled()
        let catalog = FoodCatalog.bundled()
        for source in sources.all {
            let item = try #require(sources.resolve(source, in: catalog), "did not resolve: \(source.displayName)")
            let reference = try #require(
                MicronutrientGapAnalyzer.trackedNutrients.first { $0.key == source.nutrientKey },
                "unknown nutrientKey: \(source.nutrientKey)"
            )
            let amount = reference.value(item.micronutrients) ?? 0
            #expect(amount > 0, "\(source.displayName) carries no \(source.nutrientKey) in the catalog (amount \(amount))")
        }
    }

    /// The "Add it" affordance logs the TOP curated food (`suggestion.foods.first`) via
    /// `store.logNutrientSuggestionFood` → `diary.logNutrientSuggestionFoodItem`, which copies the
    /// resolved `FoodItem`'s micronutrient profile verbatim into the logged meal's snapshot. So the
    /// meal the accept path produces carries the nudged nutrient exactly when the resolved top food
    /// does. Guards the original review finding that the old free-text `addMeal(from:)` path bound an
    /// arbitrary branded row carrying none of the nutrient (e.g. potassium's "banana" → a branded
    /// banana row with zero potassium).
    @Test func acceptPathTopFoodCarriesTheNudgedNutrient() throws {
        let sources = CuratedNutrientSources.bundled()
        let catalog = FoodCatalog.bundled()
        for nutrient in MicronutrientGapAnalyzer.trackedNutrients {
            let top = try #require(sources.topSources(for: nutrient.key, count: 2).first, "no curated food for \(nutrient.key)")
            let logged = try #require(sources.resolve(top, in: catalog), "top food did not resolve: \(top.displayName)")
            // The meal snapshot the accept path writes IS `logged.micronutrients` (copied verbatim).
            let amount = nutrient.value(logged.micronutrients) ?? 0
            #expect(amount > 0, "accept-path meal for \(nutrient.key) (\(top.displayName)) carries no \(nutrient.key)")
        }
    }

    // MARK: - Copy safety (DiagnosticLanguage gate) + no cycle/period implication

    @Test func everyCuratedStringSurvivesTheDiagnosticGate() {
        let sources = CuratedNutrientSources.bundled()
        for source in sources.all {
            #expect(DiagnosticLanguage.contains(source.displayName) == false, "displayName flagged: \(source.displayName)")
            #expect(DiagnosticLanguage.contains(source.portionNote) == false, "portionNote flagged: \(source.portionNote)")
        }
    }

    @Test func generatedNudgeCopySurvivesTheDiagnosticGate() {
        let sources = CuratedNutrientSources.bundled()
        #expect(DiagnosticLanguage.contains(NutrientNudgeCopy.headline) == false)
        for nutrient in MicronutrientGapAnalyzer.trackedNutrients {
            let foods = sources.topSources(for: nutrient.key, count: 2)
            let passive = NutrientNudgeCopy.passive(nutrientName: nutrient.name)
            let suggestion = NutrientNudgeCopy.suggestion(nutrientName: nutrient.name, foods: foods)
            #expect(DiagnosticLanguage.contains(passive) == false, "passive copy flagged: \(passive)")
            #expect(DiagnosticLanguage.contains(suggestion) == false, "suggestion copy flagged: \(suggestion)")
            if let food = foods.first {
                #expect(DiagnosticLanguage.contains(NutrientNudgeCopy.addButtonLabel(food: food)) == false)
            }
        }
    }

    @Test func ironCopyNeverImpliesCycleAwareness() {
        // Iron needs vary with menstruation, but that signal is walled off (§3.4): the
        // nudge must not imply cycle/period awareness. The gate itself screens "cycle"/
        // "period", so this doubles as a regression guard on the iron copy specifically.
        let sources = CuratedNutrientSources.bundled()
        let ironCopy = NutrientNudgeCopy.suggestion(nutrientName: "Iron", foods: sources.topSources(for: "iron", count: 2))
        #expect(DiagnosticLanguage.contains(ironCopy) == false)
        let lowered = ironCopy.lowercased()
        #expect(lowered.contains("period") == false)
        #expect(lowered.contains("cycle") == false)
    }
}
