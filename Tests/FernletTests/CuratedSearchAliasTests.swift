// CuratedSearchAliasTests.swift
// FernletTests
//
// Ingredient-search round F7 (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §2, §8 F7): a small
// curated alias table answers "chocolate chips" with USDA's "Candies, semisweet chocolate" — a row
// whose NAME never says "chips", so no ranking change could reach it.
//
// Three things are pinned here: the table's targets are the rows they claim (by the committed
// catalog's deterministic ids, never a renumberable food_id); the phrase matcher's word rules; and
// where the row lands relative to the three personal tiers — a correction wins over it, and this
// person's own and logged rows stay above it — plus that no machine-generated surface ever sees it.

import Foundation
import Testing
import FernletDomainModel
@testable import FoodCatalog

struct CuratedSearchAliasTests {
    /// The row each alias target must be, in the shipped catalog.
    static let expectedTargets: [String: String] = [
        CuratedSearchAlias.semisweetChocolateID: "Candies, semisweet chocolate",
        CuratedSearchAlias.rawGarlicID: "Garlic, raw",
        CuratedSearchAlias.redPepperID: "Spices, pepper, red or cayenne",
        CuratedSearchAlias.soybeanOilID: "Oil, soybean, salad or cooking",
    ]

    /// A throwaway food carrying a chosen id.
    static func food(_ name: String, id: UUID = UUID(), source: FoodItemSource = .usda,
                     dataType: FoodDataType = .srLegacy) -> FoodItem {
        FoodItem(id: id, name: name, servingSize: 100, servingUnit: "g",
                 macros: Macros(protein: 1, carbs: 2, fat: 3), micronutrients: Micronutrients(),
                 category: "Test", source: source, dataType: dataType, tags: [])
    }

    // MARK: - The table

    @Test func everyTargetIsTheNamedRowInTheShippedCatalog() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        #expect(Set(CuratedSearchAlias.entries.map(\.targetID)) == Set(Self.expectedTargets.keys))
        for (targetID, name) in Self.expectedTargets {
            let id = try #require(UUID(uuidString: targetID), "\(targetID) is not a UUID")
            let row = try #require(catalog.item(id: id), "\(name) is missing from the shipped catalog")
            #expect(row.name == name)
            #expect(row.dataType == .srLegacy, "\(name) must be the USDA generic row")
        }
    }

    @Test func phrasesAreNormalizedAndWithinTheWordLimit() {
        for entry in CuratedSearchAlias.entries {
            #expect(FoodItemSearch.normalized(entry.phrase) == entry.phrase, "\(entry.phrase) is not in normalized form")
            #expect((2...CuratedSearchAlias.maxPhraseWords).contains(entry.words.count), "\(entry.phrase): word count")
        }
        #expect(Set(CuratedSearchAlias.entries.map(\.phrase)).count == CuratedSearchAlias.entries.count, "a phrase is listed twice")
    }

    // MARK: - Matching

    @Test func phrasesMatchWhileTheLastWordIsBeingTyped() {
        let chips = UUID(uuidString: CuratedSearchAlias.semisweetChocolateID)
        for typed in ["chocolate chips", "Chocolate Chips", "chocolate chip", "chocolate chi", "chocolate ch",
                      "chocolate c", "choc chips", "choc c", "semisweet chocolate chips",
                      "semi sweet chocolate chips", "Semi-Sweet Chocolate Chips", "semi sweet chocolate",
                      "semisweet chocolate"] {
            #expect(CuratedSearchAlias.targetID(forTyped: typed) == chips, "\(typed) should name the semisweet row")
        }
        #expect(CuratedSearchAlias.targetID(forTyped: "garlic cloves") == UUID(uuidString: CuratedSearchAlias.rawGarlicID))
        #expect(CuratedSearchAlias.targetID(forTyped: "garlic cl") == UUID(uuidString: CuratedSearchAlias.rawGarlicID))
        #expect(CuratedSearchAlias.targetID(forTyped: "red pepper f") == UUID(uuidString: CuratedSearchAlias.redPepperID))
        #expect(CuratedSearchAlias.targetID(forTyped: "crushed red pepper") == UUID(uuidString: CuratedSearchAlias.redPepperID))
        #expect(CuratedSearchAlias.targetID(forTyped: "vegetable oil") == UUID(uuidString: CuratedSearchAlias.soybeanOilID))
    }

    /// One word is still being typed; a shorter or longer query names something else.
    @Test func otherQueriesNameNothing() {
        for typed in ["chocolate", "choc", "chocolate chip cookies", "chocolate chipz", "chocolate cake",
                      "red pepper", "red bell pepper", "garlic", "garlic powder", "vegetable", "vegetable oil spray",
                      "semi", "semi sweet", "ch", "", "   "] {
            #expect(CuratedSearchAlias.targetID(forTyped: typed) == nil, "\(typed) should name no alias")
        }
    }

    @Test func theSpellingFoldJoinsOnlyTheListedPair() {
        #expect(CuratedSearchAlias.folded(["semi", "sweet", "chocolate"]) == ["semisweet", "chocolate"])
        #expect(CuratedSearchAlias.folded(["semi", "dry", "sweet"]) == ["semi", "dry", "sweet"])
        #expect(CuratedSearchAlias.folded(["sweet", "semi"]) == ["sweet", "semi"])
    }

    // MARK: - Where the row lands (shipped catalog, cold)

    @Test func typedChocolateChipsLeadsWithTheSemisweetRow() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        for typed in ["chocolate chips", "chocolate chip", "chocolate chi"] {
            let rows = catalog.results(for: typed, context: .userTyped)
            #expect(rows.first?.name == "Candies, semisweet chocolate", "\(typed) leads with \(rows.first?.name ?? "nothing")")
            #expect(rows.count == 6, "\(typed): the alias grows no list past its limit")
        }
    }

    /// The resolver pool and the importer's limit-1 bind are machine surfaces: no alias reaches them.
    @Test func machineSurfacesNeverSeeTheAlias() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        let chips = try #require(UUID(uuidString: CuratedSearchAlias.semisweetChocolateID))
        let machine = catalog.results(for: "chocolate chips", limit: 60, context: .machineGenerated)
        #expect(!machine.contains { $0.id == chips })
        #expect(!catalog.candidates(for: "chocolate chips").contains { $0.foodItem.id == chips })
        #expect(!catalog.scoredResults(for: "chocolate chips", limit: 60).contains { $0.item.id == chips })
    }

    // MARK: - Precedence (in-memory catalog)

    /// A catalog holding the alias's target and a cookie that the typed words DO reach.
    static func catalog() throws -> (FoodCatalog, target: FoodItem, cookie: FoodItem) {
        let id = try #require(UUID(uuidString: CuratedSearchAlias.semisweetChocolateID))
        let target = food("Candies, semisweet chocolate", id: id)
        let cookie = food("Cookies, chocolate chip, dry mix")
        return (FoodCatalog(source: InMemoryBundledFoodSource([target, cookie])), target, cookie)
    }

    @Test func onAColdCatalogTheAliasRowIsFirstAndNothingIsDropped() throws {
        let (catalog, target, cookie) = try Self.catalog()
        let rows = catalog.results(for: "chocolate chips", context: .userTyped)
        #expect(rows.map(\.id) == [target.id, cookie.id])
    }

    @Test func aCorrectionStillWinsOverTheAlias() throws {
        let (catalog, target, cookie) = try Self.catalog()
        catalog.setSearchAliases(["chocolate chips": cookie.id])
        let rows = catalog.results(for: "chocolate chips", context: .userTyped)
        #expect(rows.map(\.id) == [cookie.id, target.id], "the person's correction must stay first")
    }

    @Test func thePersonsOwnAndLoggedRowsStayAboveTheAlias() throws {
        let mine = Self.food("Chocolate chips, my brand", source: .manual)
        let (catalog, target, cookie) = try Self.catalog()
        catalog.setUserItems([mine])
        #expect(catalog.results(for: "chocolate chips", context: .userTyped).map(\.id) == [mine.id, target.id, cookie.id])

        let (logged, loggedTarget, loggedCookie) = try Self.catalog()
        logged.setSearchHistory(FoodSearchHistory(weights: [loggedCookie.id: 3_000]))
        #expect(logged.results(for: "chocolate chips", context: .userTyped).map(\.id) == [loggedCookie.id, loggedTarget.id])
    }

    @Test func aTargetMissingFromTheCatalogIsInert() {
        let cookie = Self.food("Cookies, chocolate chip, dry mix")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([cookie]))
        #expect(catalog.results(for: "chocolate chips", context: .userTyped).map(\.id) == [cookie.id])
    }
}
