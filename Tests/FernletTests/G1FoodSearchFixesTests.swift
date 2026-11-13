// G1FoodSearchFixesTests.swift
// FernletTests
//
// Roadmap G1 (food search & catalog, 2026-11-13): the fixes the 2026-11-09 review left open — short
// queries (F9), a superseded search's retrieval (F8), chain words read as words (F11), a lone digit
// ("2% milk", "7 up"), the branded-category gate for flavor-last product names, the web-product cache
// age, and "Use manual nutrition" on an amount the food cannot weigh.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

struct G1FoodSearchFixesTests {
    static func food(
        _ name: String, category: String = "Fixtures", dataType: FoodDataType = .srLegacy,
        brand: String? = nil
    ) -> FoodItem {
        FoodItem(name: name, brandSource: brand, servingSize: 100, servingUnit: "g",
                 macros: Macros(protein: 5, carbs: 10, fat: 3), micronutrients: Micronutrients(),
                 category: category, source: .usda, dataType: dataType, tags: [])
    }

    // MARK: - F9: one- and two-letter queries

    @Test func anAbbreviationSearchesTheWordsItStandsFor() {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([
            Self.food("Peanut butter, smooth style"), Self.food("Orange juice, raw"), Self.food("Egg, whole, raw")
        ]))
        #expect(catalog.results(for: "pb", context: .userTyped).first?.name == "Peanut butter, smooth style")
        #expect(catalog.results(for: "OJ", context: .userTyped).first?.name == "Orange juice, raw")
        #expect(catalog.results(for: "eg", context: .userTyped).first?.name == "Egg, whole, raw")
        // A machine-generated query is never rewritten.
        #expect(catalog.results(for: "pb", context: .machineGenerated).isEmpty)
    }

    @Test func aShortFoodWordSearchesBelowTheFloor() {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([
            Self.food("V8 100% Vegetable Juice", dataType: .branded, brand: "Campbell")
        ]))
        #expect(catalog.results(for: "v8", context: .userTyped).count == 1)
    }

    @Test func anyOtherShortQueryAsksForMoreLetters() {
        #expect(FoodShortQuery.isAwaitingMoreLetters("c"))
        #expect(FoodShortQuery.isAwaitingMoreLetters("ch"))
        #expect(!FoodShortQuery.isAwaitingMoreLetters("pb"))
        #expect(!FoodShortQuery.isAwaitingMoreLetters("v8"))
        #expect(!FoodShortQuery.isAwaitingMoreLetters("che"))
        #expect(!FoodShortQuery.isAwaitingMoreLetters(""))
    }

    /// Frozen English matching input (localization wall): the tables never change by translation.
    @Test func theShortQueryTablesAreFrozen() {
        #expect(FoodShortQuery.expansionsForTesting == ["pb": "peanut butter", "oj": "orange juice", "eg": "egg"])
        #expect(FoodShortQuery.shortWordsForTesting == ["v8"])
    }

    // MARK: - Lone digit

    @Test func aDigitWithAPercentSignIsAWord() {
        #expect(FoodItemSearch.searchTokens(in: "2% milk") == ["2", "milk"])
        #expect(FoodItemSearch.searchTokens(in: "1 % milk") == ["1", "milk"])
        #expect(FoodItemSearch.searchTokens(in: "12% cream") == ["12", "cream"])
    }

    @Test func aDigitBeforeAShortBrandWordJoinsIt() {
        #expect(FoodItemSearch.searchTokens(in: "7 up") == ["7up"])
        #expect(FoodItemSearch.searchTokens(in: "7 up zero") == ["7up", "zero"])
    }

    @Test func aCountDigitIsStillDropped() {
        #expect(FoodItemSearch.searchTokens(in: "2 eggs") == ["eggs"])
        #expect(FoodItemSearch.searchTokens(in: "2 oz chicken") == ["oz", "chicken"])
        #expect(FoodItemSearch.searchTokens(in: "1 c flour") == ["flour"])
    }

    @Test func twoPercentMilkFindsTheTwoPercentRowFirst() {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([
            Self.food("Milk, whole, 3.25% milkfat"),
            Self.food("Milk, reduced fat, fluid, 2% milkfat"),
            Self.food("Milk, lowfat, fluid, 1% milkfat"),
            Self.food("Puddings, rice, dry mix, prepared with 2% milk")
        ]))
        let rows = catalog.results(for: "2% milk", context: .userTyped)
        #expect(rows.firstIndex { $0.name.hasPrefix("Puddings") } ?? rows.count > 0,
                "a dish made WITH 2% milk sits below the milk")
        #expect(rows.first?.name == "Milk, reduced fat, fluid, 2% milkfat")
        #expect(!rows.contains { $0.name.contains("1%") }, "a row that does not say 2 is not a 2% milk")
    }

    @Test func sevenUpFindsTheSoftDrink() {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([
            Self.food("7UP, Flavored Soft Drink, Cherry", dataType: .branded, brand: "Keurig Dr Pepper"),
            Self.food("Upside down cake")
        ]))
        #expect(catalog.results(for: "7 up", context: .userTyped).map(\.name) == ["7UP, Flavored Soft Drink, Cherry"])
    }

    // MARK: - F11: chain names are words

    @Test func chainNamesAreReadAsWords() {
        #expect(FoodBrandLexicon.matchedChainTokens(in: "green chilis") == [])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "chipotle chicken") == [])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "chipotle") == ["chipotle"])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "chipotle chicken burrito") == ["chipotle"])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "Chili's fajitas") == ["chilis"])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "supersonic shake") == [])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "McDonald's fries") == ["mcdonalds"])
        #expect(FoodBrandLexicon.matchedChainTokens(in: "burger king whopper") == ["burger king"])
    }

    // MARK: - Branded-category gate

    @Test func aFlavorLastProductInACompositeAisleIsNotItsFlavor() throws {
        let head = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["lemon"], normalizedQuery: "lemon"))
        let mix = Self.food("Cake Mix Extra Moist Lemon", category: "Cake, Cookie & Cupcake Mixes", dataType: .branded)
        let drink = Self.food("Sparkling Water Lemon", category: "Non Alcoholic Beverages  Ready to Drink", dataType: .branded)
        let bagged = Self.food("Organic Lemon", category: "Pre-Packaged Fruit & Vegetables", dataType: .branded)
        let reference = Self.food("Lemons, raw, without peel")
        #expect(head.level(of: mix, brandQuery: false) == 0)
        #expect(head.level(of: drink, brandQuery: false) == 0)
        #expect(head.level(of: bagged, brandQuery: false) == FoodIngredientIdentity.ingredientLevel)
        #expect(head.level(of: reference, brandQuery: false) > 0)
    }

    @Test func aCompositeAisleThatNamesTheNounStillCounts() throws {
        let cookie = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["cookie"], normalizedQuery: "cookie"))
        let chipCookie = Self.food("Chocolate Chip Cookie", category: "Cookies & Biscuits", dataType: .branded)
        #expect(cookie.level(of: chipCookie, brandQuery: false) > 0)
        let candyCorn = try #require(FoodIngredientIdentity.QueryHead(
            searchTokens: ["candy", "corn"], normalizedQuery: "candy corn"))
        #expect(candyCorn.level(of: Self.food("Candy Corn", category: "Candy", dataType: .branded), brandQuery: false) > 0)
        let corn = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["corn"], normalizedQuery: "corn"))
        #expect(corn.level(of: Self.food("Candy Corn", category: "Candy", dataType: .branded), brandQuery: false) == 0)
    }

    @Test func thePersonsOwnFoodIsNeverGated() throws {
        let head = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["lemon"], normalizedQuery: "lemon"))
        var own = Self.food("Lemon", category: "Candy", dataType: .branded)
        own.source = .manual
        #expect(head.level(of: own, brandQuery: false) > 0)
    }

    /// The failure the gate fixes: on the recipe surface the identity key leads every other key, so a
    /// flavor-last product read as "a lemon" used to sit above USDA's plain lemon juice.
    @Test func theRecipeSurfacePutsThePlainIngredientAboveTheLemonCakeMix() {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([
            Self.food("Cake Mix Extra Moist Lemon", category: "Cake, Cookie & Cupcake Mixes", dataType: .branded),
            Self.food("Lemon juice, raw")
        ]))
        let rows = catalog.results(for: "lemon", context: .userTyped, ranking: .ingredientIdentity)
        #expect(rows.map(\.name) == ["Lemon juice, raw", "Cake Mix Extra Moist Lemon"])
    }

    // MARK: - Web product cache age

    @MainActor @Test func aStaleWebProductIsNotReused() {
        let store = makeTestStore()
        let product = ImportedFoodProduct(
            sourceURL: URL(fileURLWithPath: "/chicken-melt"), name: "Chicken Melt", brand: "Example Foods",
            servingSize: "1 sandwich", macros: Macros(protein: 18, carbs: 30, fat: 12),
            micronutrients: Micronutrients()
        )
        let saved = store.saveWebImportedFoodProduct(product)
        let policy = TimeInterval(saved.verificationPolicyDays) * 86_400
        let fresh = Date().addingTimeInterval(policy - 3_600)
        let stale = Date().addingTimeInterval(policy + 3_600)
        #expect(store.cachedWebImportedFoodProduct(for: "chicken melt", now: fresh)?.id == saved.id)
        #expect(store.cachedWebImportedFoodProduct(for: "chicken melt", now: stale) == nil)
    }

    @Test func verificationAge() {
        let now = Date()
        var item = Self.food("Fixture")
        #expect(item.isPastVerification(asOf: now), "never verified counts as past")
        item.lastVerified = now.addingTimeInterval(-86_400)
        item.verificationPolicyDays = 180
        #expect(!item.isPastVerification(asOf: now))
        item.verificationPolicyDays = 0
        #expect(item.isPastVerification(asOf: now))
    }

    /// The retired `isFlagged` key: an old blob that carries it still decodes, and a new one omits it.
    @Test func theRetiredFlagKeyDecodesAndIsNoLongerWritten() throws {
        let encoded = try JSONEncoder().encode(Self.food("Fixture"))
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("isFlagged"))
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["isFlagged"] = true
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(FoodItem.self, from: legacy).name == "Fixture")
    }

    // MARK: - F8: a machine-generated search is never cut short

    @Test func aMachineGeneratedSearchInACancelledTaskStillFinishes() async throws {
        let source = try #require(SQLiteBundledFoodSource())
        let catalog = FoodCatalog(source: source)
        let whole = catalog.results(for: "chicken", limit: 20, context: .machineGenerated)
        let inCancelled = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return catalog.results(for: "chicken", limit: 20, context: .machineGenerated)
        }.value
        #expect(!whole.isEmpty)
        #expect(inCancelled.map(\.id) == whole.map(\.id))
    }

    @Test func aSupersededTypedSearchOverTheShippedCatalogAnswersNothing() async throws {
        let catalog = FoodCatalog(source: try #require(SQLiteBundledFoodSource()))
        let superseded = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return catalog.results(for: "chicken", context: .userTyped)
        }.value
        #expect(superseded.isEmpty)
    }
}
