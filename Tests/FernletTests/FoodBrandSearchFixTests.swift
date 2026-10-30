import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

/// The 2026-10-29 targeted brand-search fixes (Docs/Food-Search-Phase0-Baseline-2026-10-29.md): the
/// brand field is searched when the full gate finds nothing, rows agreeing with a typed brand rank first
/// (above history), and a misspelling gets an offered, never applied, suggestion. Every fix is the TYPED
/// surface's alone, so each case also pins that the machine path did not move.
///
/// Deterministic in-memory rows for the rules; two cases at the end read the shipped base catalog.
@Suite
struct FoodBrandSearchFixTests {

    static func food(_ name: String, brand: String? = nil, dataType: FoodDataType = .branded) -> FoodItem {
        var item = FoodItem(
            name: name,
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 10, fat: 2),
            micronutrients: Micronutrients(),
            category: "Fixtures",
            source: .usda,
            dataType: dataType,
            tags: []
        )
        item.brandSource = brand
        return item
    }

    // MARK: Brand field

    @Test func brandStoredOnlyInTheBrandFieldIsFoundEitherWordOrder() {
        let quest = Self.food("Protein Bar, Cookies & Cream", brand: "Quest Nutrition, LLC")
        let other = Self.food("Formulated Bar, protein bar", brand: "USDA", dataType: .srLegacy)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([other, quest]))
        #expect(catalog.results(for: "quest protein bar", context: .userTyped).first?.id == quest.id)
        #expect(catalog.results(for: "protein bar quest", context: .userTyped).first?.id == quest.id)
    }

    @Test func brandFieldRouteNeverReachesTheMachinePath() {
        let quest = Self.food("Protein Bar, Cookies & Cream", brand: "Quest Nutrition, LLC")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([quest]))
        #expect(catalog.results(for: "quest protein bar", context: .machineGenerated).isEmpty)
        #expect(catalog.scoredResults(for: "quest protein bar").isEmpty)
    }

    @Test func brandFieldRouteNeedsABrandWordStartNotAnInnerMatch() {
        let tequesta = Self.food("Protein Bar, Vanilla", brand: "Tequesta Foods")
        let source = InMemoryBundledFoodSource([tequesta])
        #expect(source.brandFieldCandidates(brandWord: "quest", productQuery: "protein bar", stripsStopwords: true, limit: 10).isEmpty)
    }

    @Test func aReferenceRowAgreesThroughItsNameAnotherBrandsRowDoesNot() {
        let reference = FoodBrandAgreement.Row(
            normalizedName: FoodItemSearch.normalized("CAMPBELL'S, Chicken Noodle Soup, condensed"),
            normalizedBrand: FoodItemSearch.normalized("USDA FDC 171148"))
        #expect(FoodBrandAgreement.carries(["campbells"], reference))
        let flavour = FoodBrandAgreement.Row(
            normalizedName: FoodItemSearch.normalized("Potato Chips, Heinz Ketchup"),
            normalizedBrand: FoodItemSearch.normalized("Herr Foods Inc."))
        #expect(!FoodBrandAgreement.carries(["heinz"], flavour))
    }

    @Test func theLastWordIsTheFoodNotABrand() {
        let rows = [
            Self.food("Chicken Noodle Soup", brand: "Campbell Soup Company"),
            Self.food("Chicken Noodle Soup, Homestyle", brand: "Campbell Soup Company"),
            Self.food("CAMPBELL'S, Chicken Noodle Soup, condensed", brand: "USDA FDC 171148", dataType: .srLegacy)
        ]
        let index = FoodItemSearch.Index(foodItems: rows)
        #expect(FoodItemSearch.results(for: "chicken noodle soup", in: index, brandAware: true).map(\.id)
                == FoodItemSearch.results(for: "chicken noodle soup", in: index, brandAware: false).map(\.id))
    }

    // MARK: Typed brand first

    @Test func aRowWhoseBrandFieldSaysTheTypedBrandOutranksAFlavourNamingIt() {
        let chips = Self.food("Potato Chips, Heinz Ketchup", brand: "Herr Foods Inc.")
        let ketchup = Self.food("Heinz, Tomato Ketchup", brand: "Kraft Heinz Foods Company")
        let squeeze = Self.food("Tomato Ketchup, Heinz, Squeeze", brand: "Kraft Heinz Foods Company")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([chips, ketchup, squeeze]))
        let shown = catalog.results(for: "heinz ketchup", context: .userTyped)
        #expect(shown.prefix(2).allSatisfy { $0.brandSource == "Kraft Heinz Foods Company" })
        #expect(shown.last?.id == chips.id, "the flavour row stays, below the brand's own")
    }

    @Test func aNamedChainOutranksAnotherBrandsLookalike() {
        let real = Self.food("CHICK-FIL-A, chicken sandwich", brand: "USDA", dataType: .srLegacy)
        let lookalike = Self.food("Breaded Chicken Breast Fillet Sandwich, Chick'n", brand: "Wal-Mart Stores, Inc.")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([lookalike, real]))
        #expect(catalog.results(for: "chick-fil-a sandwich", context: .userTyped).first?.id == real.id)
    }

    @Test func historyCannotPutAnotherBrandAboveTheTypedOne() {
        let kind = Self.food("Kind, Bar, Peanut Butter", brand: "KIND Inc.")
        let kindToo = Self.food("Kind Bar, Almond", brand: "KIND Inc.")
        let kinder = Self.food("Kinder Bueno Bar", brand: "Ferrero")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([kind, kindToo, kinder]))
        catalog.setSearchHistory(FoodSearchHistory(weights: [kinder.id: 5_000]))
        let shown = catalog.results(for: "kind bar", context: .userTyped)
        #expect(shown.first?.brandSource == "KIND Inc.")
        #expect(shown.contains { $0.id == kinder.id }, "history still keeps the logged bar in the list")
    }

    @Test func aGenericWordInAFewBrandNamesIsNotABrand() {
        var rows = (1...10).map { Self.food("Olive Oil, Extra Virgin \($0)", brand: "Store Brand \($0)") }
        rows.append(Self.food("Olive Oil, Light", brand: "California Olive Ranch"))
        rows.append(Self.food("Oil, olive, salad or cooking", brand: "USDA", dataType: .srLegacy))
        let index = FoodItemSearch.Index(foodItems: rows)
        #expect(FoodItemSearch.results(for: "olive oil", in: index, limit: 12, brandAware: true).map(\.id)
                == FoodItemSearch.results(for: "olive oil", in: index, limit: 12, brandAware: false).map(\.id))
    }

    @Test func oneWordQueriesNeverSplitIntoBrandAndProduct() {
        #expect(FoodBrandAgreement.splits(of: ["chobani"]).isEmpty)
        let splits = FoodBrandAgreement.splits(of: ["quest", "protein", "bar"])
        #expect(splits.first?.brand == ["quest"])
        #expect(splits.first?.product == ["protein", "bar"])
        #expect(splits.count == 4)
    }

    // MARK: Spelling suggestion

    static let vocabulary = FoodSearchVocabulary(terms: [
        FoodSearchTerm(term: "chobani", documents: 19), FoodSearchTerm(term: "yogurt", documents: 3_876),
        FoodSearchTerm(term: "protein", documents: 5_000), FoodSearchTerm(term: "protien", documents: 1),
        FoodSearchTerm(term: "ketchup", documents: 1_338), FoodSearchTerm(term: "chocolate", documents: 8_874)
    ])

    @Test func misspellingsGetTheNearCommonWord() {
        #expect(Self.vocabulary.suggestion(for: "chobanni yogurt") == "chobani yogurt")
        #expect(Self.vocabulary.suggestion(for: "heinz ketchip") == "heinz ketchup")
        #expect(Self.vocabulary.suggestion(for: "quest protien bar") == "quest protein bar")
        #expect(Self.vocabulary.suggestion(for: "chickfila nuggets") == "chick fil a nuggets")
    }

    @Test func correctAndHalfTypedWordsGetNoSuggestion() {
        #expect(Self.vocabulary.suggestion(for: "chobani yogurt") == nil)
        #expect(Self.vocabulary.suggestion(for: "choc") == nil)
        #expect(Self.vocabulary.suggestion(for: "chocol") == nil)
    }

    // MARK: The shipped base catalog

    @Test func shippedCatalogFindsQuestByBrandAndSuggestsChobani() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        let first = try #require(catalog.results(for: "quest protein bar", context: .userTyped).first)
        #expect(FoodItemSearch.normalized(first.brandSource ?? "").hasPrefix("quest"), "got \(first.name) [\(first.brandSource ?? "")]")
        #expect(catalog.spellingSuggestion(for: "chobanni yogurt") == "chobani yogurt")
    }
}
