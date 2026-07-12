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
    @Test func pluralQueryReachesSingularCanonicalFood() {
        let egg   = makeFood(name: "Egg, whole, raw, fresh", source: .usda, dataType: .foundation)
        let oat   = makeFood(name: "Oat, rolled, dry",       source: .usda, dataType: .srLegacy)
        let grape = makeFood(name: "Grape, red, raw",        source: .usda, dataType: .srLegacy)
        let berry = makeFood(name: "Berry medley, raw",      source: .usda, dataType: .srLegacy)
        let items = [egg, oat, grape, berry]

        #expect(FoodItemSearch.results(for: "eggs", in: items).contains { $0.name == egg.name })
        #expect(FoodItemSearch.results(for: "oats", in: items).contains { $0.name == oat.name })
        #expect(FoodItemSearch.results(for: "grapes", in: items).contains { $0.name == grape.name })
        #expect(FoodItemSearch.results(for: "berries", in: items).contains { $0.name == berry.name })
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
