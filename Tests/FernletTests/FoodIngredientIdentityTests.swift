// FoodIngredientIdentityTests.swift
// FernletTests
//
// The ingredient-search round's F5 (Docs/Ingredient-Search-Deep-Research-2026-09-29.md §8 F5): the
// recipe surfaces rank a row that IS the typed ingredient ahead of one that only contains its words.
// These are statements about the RULES — each head-noun convention on the catalog's own names — and
// about the comparator on small in-memory catalogs. The shipped-catalog measurement is
// `IngredientSearchCorpusTests` (the 160-query pins) and the opt-in replay probe.

import Foundation
import Testing
@testable import FernletDomainModel
import FoodCatalog

@Suite
struct FoodIngredientIdentityTests {

    private static func heads(_ name: String, usda: Bool = true) -> Set<String> {
        FoodIngredientIdentity.heads(ofName: name, readsClassMembers: usda)
    }

    private static func food(_ name: String, _ dataType: FoodDataType = .srLegacy) -> FoodItem {
        FoodSearchHistoryRankingTests.food(name, dataType: dataType)
    }

    // MARK: - Heads

    /// The head is the last word of the first segment: a processed food whose head is a different noun
    /// is never the ingredient — the task's two named traps included.
    @Test func aProcessedFoodIsNotItsIngredient() {
        #expect(Self.heads("Bananas, raw") == ["bananas"])
        #expect(Self.heads("Cookies, chocolate chip, dry mix") == ["cookies"])
        #expect(Self.heads("Bread, banana") == ["bread"])
        #expect(Self.heads("Milk and cereal bar") == ["bar"])
        #expect(Self.heads("Chocolate Chip Cookies", usda: false) == ["cookies"])
    }

    /// USDA's "Category, member" form: a CLASS category's member is the ingredient — the prototype's
    /// known weak spots — while a dish or product category's is not.
    @Test func aClassMemberIsTheIngredient() {
        #expect(Self.heads("Squash, zucchini, baby, raw").contains("zucchini"))
        #expect(Self.heads("Cheese, parmesan, grated").contains("parmesan"))
        #expect(Self.heads("Onions, spring or scallions (includes tops and bulb), raw").contains("scallions"))
        #expect(Self.heads("Spices, pepper, black").contains("pepper"))
        #expect(Self.heads("Leavening agents, baking soda").contains("soda"))
        #expect(Self.heads("Peppers, jalapeño, raw").contains("jalapeno"), "folded as the index folds: no diacritics")
        #expect(!Self.heads("Oil, olive, salad or cooking").contains("olive"), "olive oil is not an olive")
        #expect(!Self.heads("Flour, almond").contains("almond"), "almond flour is not an almond")
        #expect(!Self.heads("Cheese, parmesan", usda: false).contains("parmesan"),
                "a branded name's second segment is a flavor, never a class member")
    }

    /// A part that is the food, and a one-word parenthetical, name the ingredient; leaves do not.
    @Test func partsAndParentheticalsNameTheIngredient() {
        #expect(Self.heads("Ginger root, raw").contains("ginger"))
        #expect(Self.heads("Coriander (cilantro) leaves, raw").contains("cilantro"))
        #expect(Self.heads("Green onion, (scallion), bulb and greens, root removed, raw").contains("scallion"))
        #expect(!Self.heads("Sweet potato leaves, raw").contains("potato"), "sweet potato leaves are not sweet potatoes")
        #expect(Self.heads("Chickpeas (garbanzo beans, bengal gram), mature seeds, raw") == ["chickpeas"],
                "a comma inside parentheses does not split, and a two-word parenthetical is no synonym")
    }

    /// A seed spice is its plant inside a class member only, and USDA's inverted compound ("Tomato,
    /// paste") names the query's head only when its first segment names one of the query's modifiers.
    @Test func seedSpicesAndInvertedCompounds() throws {
        #expect(Self.heads("Spices, cumin seed").contains("cumin"))
        #expect(!Self.heads("Pumpkin seeds, roasted").contains("pumpkin"), "outside a class member a seed is no part")
        let paste = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["tomato", "paste"], normalizedQuery: "tomato paste"))
        #expect(paste.isNamed(by: Self.food("Tomato, paste, canned, without salt added")))
        #expect(paste.isNamed(by: Self.food("Tomato Paste", .branded)))
        let cocoa = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["cocoa", "powder"], normalizedQuery: "cocoa powder"))
        #expect(cocoa.isNamed(by: Self.food("Cocoa, dry powder, unsweetened")))
        #expect(!cocoa.isNamed(by: Self.food("Cocoa, Powder", .branded)), "a branded second segment is a flavor")
        #expect(!Self.heads("Tomato, paste, canned").contains("paste"), "a one-word query has no modifier")
    }

    /// A phrase ends at a preposition, and coordination shares or withholds a head.
    @Test func prepositionsAndCoordination() {
        #expect(Self.heads("Pork with chili and tomatoes") == ["pork"])
        #expect(!Self.heads("Chicken, no broth").contains("broth"), "'no broth' says nothing about broth")
        #expect(Self.heads("Chicken or turkey salad with egg") == ["salad"])
        #expect(Self.heads("Egg omelet or scrambled egg, NS as to fat").isEmpty,
                "two whole phrases ending in different nouns have no single head")
        #expect(Self.heads("Wild Pacific Sardines Cumin & Coriander", usda: false).isEmpty, "& coordinates like 'and'")
        #expect(Self.heads("Egg burrito") == ["burrito"])
    }

    // MARK: - Forms and the query

    /// Plural-aware, both ways, including the -es and -ies plurals the search gate's stem skips.
    @Test func formsMeetAcrossNumber() {
        #expect(!FoodIngredientIdentity.forms(of: "tomatoes").isDisjoint(with: FoodIngredientIdentity.forms(of: "tomato")))
        #expect(FoodIngredientIdentity.forms(of: "berries").contains("berry"))
        #expect(FoodIngredientIdentity.forms(of: "chips").contains("chip"))
        #expect(FoodIngredientIdentity.forms(of: "glass") == ["glass"])
    }

    /// No head until one is typed: a trailing single letter ("chocolate c") leaves the key off, and a
    /// part noun brings its owner ("garlic clove" is garlic).
    @Test func theQueryHead() throws {
        #expect(FoodIngredientIdentity.QueryHead(searchTokens: ["chocolate"], normalizedQuery: "chocolate c") == nil)
        #expect(FoodIngredientIdentity.QueryHead(searchTokens: [], normalizedQuery: "") == nil)
        let clove = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["garlic", "clove"], normalizedQuery: "garlic clove"))
        #expect(clove.isNamed(by: Self.food("Garlic, raw")))
        #expect(!clove.isNamed(by: Self.food("Spices, garlic powder")))
    }

    /// The completeness gate: a head said whole by under one ranked row in ten is a word still being
    /// typed ("choc" in a list of chocolate rows), so the key stays off.
    @Test func anUnfinishedWordIsNoHead() throws {
        let head = try #require(FoodIngredientIdentity.QueryHead(searchTokens: ["choc"], normalizedQuery: "choc"))
        let chocolate: [Set<String>] = Array(repeating: ["chocolate", "dark"], count: 95)
        let abbreviated: [Set<String>] = Array(repeating: ["bar", "choc"], count: 5)
        #expect(!head.sharesHead(chocolate + abbreviated))
        #expect(head.sharesHead(Array(chocolate.prefix(9)) + [["choc"]]), "one row in ten is enough")
        #expect(!head.sharesHead([]))
    }

    // MARK: - The comparator

    /// The recipe order puts the plain row first across the data-type tier; the standard order is
    /// untouched (the generic-first tier still wins there).
    @Test func identityOutranksTheTierOnTheRecipeSurfaceOnly() {
        let cookie = Self.food("Cookies, chocolate chip, dry mix", .srLegacy)
        let chips = Self.food("Semi-Sweet Chocolate Chips", .branded)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([cookie, chips]))
        #expect(catalog.results(for: "chocolate chips", context: .userTyped).map(\.id) == [cookie.id, chips.id])
        #expect(catalog.results(for: "chocolate chips", context: .userTyped, ranking: .ingredientIdentity).map(\.id)
                == [chips.id, cookie.id])
        #expect(catalog.results(for: "chocolate chips", context: .userTyped, ranking: .standard).map(\.id)
                == catalog.results(for: "chocolate chips", context: .userTyped).map(\.id),
                "the default is the standard order")
    }

    /// Among rows that ARE the ingredient, the standard keys still order them: the generic tier first.
    @Test func theTierOrdersThePlainRows() {
        let branded = Self.food("Brown Sugar", .branded)
        let usda = Self.food("Sugars, brown", .srLegacy)
        let cereal = Self.food("Cereal with brown sugar", .srLegacy)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([cereal, branded, usda]))
        let recipe = catalog.results(for: "brown sugar", context: .userTyped, ranking: .ingredientIdentity).map(\.id)
        #expect(recipe == [usda.id, branded.id, cereal.id])
    }

    /// The swap sheet's pool reads identity per sub-phrase; the resolver's pool (the default) does not.
    @Test func theSwapPoolRanksByIdentityAndTheResolverPoolDoesNot() {
        let cookie = Self.food("Cookies, chocolate chip, dry mix", .srLegacy)
        let chips = Self.food("Semi-Sweet Chocolate Chips", .branded)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([cookie, chips]))
        #expect(catalog.candidates(for: "chocolate chips").first?.foodItem.id == cookie.id)
        #expect(catalog.candidates(for: "chocolate chips", ranking: .ingredientIdentity).first?.foodItem.id == chips.id)
    }

    /// Identity never reaches a confidence gate: `scoredResults` has no ranking and keeps the standard
    /// order, so a quick-log bind reads exactly what it read before F5.
    @Test func scoredResultsStayStandard() {
        let cookie = Self.food("Cookies, chocolate chip, dry mix", .srLegacy)
        let chips = Self.food("Semi-Sweet Chocolate Chips", .branded)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([cookie, chips]))
        #expect(catalog.scoredResults(for: "chocolate chips").map(\.item.id) == [cookie.id, chips.id])
    }

    /// With the head still being typed, the recipe order IS the standard order.
    @Test func anUntypedHeadLeavesTheStandardOrder() {
        let rows = (0..<12).map { Self.food("Chocolate, dark, \($0)0% cacao solids", .srLegacy) }
            + [Self.food("F1 CHSCK BAR CHOC", .branded)]
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource(rows))
        let standard = catalog.results(for: "choc", limit: 13, context: .userTyped).map(\.id)
        #expect(catalog.results(for: "choc", limit: 13, context: .userTyped, ranking: .ingredientIdentity).map(\.id) == standard)
    }
}
