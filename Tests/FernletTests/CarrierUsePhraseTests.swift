// CarrierUsePhraseTests.swift
// FernletTests
//
// Ingredient-search round F3 (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §4.2 cluster M,
// §8 F3): USDA names its plain vegetable oils "Oil, olive, salad or cooking", and the dish heuristic
// read that "salad" as a carrier — so every plain oil counted as a prepared dish and sank beneath
// branded bottles, mayonnaises and oil-roasted peanuts, in the typed list and in the resolver pool.
// A carrier inside a use phrase ("salad or cooking") no longer counts. The narrow sweets carriers the
// report suggested beside it (`waffle(s)`, `dough`) were measured and NOT added — see the note at
// `PreparedDishHeuristic.carrierTokens`.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

struct CarrierUsePhraseTests {
    static func food(_ name: String) -> FoodItem {
        FoodItem(name: name, servingSize: 100, servingUnit: "g", macros: Macros(protein: 0, carbs: 0, fat: 100),
                 micronutrients: Micronutrients(), category: "Fixtures", source: .usda, tags: [])
    }

    @Test func aSaladOrCookingOilIsNotADish() {
        #expect(!PreparedDishHeuristic.isPreparedDish(Self.food("Oil, olive, salad or cooking")))
        #expect(!PreparedDishHeuristic.isPreparedDish(Self.food("Oil, corn, industrial and retail, all purpose salad or cooking")))
        #expect(PreparedDishHeuristic.isPreparedDish(Self.food("Salad, chicken")), "a real salad is still a dish")
        #expect(PreparedDishHeuristic.isPreparedDish(Self.food("Chicken caesar salad, with oil")))
        #expect(PreparedDishHeuristic.isPreparedDish(Self.food("Chili hot dog on bun")), "other carriers are untouched")
    }

    /// No sweets word joined the carriers: a waffle or a dough stays an ingredient to the heuristic.
    @Test func waffleAndDoughAreNotCarriers() {
        #expect(!PreparedDishHeuristic.isPreparedDish(Self.food("Phyllo dough")))
        #expect(!PreparedDishHeuristic.isPreparedDish(Self.food("Waffles, plain, frozen, ready-to-heat")))
    }

    @Test func plainOilsSurfaceOnTheShippedCatalog() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        let olive = catalog.results(for: "olive oil", context: .userTyped).map(\.name)
        #expect(olive.contains("Oil, olive, salad or cooking"), "olive oil shows \(olive)")
        let peanut = catalog.results(for: "peanut oil", limit: 3, context: .userTyped).map(\.name)
        #expect(peanut.contains("Oil, peanut, salad or cooking"), "peanut oil shows \(peanut)")
        let pool = catalog.candidates(for: "olive oil").prefix(6).map(\.foodItem.name)
        #expect(pool.contains("Oil, olive, salad or cooking"), "the resolver pool for olive oil holds \(pool)")
    }
}
