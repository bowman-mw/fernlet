//
//  FoodSearchLabelAndFallbackTests.swift
//  FernletTests
//
//  Covers the Item 3 (Remaining-work doc) food slices implemented in this pass: per-row data-source
//  labels for ingredient search, and catalog-grounded micronutrient fallback so manually parsed
//  meals no longer log an empty micronutrient snapshot.
//

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

struct FoodSearchLabelAndFallbackTests {

    // MARK: - Data-source labels

    @Test func dataSourceLabelReflectsProvenance() {
        #expect(makeFood(source: .manual).dataSourceLabel == "Your foods")
        #expect(makeFood(source: .aiResolved).dataSourceLabel == "AI estimate")
        #expect(makeFood(source: .usda, dataType: .foundation).dataSourceLabel == "USDA")
        #expect(makeFood(source: .usda, dataType: .srLegacy).dataSourceLabel == "USDA")
        #expect(makeFood(source: .usda, dataType: .branded, brandSource: "Chobani").dataSourceLabel == "Chobani")
        #expect(makeFood(source: .usda, dataType: .branded, brandSource: nil).dataSourceLabel == "Branded")
        #expect(makeFood(source: .usda, dataType: .restaurant, brandSource: nil).dataSourceLabel == "Restaurant")
    }

    // MARK: - Fallback micronutrients

    @MainActor
    @Test func manuallyParsedMealBorrowsMicronutrientsFromCatalog() {
        let chicken = makeFood(
            name: "Chicken breast",
            source: .usda,
            dataType: .foundation,
            micronutrients: Micronutrients(vitaminB6: 0.9, niacin: 13, iron: 1.1, phosphorus: 210, potassium: 256)
        )
        let store = makeTestStore(bundledFoodItems: [chicken])

        let meal = store.addMeal(from: "chicken breast", type: MealType.lunch)
        #expect(meal.micronutrientSnapshot.hasAnyValue)
        #expect(store.day.meals.last?.micronutrientSnapshot.hasAnyValue == true)
    }

    @MainActor
    @Test func manuallyParsedMealWithoutCatalogMatchLeavesMicrosEmpty() {
        let store = makeTestStore() // empty in-memory catalog
        let meal = store.addMeal(from: "qwxz mystery dish", type: MealType.lunch)
        #expect(meal.micronutrientSnapshot.hasAnyValue == false)
    }

    @MainActor
    @Test func fallbackMicronutrientsHelperReturnsEmptyWhenUnmatched() {
        let store = makeTestStore()
        #expect(store.fallbackMicronutrients(for: "qwxz mystery dish").hasAnyValue == false)
    }

    // MARK: - FIX A: plural / inflected queries reach the singular canonical food

    // The scorer's token gate was one-directional prefix-only ("egg*" matches, "eggs*" doesn't), so a
    // plural query could never reach the singular canonical Foundation/legacy food. These exercise the
    // stem-normalized gate directly (pure `FoodItemSearch`, no DB needed).
    /// The stem invariant, asserted at the layer where it actually lives — the GATE.
    ///
    /// This test used to assert the whole thing end-to-end through `results`, on four synthetic rows
    /// whose scores nothing in the shipped catalog resembles: a singular name reached only through
    /// the stem earns no phrase bonus and no +60 (the coverage bonus requires token EQUALITY, §8's
    /// own defect list), so each fixture row scored −1 to −3, and the test was passing only because
    /// nothing yet refused a negative row. Read as a claim about search, it was measuring the absence
    /// of a floor rather than the presence of stemming.
    ///
    /// Research §26 fix 1.8 added that floor, so the two halves are now asserted separately and
    /// honestly: **retrieval** still reaches the singular canonical food for all four plurals (that
    /// is what `matchVariants` is for, and `ftsCandidatesReachSingularForPluralQuery` /
    /// `shippedCatalogReachesCanonicalEggForPluralQuery` prove it against real FTS), while
    /// **presentation** additionally requires a real name signal. On the shipped catalog the
    /// distinction costs nothing, because USDA names countable foods in the plural: `eggs` returns
    /// *Eggs, Grade A, Large, egg whole* at **807** — pinned in `FoodSearchCorpusTests.reviewBattery`
    /// — which the old fixture's −1 row could never have outranked anyway.
    @Test func pluralQueryReachesSingularCanonicalFood() {
        for (plural, singular) in [("eggs", "egg"), ("oats", "oat"), ("grapes", "grape"), ("berries", "berry")] {
            #expect(FoodItemSearch.matchVariants(for: plural).contains(singular),
                    "\(plural) must offer \(singular) as a match variant")
        }

        // End to end with CATALOG-REALISTIC names — how USDA actually spells these rows — so the
        // scores are plausible and the plural query reaches the canonical food through the scorer,
        // not merely through the gate.
        let egg   = makeFood(name: "Eggs, Grade A, Large, egg whole", source: .usda, dataType: .foundation)
        let oat   = makeFood(name: "Oats, rolled, dry",               source: .usda, dataType: .srLegacy)
        let grape = makeFood(name: "Grapes, red or green, raw",       source: .usda, dataType: .srLegacy)
        let berry = makeFood(name: "Berries, mixed, raw",             source: .usda, dataType: .srLegacy)
        let items = [egg, oat, grape, berry]
        #expect(FoodItemSearch.results(for: "eggs", in: items).contains { $0.name == egg.name })
        #expect(FoodItemSearch.results(for: "oats", in: items).contains { $0.name == oat.name })
        #expect(FoodItemSearch.results(for: "grapes", in: items).contains { $0.name == grape.name })
        #expect(FoodItemSearch.results(for: "berries", in: items).contains { $0.name == berry.name })

        // And the singular-named row a stem alone reaches: retrieved by the gate, not presented,
        // because it carries no name signal beyond the stem. This is the floor's cost, stated.
        let singularEgg = makeFood(name: "Egg, whole, raw, fresh", source: .usda, dataType: .foundation)
        let scored = FoodItemSearch.scoredResults(for: "eggs", in: FoodItemSearch.Index(foodItems: [singularEgg]), limit: 1)
        #expect(scored.isEmpty, "a stem-only match scores below the floor and is not presented")
    }

    // Singular queries must keep working unchanged (the gate already handled "egg" -> "eggs").
    @Test func singularQueryStillMatches() {
        let egg = makeFood(name: "Egg, whole, raw, fresh", source: .usda, dataType: .foundation)
        #expect(FoodItemSearch.results(for: "egg", in: [egg]).contains { $0.name == egg.name })
    }

    // Conservative: stemming must not broaden a plural query onto unrelated foods.
    @Test func pluralQueryDoesNotOverBroaden() {
        let cheese = makeFood(name: "Cheddar cheese", source: .usda, dataType: .srLegacy)
        #expect(FoodItemSearch.results(for: "eggs", in: [cheese]).isEmpty)
    }

    // The shared variant helper is the single source of truth that keeps the in-memory scorer gate and
    // the SQLite FTS match string in lockstep. Assert its exact output, including the guards.
    @Test func matchVariantsAreConservative() {
        #expect(FoodItemSearch.matchVariants(for: "eggs") == ["eggs", "egg"])
        #expect(FoodItemSearch.matchVariants(for: "oats") == ["oats", "oat"])
        #expect(FoodItemSearch.matchVariants(for: "grapes") == ["grapes", "grape"])
        #expect(FoodItemSearch.matchVariants(for: "berries") == ["berries", "berry"])
        #expect(FoodItemSearch.matchVariants(for: "egg") == ["egg"])     // singular: no stem
        #expect(FoodItemSearch.matchVariants(for: "gas") == ["gas"])     // < 4 chars: not stemmed
        #expect(FoodItemSearch.matchVariants(for: "grass") == ["grass"]) // -ss guard: not "gras"
    }

    // End-to-end through the real FTS5 index (built from in-memory items): the plural query "eggs" must
    // surface the singular "Egg, whole, raw, fresh" row via the `(eggs* OR egg*)` match, proving the
    // FTS string and the scorer gate stay in lockstep.
    @Test func ftsCandidatesReachSingularForPluralQuery() throws {
        let egg     = makeFood(name: "Egg, whole, raw, fresh", source: .usda, dataType: .foundation)
        let branded = makeFood(name: "Eggs Benedict Frozen Meal", source: .usda, dataType: .branded)
        let source  = try buildSQLiteSource([egg, branded])
        #expect(source.candidates(forQuery: "eggs").contains { $0.name == egg.name })
    }

    // MARK: - FIX B: broad-prefix truncation no longer drops the highest-priority rows

    // Against the full shipped catalog only (gated): a broad 3-char prefix ("chi") matches >10k rows,
    // and all `survey` (FNDDS) foods carry the highest food_ids. Before the ORDER BY the ascending-id
    // cap dropped 100% of them; now they survive so the scorer can see (and rank) them.
    @Test func shippedCatalogSurfacesSurveyRowsForBroadPrefix() {
        guard let source = SQLiteBundledFoodSource(), source.count > 50_000 else { return }
        #expect(source.candidates(forQuery: "chi").contains { $0.dataType == .survey })
    }

    // Against the full shipped catalog only (gated): plural "eggs" reaches the canonical singular egg.
    @Test func shippedCatalogReachesCanonicalEggForPluralQuery() {
        guard let source = SQLiteBundledFoodSource(), source.count > 50_000 else { return }
        #expect(source.candidates(forQuery: "eggs").contains { $0.name == "Egg, whole, raw, fresh" })
    }

    // MARK: - Helpers

    private func buildSQLiteSource(_ items: [FoodItem]) throws -> SQLiteBundledFoodSource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FoodCatalogDatabaseBuilder.build(items: items, to: url)
        return try #require(SQLiteBundledFoodSource(url: url))
    }

    private func makeFood(
        name: String = "Test food",
        source: FoodItemSource,
        dataType: FoodDataType = .srLegacy,
        brandSource: String? = nil,
        micronutrients: Micronutrients = Micronutrients()
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: brandSource,
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: 20, carbs: 0, fat: 3),
            micronutrients: micronutrients,
            category: "Protein",
            source: source,
            dataType: dataType,
            tags: []
        )
    }
}
