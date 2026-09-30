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

    private static func heads(_ name: String, usda: Bool = true, modifiers: [String] = []) -> Set<String> {
        let modifierForms = modifiers.reduce(into: Set<String>()) { $0.formUnion(FoodIngredientIdentity.forms(of: $1)) }
        return FoodIngredientIdentity.heads(ofName: name, referenceNaming: usda, modifierForms: modifierForms)
    }

    private static func query(_ text: String) throws -> FoodIngredientIdentity.QueryHead {
        try #require(FoodIngredientIdentity.QueryHead(
            searchTokens: text.split(separator: " ").map(String.init), normalizedQuery: text
        ))
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

    /// When a class's second segment only qualifies it — or names a typed modifier — the member is the
    /// third segment: the canonical USDA zucchini, thigh and bacon rows (fix round 1).
    @Test func aQualifiedClassNamesItsMemberThird() {
        #expect(Self.heads("Squash, summer, zucchini, includes skin, raw").contains("zucchini"))
        #expect(Self.heads("Chicken, broilers or fryers, thigh, meat only, raw").contains("thigh"))
        #expect(Self.heads("Pork, cured, bacon, unprepared").contains("bacon"))
        #expect(Self.heads("Pork, fresh, shoulder, whole, separable lean only, raw").contains("shoulder"))
        #expect(Self.heads("Beef, flank, steak, boneless, choice, raw", modifiers: ["flank"]).contains("steak"))
        #expect(!Self.heads("Beef, flank, steak, boneless, choice, raw").contains("steak"),
                "without the modifier, 'flank' is the member and the third segment a qualifier")
        #expect(!Self.heads("Beverages, Cocoa mix, powder", modifiers: ["cocoa"]).contains("powder"),
                "a member that is a product ('cocoa mix') does not defer to its third segment")
    }

    /// A product name (branded, restaurant, a person's own) is one phrase: a preposition makes it a
    /// composite, and a first segment followed by anything but an echo of its words is a flavor list —
    /// the rows fix round 1's reviewers found filling the lime, lemon and zucchini lists.
    @Test func aProductNameIsOnePhrase() {
        #expect(Self.heads("Lemon, Ginger Drink, Lemon, Ginger", usda: false).isEmpty)
        #expect(Self.heads("Lime, Cherry, Berry Blue, Strawberry, Orange Jelly Beans, Orange", usda: false).isEmpty)
        #expect(Self.heads("Roasted Vegetable Zucchini, Spinach, Eggplant, Peppers, & Broccoli Pizza", usda: false).isEmpty)
        #expect(Self.heads("Zucchini With Marinara, Marinara", usda: false).isEmpty)
        #expect(Self.heads("Yeast With Poppy Seed Filling Cake", usda: false).isEmpty)
        #expect(Self.heads("Tater Chips, Milk Chocolate", usda: false).isEmpty)
        #expect(Self.heads("Dark Chocolate Chips, Dark", usda: false) == ["chips"], "the catalog's ', <flavor>' echo")
        #expect(Self.heads("Pork with chili and tomatoes") == ["pork"], "a reference name still ends its phrase there")
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
        #expect(!cocoa.isNamed(by: Self.food("Cocoa, Powder", .branded)), "a branded first segment followed by a flavor is no product")
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
        #expect(Self.heads("Macaroni and cheese, boxed mix").isEmpty, "two one-word phrases: a dish, not cheese")
        #expect(Self.heads("Peas and carrots, frozen, unprepared").isEmpty)
        #expect(Self.heads("Half And Half", usda: false) == ["half"], "two phrases ending in the same noun")
    }

    // MARK: - The compound level

    /// A USDA reference row that says a typed modifier as its kind is the compound the person typed; a
    /// row that says it later, a product name, and every row of a brand query stay at the plain level.
    @Test func aReferenceRowNamingTheKindIsTheCompound() throws {
        let compound = FoodIngredientIdentity.compoundLevel, plain = FoodIngredientIdentity.ingredientLevel
        let wholeMilk = try Self.query("whole milk")
        #expect(wholeMilk.level(of: Self.food("Milk, whole, 3.25% milkfat, with added vitamin D"), brandQuery: false) == compound)
        #expect(wholeMilk.level(of: Self.food("Milk, dry, whole, with added vitamin D"), brandQuery: false) == plain)
        #expect(wholeMilk.level(of: Self.food("Milk, buttermilk, fluid, whole"), brandQuery: false) == plain)
        #expect(wholeMilk.level(of: Self.food("Whole Milk", .branded), brandQuery: false) == plain)
        #expect(wholeMilk.level(of: Self.food("Milk, whole, 3.25% milkfat, with added vitamin D"), brandQuery: true) == plain)
        #expect(wholeMilk.level(of: Self.food("Yogurt, plain, whole milk"), brandQuery: false) == 0)
        let oliveOil = try Self.query("olive oil")
        #expect(oliveOil.level(of: Self.food("Oil, olive, salad or cooking"), brandQuery: false) == compound)
        #expect(oliveOil.level(of: Self.food("Oil, corn, peanut, and olive"), brandQuery: false) == plain)
        let blackPepper = try Self.query("black pepper")
        #expect(blackPepper.level(of: Self.food("Spices, pepper, black"), brandQuery: false) == compound,
                "a class member's kind is its qualifier")
        #expect(try Self.query("milk").level(of: Self.food("Milk, whole, 3.25% milkfat"), brandQuery: false) == plain,
                "a one-word query has no compound")
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

    /// The compound level leads the identity group, and a flavored product is no longer the ingredient:
    /// fix round 1's "whole milk", "olive oil" and "milk chocolate chips" #1 rows.
    @Test func theTypedCompoundLeads() {
        let buttermilk = Self.food("Milk, buttermilk, fluid, whole")
        let dry = Self.food("Milk, dry, whole, with added vitamin D")
        let fluid = Self.food("Milk, whole, 3.25% milkfat, with added vitamin D")
        let milk = FoodCatalog(source: InMemoryBundledFoodSource([buttermilk, dry, fluid]))
        #expect(milk.results(for: "whole milk", context: .userTyped, ranking: .ingredientIdentity).first?.id == fluid.id)
        let blend = Self.food("Oil, corn, peanut, and olive")
        let olive = Self.food("Oil, olive, salad or cooking")
        let oil = FoodCatalog(source: InMemoryBundledFoodSource([blend, olive]))
        #expect(oil.results(for: "olive oil", context: .userTyped, ranking: .ingredientIdentity).first?.id == olive.id)
        let tater = Self.food("Tater Chips, Milk Chocolate", .branded)
        let chips = Self.food("Milk Chocolate Chips", .branded)
        let baking = FoodCatalog(source: InMemoryBundledFoodSource([tater, chips]))
        #expect(baking.results(for: "milk chocolate chips", context: .userTyped, ranking: .ingredientIdentity)
                .map(\.id) == [chips.id, tater.id])
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
