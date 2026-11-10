import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

/// The 2026-10-29 targeted brand-search fixes (Docs/Food-Search-Phase0-Baseline-2026-10-29.md): the
/// brand field is searched when the full gate finds nothing, rows agreeing with a typed brand rank first
/// (above history), and a misspelling gets an offered, never applied, suggestion. Every fix is the TYPED
/// surface's alone, so each case also pins that the machine path did not move. The 2026-11-09 review
/// fixes follow: a generic first word is not a brand, a person's own food agrees by name, a brand's
/// products join rows already matched, possessives typed plain, and single-letter brands.
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

    // MARK: Review fixes of 2026-11-09 (Docs/Food-Search-Phase0-Baseline-2026-10-29.md, last section)

    static func ownFood(_ name: String, label: String = "Custom ingredient") -> FoodItem {
        var item = food(name, brand: label)
        item.source = .manual
        return item
    }

    /// "turkey" sits in one maker's brand field ("Jennie-O Turkey Store") on 3 of 10 turkey burgers.
    /// Under the first rule (a fifth of the rows) that made it a typed brand and put that maker first.
    @Test func aGenericFirstWordInOneMakersNameIsNotABrand() {
        var rows = (1...7).map { Self.food("Turkey Burger, Seasoned \($0)", brand: "Store Brand \($0)") }
        rows += (1...3).map { Self.food("Turkey Burger, Lean \($0)", brand: "Jennie-O Turkey Store, Inc.") }
        let patties = Self.food("Burger Patties, All White Meat", brand: "Jennie-O Turkey Store, Inc.")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(rows + [patties]))
        let logged = rows[0]
        catalog.setSearchHistory(FoodSearchHistory(weights: [logged.id: 5_000]))
        let shown = catalog.results(for: "turkey burger", limit: 12, context: .userTyped)
        #expect(shown.first?.id == logged.id, "the burger this person logs stays first")
        #expect(!shown.contains { $0.id == patties.id }, "a generic first word adds no brand-field rows")
    }

    @Test func aPersonsOwnFoodAgreesWithTheTypedBrandThroughItsName() {
        let own = Self.ownFood("Heinz ketchup, the big bottle")
        let imported = Self.ownFood("Heinz ketchup glaze", label: "Imported recipe")
        let catalogRows = (1...8).map { Self.food("Heinz, Tomato Ketchup \($0)", brand: "Kraft Heinz Foods Company") }
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(catalogRows))
        catalog.setUserItems([own, imported])
        let shown = catalog.results(for: "heinz ketchup", context: .userTyped)
        #expect(Set(shown.prefix(2).map(\.id)) == [own.id, imported.id], "got \(shown.map(\.name))")
    }

    /// One row names the brand, so the zero-result route never ran and the brand's other products
    /// stayed hidden.
    @Test func aBrandsOtherProductsJoinWhenARowAlreadyMatchedByName() {
        let named = Self.food("Yogurt, Greek, Blueberry, CHOBANI", brand: "USDA FDC 170914", dataType: .srLegacy)
        let byBrand = (1...3).map { Self.food("Greek Yogurt, Blueberry on the Bottom \($0)", brand: "Chobani, Inc.") }
        let rival = Self.food("Greek Yogurt, Blueberry", brand: "Dannon Company")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([named, rival] + byBrand))
        let shown = catalog.results(for: "chobani blueberry yogurt", context: .userTyped)
        #expect(Set(shown.map(\.id)) == Set([named.id] + byBrand.map(\.id)), "got \(shown.map(\.name))")
        #expect(shown.first?.id == named.id, "the row that names the brand leads the rows that do not")
        // …unless this person logs one of the others: history still orders the brand's rows.
        catalog.setSearchHistory(FoodSearchHistory(weights: [byBrand[2].id: 5_000]))
        #expect(catalog.results(for: "chobani blueberry yogurt", context: .userTyped).prefix(2).map(\.id)
                == [byBrand[2].id, named.id])
        catalog.setSearchHistory(.empty)
        #expect(catalog.results(for: "chobani blueberry yogurt", context: .machineGenerated).map(\.id) == [named.id],
                "the machine path still sees only the row whose name says it")
    }

    @Test func aBrandTypedWithoutItsApostropheStillSaysTheBrand() {
        let amys = FoodItemSearch.normalized("Amy's Kitchen Inc.")
        #expect(FoodBrandAgreement.statesBrand(["amys"], in: amys))
        #expect(FoodBrandAgreement.statesBrand(["amy"], in: amys))
        #expect(FoodBrandAgreement.statesBrand(["kelloggs"], in: FoodItemSearch.normalized("Kellogg Company US")))
        #expect(FoodBrandAgreement.statesBrand(["trader", "joes"], in: FoodItemSearch.normalized("Trader Joe's")))
        #expect(!FoodBrandAgreement.statesBrand(["quest"], in: FoodItemSearch.normalized("Questionable Foods")))
        #expect(!FoodBrandAgreement.statesBrand(["amy"], in: FoodItemSearch.normalized("Amylu Foods")))

        let burritos = (1...2).map { Self.food("Burrito, Bean & Cheese \($0)", brand: "Amy's Kitchen Inc.") }
        let other = Self.food("Burrito, Beef", brand: "Amylu Foods")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(burritos + [other]))
        #expect(Set(catalog.results(for: "amys burrito", context: .userTyped).map(\.id)) == Set(burritos.map(\.id)))
        #expect(Set(catalog.results(for: "amy's burrito", context: .userTyped).map(\.id)) == Set(burritos.map(\.id)))
    }

    // MARK: Single-letter brands

    @Test func aQueryOpeningWithSingleLettersReadsAsABrand() {
        #expect(FoodBrandInitialism.reading(of: "m&m's")?.letters == ["m", "m"])
        #expect(FoodBrandInitialism.reading(of: "M&Ms")?.letters == ["m", "m"])
        #expect(FoodBrandInitialism.reading(of: "m and m peanut") == .init(letters: ["m", "m"], product: "peanut"))
        #expect(FoodBrandInitialism.reading(of: "a&w root beer") == .init(letters: ["a", "w"], product: "root beer"))
        #expect(FoodBrandInitialism.reading(of: "A.1. sauce") == .init(letters: ["a", "1"], product: "sauce"))
        #expect(FoodBrandInitialism.reading(of: "h-e-b tortillas")?.phrase == "h e b")
        for plain in ["a bagel", "t bone steak", "7 up", "5 hour energy", "1/2 cup oats", "mac and cheese", "milk"] {
            #expect(FoodBrandInitialism.reading(of: plain) == nil, "\(plain)")
        }
    }

    @Test func aSingleLetterBrandLeadsWhateverElseMatched() {
        let plain = Self.food("M&M'S, Milk Chocolate Candies", brand: "Mars Chocolate North America LLC")
        let peanut = Self.food("M&M'S, Chocolate Candies, Peanut", brand: "Mars Chocolate North America LLC")
        let soup = Self.food("MSG Soup Base", brand: "Store Brand")
        let ham = Self.food("Ham mayo sandwich", brand: "Store Brand")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([soup, ham, peanut, plain]))
        for typed in ["m&m's", "m&ms", "m&m", "m and ms"] {
            let shown = catalog.results(for: typed, context: .userTyped)
            #expect(shown.prefix(2).map(\.id) == [plain.id, peanut.id], "\(typed): \(shown.map(\.name))")
            #expect(!shown.contains { $0.id == ham.id }, "letters inside two words are not the brand")
        }
        #expect(catalog.results(for: "m&m peanut", context: .userTyped).first?.id == peanut.id)
        #expect(catalog.results(for: "m&m's", context: .machineGenerated).isEmpty, "typed surface only")
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

    @Test func shippedCatalogAnswersTheReviewsBrandQueries() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        func brands(_ query: String) -> [String] {
            catalog.results(for: query, context: .userTyped).map { FoodItemSearch.normalized($0.brandSource ?? "") }
        }
        let amys = brands("amys burrito")
        #expect(!amys.isEmpty && amys.allSatisfy { $0.hasPrefix("amy s kitchen") }, "got \(amys)")
        let chobani = catalog.results(for: "chobani blueberry yogurt", context: .userTyped)
        #expect(chobani.contains { FoodItemSearch.normalized($0.brandSource ?? "").hasPrefix("chobani") },
                "the brand-field row joins the one named row: \(chobani.map(\.name))")
        for typed in ["m&m's", "m&ms"] {
            let first = try #require(catalog.results(for: typed, context: .userTyped).first, "\(typed) found nothing")
            #expect(FoodBrandAgreement.states(["m", "m"], in: FoodItemSearch.normalized(first.name)), "\(typed): \(first.name)")
        }
        // "turkey" is in Jennie-O Turkey Store's brand field; it must not put that maker first.
        let cold = catalog.results(for: "turkey burger", context: .userTyped).map(\.id)
        let machine = Set(catalog.results(for: "turkey burger", limit: 60, context: .machineGenerated).map(\.id))
        #expect(cold.allSatisfy(machine.contains), "a generic query shows only rows whose names say it")
    }
}
