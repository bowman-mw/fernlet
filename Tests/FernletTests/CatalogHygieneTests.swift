// CatalogHygieneTests.swift
// FernletTests
//
// F6 of Docs/Ingredient-Search-Deep-Research-2026-09-29.md — catalog hygiene done at load time,
// because the committed catalog binary is never regenerated:
//
//   (1) the 26 zero-energy SR Legacy foods the catalog build dropped (salt, baking soda, waters, teas)
//       served beside the file from `FoodCatalogSupplement.json` (`BundledFoodSupplement`), which
//       `Scripts/food-catalog/sr_zero_energy_supplement.py` regenerates by rule from USDA's SR
//       Legacy file;
//   (2) 763 branded products the source filed as SR Legacy retyped `branded` by category
//       (`BundledRowCorrection.retypingMisfiledBrandedProducts`);
//   (3) identical-name catalog rows collapsed to one in a TYPED search (`TypeaheadDuplicateCollapse`),
//       never touching a person's own rows.

import Foundation
import Testing
import FernletDomainModel
@testable import FoodCatalog

/// Pins F6's three load-time hygiene fixes, on shipped rows and on synthetic catalogs.
struct CatalogHygieneTests {
    /// "Salt, table", FDC 173468 — restored by the supplement.
    static let saltID = UUID(uuidString: "00000000-0000-5000-8000-000000173468")
    /// "Leavening agents, baking soda", FDC 175040 — restored by the supplement.
    static let bakingSodaID = UUID(uuidString: "00000000-0000-5000-8000-000000175040")
    /// "Beverages, water, tap, drinking", FDC 173647 — restored by the supplement.
    static let tapWaterID = UUID(uuidString: "00000000-0000-5000-8000-000000173647")
    /// "Annies Hmgrwn Org Cookie Bites Choc Chip", FDC 349170 — a branded product filed as SR Legacy.
    static let annieCookieBitesID = UUID(uuidString: "00000000-0000-5000-8000-000000349170")
    /// FDC 746761, a beef top round — a REAL generic in the same FDC-id range as the misfiled products.
    static let beefRoundID = UUID(uuidString: "00000000-0000-5000-8000-000000746761")

    static func shippedCatalog() throws -> FoodCatalog {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == FoodSearchCorpusTests.loadedRowCount, "the shipped catalog must be loaded")
        return catalog
    }

    /// The shipped row `id` names, required to resolve.
    static func shipped(_ catalog: FoodCatalog, _ id: UUID?) throws -> FoodItem {
        let id = try #require(id)
        return try #require(catalog.item(id: id), "shipped row \(id) must resolve")
    }

    static func food(
        _ name: String, _ size: Double = 100, _ unit: String = "g", _ macros: Macros = Macros(protein: 1, carbs: 1, fat: 1),
        source: FoodItemSource = .usda, type: FoodDataType = .branded
    ) -> FoodItem {
        FoodItem(name: name, servingSize: size, servingUnit: unit, macros: macros, micronutrients: Micronutrients(),
                 category: "Test", source: source, dataType: type, tags: [])
    }

    // MARK: - (1) The supplement

    /// The file carries the 26 zero-energy foods, all decoded as ordinary SR Legacy rows.
    @Test func supplementCarriesTheTwentySixZeroEnergyFoods() {
        let rows = BundledFoodSupplement.items()
        #expect(rows.count == FoodSearchCorpusTests.supplementRowCount)
        #expect(rows.allSatisfy { $0.id.uuidString.hasPrefix(BundledRowCorrection.compactSourceIDPrefix) })
        #expect(rows.allSatisfy { $0.dataType == .srLegacy && $0.macros == Macros(protein: 0, carbs: 0, fat: 0) })
        #expect(rows.allSatisfy { $0.brandSource?.hasPrefix("USDA FDC ") == true }, "provenance like every SR row")
        #expect(!rows.contains { $0.name.localizedCaseInsensitiveContains("distilled") },
                "the spirits stay out: their energy is alcohol, which Macros cannot carry")
    }

    /// Salt, baking soda and tap water resolve by id through the shipped catalog, with USDA's own
    /// portions and micronutrients, and are counted in `bundledCount`.
    @Test func restoredStaplesResolveThroughTheCatalog() throws {
        let catalog = try Self.shippedCatalog()
        let salt = try Self.shipped(catalog, Self.saltID)
        #expect(salt.name == "Salt, table" && salt.category == "Spices and Herbs")
        #expect(salt.micronutrients.sodium == 38_800)
        #expect(salt.portions.map(\.unit) == ["cup", "tsp", "tbsp", "dash"])
        #expect(RecipeIngredient(foodItemId: salt.id, quantity: 6, unit: "g").servingConversion(using: salt) != nil)
        let soda = try Self.shipped(catalog, Self.bakingSodaID)
        #expect(soda.name == "Leavening agents, baking soda")
        let water = try Self.shipped(catalog, Self.tapWaterID)
        #expect(water.name == "Beverages, water, tap, drinking")
        let ids = try [Self.saltID, Self.bakingSodaID, Self.tapWaterID].map { try #require($0) }
        #expect(Set(catalog.items(ids: ids).map(\.id)) == Set(ids), "a recipe holding them resolves in one batch")
    }

    /// The report's four GAP queries now reach a plain row in the editor's six.
    @Test func gapQueriesFindTheRestoredStaples() throws {
        let catalog = try Self.shippedCatalog()
        let expectations: [(query: String, name: String)] = [
            ("salt", "Salt, table"),
            ("baking soda", "Leavening agents, baking soda"),
            ("baking s", "Leavening agents, baking soda"),
            ("water", "Water, bottled, generic")
        ]
        for expectation in expectations {
            let visible = catalog.results(for: expectation.query, context: .userTyped).map(\.name)
            #expect(visible.contains(expectation.name), "\(expectation.query): \(visible)")
        }
    }

    /// The supplement does not make a word the catalog has never seen look real: the typed partial
    /// fallback still refuses to drop an unknown token.
    @Test func unknownWordsStillFindNothing() throws {
        let catalog = try Self.shippedCatalog()
        #expect(catalog.results(for: "salt zzznotfood", context: .userTyped).isEmpty)
        #expect(catalog.results(for: "zzznotfood", context: .userTyped).isEmpty)
    }

    /// The composite source on synthetic rows: gate, dedupe against the file, lookups, the bounded form.
    @Test func supplementedSourceMirrorsTheFTSGate() {
        let fileRow = Self.food("Salt, table", type: .srLegacy)
        let salt = fileRow
        let soda = Self.food("Leavening agents, baking soda", type: .srLegacy)
        var water = Self.food("Beverages, water, tap, drinking", type: .srLegacy)
        water.tags = ["beverages"]
        let source = SupplementedBundledFoodSource(
            primary: InMemoryBundledFoodSource([fileRow]), supplement: [salt, soda, water]
        )
        #expect(source.count == 3, "a supplement row the file already serves is dropped")
        #expect(source.candidates(forQuery: "baking soda", stripsStopwords: true).map(\.name).contains(soda.name))
        #expect(source.candidates(forQuery: "leaven", stripsStopwords: true).map(\.id) == [fileRow.id, soda.id])
        #expect(!source.candidates(forQuery: "soda pop", stripsStopwords: true).contains { $0.id == soda.id },
                "every token must match, as FTS's prefix-AND does")
        #expect(source.candidates(forQuery: "beverage", stripsStopwords: true).contains { $0.id == water.id },
                "category and tag words are indexed, as in FTS")
        #expect(source.candidates(forQuery: "sodas", stripsStopwords: true).contains { $0.id == soda.id },
                "a plural reaches the singular through matchVariants")
        #expect(source.candidates(forQuery: "baking soda", stripsStopwords: true, limit: 1).map(\.id) == [soda.id],
                "the bounded form puts supplement rows first")
        #expect(source.item(id: soda.id)?.name == soda.name)
        #expect(Set(source.items(ids: [fileRow.id, soda.id]).map(\.id)) == [fileRow.id, soda.id])
        #expect(source.exactMatch(normalizedName: FoodItemSearch.normalized(water.name))?.id == water.id)
    }

    // MARK: - (2) Misfiled branded products

    /// A packaged product the source filed as SR Legacy is branded now, and its per-100 g nutrients
    /// are rebased like every other compact-source branded row (F2).
    @Test func misfiledBrandedProductsAreRetyped() throws {
        let catalog = try Self.shippedCatalog()
        let bites = try Self.shipped(catalog, Self.annieCookieBitesID)
        #expect(bites.dataType == .branded)
        #expect(bites.servingSize == 100 && bites.portions.map(\.gramWeight) == [30])
        let beef = try Self.shipped(catalog, Self.beefRoundID)
        #expect(beef.dataType == .srLegacy, "a real generic in the same id range keeps its SR Legacy food group")
    }

    /// The guard: only a compact-source `srLegacy` row outside SR Legacy's food groups moves.
    @Test func onlyNonSRCategoriesAreRetyped() throws {
        func row(_ id: String, _ type: FoodDataType, _ category: String) throws -> FoodItem {
            FoodItem(id: try #require(UUID(uuidString: id)), name: "Row", servingSize: 100, servingUnit: "g",
                     macros: Macros(protein: 1, carbs: 1, fat: 1), micronutrients: Micronutrients(),
                     category: category, source: .usda, dataType: type, tags: [])
        }
        let compact = "00000000-0000-5000-8000-000000000002"
        #expect(BundledRowCorrection.corrected(try row(compact, .srLegacy, "Confectionery Products")).dataType == .branded)
        #expect(BundledRowCorrection.corrected(try row(compact, .srLegacy, "Sweets")).dataType == .srLegacy)
        #expect(BundledRowCorrection.corrected(try row(compact, .survey, "Confectionery Products")).dataType == .survey)
        let gtin = "88C4EB4B-4E4E-41FA-91A4-811533FD52C6"
        #expect(BundledRowCorrection.corrected(try row(gtin, .srLegacy, "Confectionery Products")).dataType == .srLegacy)
        #expect(BundledRowCorrection.srLegacyFoodGroups.count == 25)
    }

    // MARK: - (3) Identical-name collapse

    /// Three rows share a name: the typed list shows ONE, at the first one's rank, and it is the one
    /// whose nutrition can exist; the machine surfaces still see all three.
    @Test func typedSearchShowsOneRowPerName() throws {
        let broken = Self.food("Chocolate Chips, Chocolate", 15, "g", Macros(protein: 0, carbs: 67, fat: 27))
        let good = Self.food("Chocolate Chips, Chocolate", 15, "g", Macros(protein: 0, carbs: 10, fat: 4))
        let shouty = Self.food("CHOCOLATE CHIPS, CHOCOLATE", 15, "g", Macros(protein: 0, carbs: 60, fat: 30))
        let other = Self.food("Chocolate Chips, Semi-sweet", 15, "g", Macros(protein: 1, carbs: 10, fat: 4))
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([broken, good, shouty, other]))
        let machine = catalog.results(for: "chocolate chips", context: .machineGenerated)
        #expect(Set(machine.map(\.id)) == Set([broken.id, good.id, shouty.id, other.id]), "the machine surface sees every row")
        let groupRank = try #require(machine.firstIndex { $0.id != other.id })
        let otherRank = try #require(machine.firstIndex { $0.id == other.id })
        let typed = catalog.results(for: "chocolate chips", context: .userTyped)
        #expect(typed.map(\.id) == (groupRank < otherRank ? [good.id, other.id] : [other.id, good.id]),
                "one row for the name, at its first member's rank: \(typed.map(\.name))")
    }

    /// A person's own rows are never hidden and never hide: a user item and a logged catalog row
    /// both stay, even when a same-name twin is better.
    @Test func ownRowsAreNeverCollapsed() {
        let broken = Self.food("Chocolate Chips, Chocolate", 15, "g", Macros(protein: 0, carbs: 67, fat: 27))
        let good = Self.food("Chocolate Chips, Chocolate", 15, "g", Macros(protein: 0, carbs: 10, fat: 4))
        let mine = Self.food("Chocolate chips, chocolate", 15, "g", Macros(protein: 1, carbs: 9, fat: 5), source: .manual)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([broken, good]))
        catalog.setUserItems([mine])
        #expect(Set(catalog.results(for: "chocolate chips", context: .userTyped).map(\.id)) == [mine.id, good.id])
        catalog.setUserItems([])
        catalog.setSearchHistory(FoodSearchHistory(weights: [broken.id: 3_000]))
        let logged = catalog.results(for: "chocolate chips", context: .userTyped).map(\.id)
        #expect(logged.first == broken.id, "the row this person logged keeps its history rank")
        #expect(logged.contains(good.id), "and does not hide its twin either")
    }

    /// The rule that picks the row: plausible nutrition, then a tap default that converts, then more
    /// readable household portions; a tie keeps the higher-ranked row.
    @Test func collapseKeepsTheRowThatWorks() {
        var noConvert = Self.food("Garlic, raw")   // "1 cup" default, but two volume portions: no conversion
        noConvert.portions = [FoodPortion(amount: 1, unit: "cup", gramWeight: 136), FoodPortion(amount: 1, unit: "tsp", gramWeight: 2.8)]
        var converts = Self.food("Garlic, raw", 100, "g")
        converts.portions = [FoodPortion(amount: 1, unit: "RACC", gramWeight: 85)]
        var richer = Self.food("Garlic, raw", 100, "g")
        richer.portions = [FoodPortion(amount: 1, unit: "tsp", gramWeight: 2.8), FoodPortion(amount: 1, unit: "slice", gramWeight: 3)]
        #expect(TypeaheadDuplicateCollapse.collapsing([noConvert, converts], limit: 6) { _ in false }.map(\.id) == [converts.id])
        #expect(TypeaheadDuplicateCollapse.collapsing([converts, richer], limit: 6) { _ in false }.map(\.id) == [richer.id])
        #expect(TypeaheadDuplicateCollapse.collapsing([converts, converts], limit: 6) { _ in false }.count == 1)
        #expect(TypeaheadDuplicateCollapse.collapsing([converts], limit: 0) { _ in false }.isEmpty)
    }

    /// On the shipped catalog: "extra virgin olive oil" showed one product six times — every one of
    /// the 60 rows the scorer ranks for it is named exactly that — so the typed list is now that one
    /// product, once, while the resolver still sees the run. "chocolate chips" keeps a single
    /// "Chocolate Chips, Chocolate" (the report's three-row tie, §2.5).
    @Test func shippedDuplicateRunsCollapse() throws {
        let catalog = try Self.shippedCatalog()
        let typed = catalog.results(for: "extra virgin olive oil", context: .userTyped)
        #expect(typed.map(\.name) == ["Extra Virgin Olive Oil"])
        #expect(typed.first.map(TypeaheadDuplicateCollapse.isPlausible) == true)
        let machine = catalog.results(for: "extra virgin olive oil", context: .machineGenerated)
        #expect(machine.count == 6 && machine.allSatisfy { $0.name == "Extra Virgin Olive Oil" },
                "the resolver/import surface is untouched")
        let chips = catalog.results(for: "chocolate chips", limit: 60, context: .userTyped)
        #expect(chips.filter { $0.name == "Chocolate Chips, Chocolate" }.count == 1)
    }
}
