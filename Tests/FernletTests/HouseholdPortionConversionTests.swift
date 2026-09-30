// HouseholdPortionConversionTests.swift
// FernletTests
//
// The unit layer's household measures — Docs/Ingredient-Search-Deep-Research-2026-09-29.md §3, §6,
// §8 F1(b)/(c) and F4a — pinned on fixtures and on shipped USDA rows (each cited by its FDC id, which
// the compact-source id `00000000-0000-5000-8000-<fdcId>` carries).
//
// F1(b), volume portions: a food stating several volume portions ("cup" 227 g and "tbsp" 14.2 g of
// butter) refused every volume amount as ambiguous. The portion stated in the requested unit now
// answers first, and otherwise the portions' implied densities must agree within 15% (the median is
// used). Counts stay strict.
//
// F1(c), the tap default: `preferredRecipeUnit` × `defaultRecipeQuantity(for:)` is what a tap in the
// recipe editor (and a bare-count quick log) binds, and it must convert — the unit the data suggests
// is kept only when it does, else grams, else "1 serving". "Oil" is a word ("oil", "oils"), not a
// substring of "boiled".
//
// F4a, "1 each": `FoodPortionReader` reads a portion's leading measure word and drops its qualifiers,
// so "medium (7" to 7-7/8" long)" is a size, "clove" a count noun and "cup, sliced" a cup. "Each" is
// the one medium portion among several sizes, else the single named count, else the named count that
// is the food's own reference serving. Every gram weight is USDA's; the reader invents none. Fix round
// 1: a count unit on a USDA yield (a pound's cooked yield) and a named count holding a part or
// packaging word (half an apricot, a box of raisins) are not "one".

import Foundation
import Testing
import FernletDomainModel
@testable import FoodCatalog
@testable import Fernlet

/// Pins household-measure conversions (volume agreement, tap defaults, named counts).
struct HouseholdPortionConversionTests {
    static func food(_ name: String, portions: [FoodPortion], size: Double = 100, unit: String = "g") -> FoodItem {
        FoodItem(name: name, servingSize: size, servingUnit: unit, macros: Macros(protein: 10, carbs: 20, fat: 5),
                 micronutrients: Micronutrients(), category: "Test", source: .usda, dataType: .srLegacy,
                 tags: [], portions: portions)
    }

    static func grams(_ item: FoodItem, _ quantity: Double, _ unit: String) -> Double? {
        RecipeIngredient(foodItemId: item.id, quantity: quantity, unit: unit).servingConversion(using: item)?.grams
    }

    static func shipped(_ fdcID: Int) throws -> FoodItem {
        let id = try #require(UUID(uuidString: String(format: "00000000-0000-5000-8000-%012d", fdcID)))
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        return try #require(catalog.item(id: id), "shipped FDC \(fdcID) must resolve")
    }

    static func near(_ value: Double?, _ expected: Double, within tolerance: Double = 0.05) -> Bool {
        guard let value else { return false }
        return abs(value - expected) <= tolerance
    }

    // MARK: - F1(b): volume portions

    /// The portion stated in the requested unit answers first; another volume unit converts through
    /// the median of densities that agree.
    @Test func agreeingVolumePortionsConvertEveryVolumeUnit() {
        let butter = Self.food("Butter", portions: [
            FoodPortion(amount: 1, unit: "cup", gramWeight: 227),
            FoodPortion(amount: 1, unit: "tbsp", gramWeight: 14.2)
        ])
        #expect(Self.grams(butter, 1, "cup") == 227, "the stated cup, not a density")
        #expect(Self.grams(butter, 2, "tbsp") == 28.4, "the stated tablespoon")
        // cup 0.9595 g/ml, tbsp 0.9603 g/ml: the lower-middle (cup) density carries a teaspoon.
        #expect(Self.near(Self.grams(butter, 1, "tsp"), 4.92892 * 227 / 236.588, within: 0.001))
        #expect(Self.near(Self.grams(butter, 100, "ml"), 100 * 227 / 236.588, within: 0.001))
    }

    /// Two preparations of one food (sliced vs mashed banana) state two densities; none is chosen.
    @Test func disagreeingVolumePortionsStillRefuse() {
        let banana = Self.food("Banana", portions: [
            FoodPortion(amount: 1, unit: "cup", gramWeight: 150),
            FoodPortion(amount: 1, unit: "cup", gramWeight: 225)
        ])
        #expect(Self.grams(banana, 1, "cup") == nil)
        #expect(Self.grams(banana, 1, "tbsp") == nil)
        #expect(FoodPortion.densityAgreement(among: banana.portions) == nil)
        let sameCup = Self.food("Rice", portions: [
            FoodPortion(amount: 1, unit: "cup", gramWeight: 158),
            FoodPortion(amount: 1, unit: "cup", gramWeight: 160)
        ])
        #expect(Self.grams(sameCup, 1, "cup") == 158, "two cups that agree take the lower-middle one")
    }

    /// The tolerance is the median's 15%, inclusive, and a volume portion with no readable volume
    /// voids the agreement rather than being skipped.
    @Test func densityAgreementIsBoundedByTheMedian() {
        let ml = { (grams: Double) in FoodPortion(amount: 100, unit: "ml", gramWeight: grams) }
        #expect(FoodPortion.densityAgreement(among: [ml(100), ml(115)]) == ml(100))
        #expect(FoodPortion.densityAgreement(among: [ml(100), ml(116)]) == nil)
        #expect(FoodPortion.densityAgreement(among: [ml(90), ml(100), ml(114)]) == ml(100))
        #expect(FoodPortion.densityAgreement(among: []) == nil)
        #expect(FoodPortion.densityAgreement(among: [ml(100)]) == ml(100))
        let unreadable = FoodPortion(amount: 1, unit: "handful", gramWeight: 30)
        #expect(FoodPortion.densityAgreement(among: [ml(100), unreadable]) == nil)
    }

    /// Counts are untouched: two identical slices are still ambiguous (MealBuilderTests pins the same).
    @Test func countPortionsStayStrict() {
        let toast = Self.food("Toast", portions: [
            FoodPortion(amount: 1, unit: "slice", gramWeight: 50),
            FoodPortion(amount: 1, unit: "slice", gramWeight: 50)
        ])
        #expect(Self.grams(toast, 1, "slice") == nil)
    }

    /// Shipped USDA rows whose several volume portions agree: butter, olive oil, sugar, honey and
    /// garlic now convert every volume amount; a banana's two cups still refuse.
    @Test func shippedAgreeingRowsConvertVolume() throws {
        let butter = try Self.shipped(173_410)      // Butter, salted: cup 227, tbsp 14.2, stick, pat
        #expect(Self.grams(butter, 1, "cup") == 227)
        #expect(Self.grams(butter, 1, "tbsp") == 14.2)
        #expect(Self.near(Self.grams(butter, 1, "tsp"), 4.73))
        let oil = try Self.shipped(171_413)         // Oil, olive, salad or cooking: tbsp 13.5, tsp 4.5, cup 216
        #expect(Self.grams(oil, 1, "cup") == 216)
        #expect(Self.grams(oil, 1, "tbsp") == 13.5)
        #expect(Self.near(Self.grams(oil, 1, "fl oz"), 27.0))
        let sugar = try Self.shipped(169_655)       // Sugars, granulated: cup 200, tsp 4.2
        #expect(Self.grams(sugar, 1, "cup") == 200)
        #expect(Self.near(Self.grams(sugar, 1, "tbsp"), 12.5))
        let honey = try Self.shipped(169_640)       // Honey: cup 339, tbsp 21
        #expect(Self.near(Self.grams(honey, 1, "tsp"), 7.0))
        let garlic = try Self.shipped(169_230)      // Garlic, raw: tsp 2.8, cup 136 (clove, cloves)
        #expect(Self.grams(garlic, 1, "cup") == 136)
        #expect(Self.grams(garlic, 1, "tsp") == 2.8)
        let banana = try Self.shipped(173_944)      // Bananas, raw: cup sliced 150, cup mashed 225
        #expect(Self.grams(banana, 1, "cup") == nil)
    }

    // MARK: - F1(c): the tap default converts

    static func tapConverts(_ item: FoodItem) -> Bool {
        let unit = item.preferredRecipeUnit
        return RecipeIngredient(foodItemId: item.id, quantity: item.defaultRecipeQuantity(for: unit), unit: unit.rawValue)
            .servingConversion(using: item) != nil
    }

    /// An oil served by mass with no portions used to tap to "1 cup", which cannot convert; it now
    /// taps to its serving in grams. Served by volume it still taps to a tablespoon.
    @Test func anOilWithNoDensityTapsToGrams() {
        let massOil = Self.food("Oil, coconut, virgin", portions: [], size: 14, unit: "g")
        #expect(massOil.preferredRecipeUnit == .gram)
        #expect(massOil.defaultRecipeQuantity(for: .gram) == 14)
        #expect(massOil.tapDefaultConverts(.gram) && !massOil.tapDefaultConverts(.cup))
        let volumeOils = Self.food("Oils, vegetable blend", portions: [], size: 15, unit: "ml")
        #expect(volumeOils.preferredRecipeUnit == .tablespoon, "plural \"oils\" is still an oil")
        #expect(Self.tapConverts(volumeOils))
    }

    /// "Oil" is a word: a boiled or broiled food served by volume taps to its own milliliters, not a
    /// tablespoon (it matched the substring before).
    @Test func boiledIsNotAnOil() {
        let broth = Self.food("Chicken broth, boiled", portions: [], size: 240, unit: "ml")
        #expect(broth.preferredRecipeUnit == .milliliter)
        #expect(broth.defaultRecipeQuantity(for: .milliliter) == 240)
    }

    /// A serving the converter cannot weigh (IU, a survey unit) falls back to "1 serving", which
    /// resolves; a unit the data suggests is never returned when it cannot convert.
    @Test func anUnweighableServingTapsToOneServing() {
        let iuOil = Self.food("Oil, fish, cod liver", portions: [], size: 1, unit: "IU")
        #expect(iuOil.preferredRecipeUnit == .serving)
        #expect(Self.tapConverts(iuOil))
        let flour = Self.food("Flour, rice", portions: [], size: 30, unit: "sandwich")
        #expect(flour.preferredRecipeUnit == .serving, "grams cannot convert against a sandwich")
        let pastBound = Self.food("Punch, party size", portions: [], size: 4_320, unit: "ml")
        #expect(pastBound.preferredRecipeUnit == .gram, "nothing converts past the bound; grams by rule")
        #expect(!Self.tapConverts(pastBound))
    }

    /// A cup default that converts is kept (olive oil's stated cup); one that cannot — a cup portion
    /// on a serving the converter cannot weigh — is not, and the tap lands on "1 serving".
    @Test func aCandidateIsKeptOnlyWhenItConverts() throws {
        let oil = try Self.shipped(171_413)         // Oil, olive, salad or cooking: tablespoon, tsp, cup
        #expect(oil.preferredRecipeUnit == .cup && Self.tapConverts(oil))
        let syrup = Self.food("Syrup", portions: [FoodPortion(amount: 1, unit: "cup", gramWeight: 300)], size: 1, unit: "IU")
        #expect(!syrup.tapDefaultConverts(.cup))
        #expect(syrup.preferredRecipeUnit == .serving && Self.tapConverts(syrup))
    }

    // MARK: - F4a: the tolerant reader

    static func portion(_ unit: String, _ grams: Double = 100, amount: Double = 1, description: String? = nil) -> FoodPortion {
        FoodPortion(amount: amount, unit: unit, gramWeight: grams, description: description)
    }

    /// The leading measure word decides, and qualifiers (a parenthetical, anything after a comma) are
    /// dropped: USDA's own portion text, read the way a cook reads it.
    @Test func theReaderClassifiesUSDAPortionText() {
        let cases: [(FoodPortion, FoodPortionMeasure?)] = [
            (Self.portion("medium (7\" to 7-7/8\" long)"), .count(noun: nil, size: "medium")),
            (Self.portion("extra large (9\" or longer)"), .count(noun: nil, size: "extra large")),
            (Self.portion("large whole (3\" dia)"), .count(noun: nil, size: "large")),
            (Self.portion("cup, sliced"), .unit(.cup)),
            (Self.portion("tbsp chopped"), .unit(.tablespoon)),
            (Self.portion("fl oz"), .unit(.fluidOunce)),
            (Self.portion("oz"), .unit(.ounce)),
            (Self.portion("lb"), .unit(.pound)),
            (Self.portion("NLEA serving"), .reference),
            (Self.portion("RACC"), .reference),
            (Self.portion("serving 1 cube"), .reference),
            (Self.portion("clove"), .count(noun: "clove", size: nil)),
            (Self.portion("cloves", 9, amount: 3), .count(noun: "clove", size: nil)),
            (Self.portion("Potato medium (2-1/4\" to 3-1/4\" dia)"), .count(noun: "potato", size: "medium")),
            (Self.portion("stalk, medium (7-1/2\" - 8\" long)"), .count(noun: "stalk", size: "medium")),
            (Self.portion("tortilla, medium (approx 6\" dia)"), .count(noun: "tortilla", size: "medium")),
            (Self.portion("5 tomatoes", amount: 5), nil),
            (Self.portion("tomatoes", 50, amount: 5), .count(noun: "tomato", size: nil)),
            (Self.portion("medium slice (approx 3\" x 2\" x 1/4\")"), .unit(.slice)),
            (Self.portion("slice, medium (1/8\" thick)"), .unit(.slice)),
            (Self.portion("strip large (3\" long)"), nil),
            (Self.portion("package (5 oz)"), nil),
            (Self.portion("wedge (1/4 of medium tomato)"), nil),
            (Self.portion("undetermined", description: "1 banana"), .count(noun: "banana", size: nil)),
            (Self.portion("undetermined", description: "1 piece, NFS"), .unit(.piece)),
            // Fix round 1: a yield is not one piece or one unit; a part or a package is not one of anything.
            (Self.portion("piece, cooked, excluding refuse (yield from 1 lb raw meat with refuse)"), nil),
            (Self.portion("unit (yield from 1 lb ready-to-cook chicken)"), nil),
            (Self.portion("lemon yields"), .count(noun: "lemon", size: nil)),
            (Self.portion("cup, dry, yields"), .unit(.cup)),
            (Self.portion("apricot half with liquid"), nil),
            (Self.portion("small box (1.5 oz)"), nil),
            (Self.portion("plum with liquid"), .count(noun: "plum", size: nil))
        ]
        for (portion, expected) in cases {
            #expect(portion.measure == expected, "\(portion.unit) / \(portion.description ?? "")")
        }
        #expect(Self.portion("cup, sliced").exactRecipeUnit == nil, "the exact reading is unchanged")
        #expect(Self.portion("cup").exactRecipeUnit == .cup)
        #expect(Self.portion("medium").recipeUnit == .each && Self.portion("RACC").recipeUnit == nil)
    }

    /// "Each" among several sizes is the medium one; a single named count is itself; several
    /// portions of one noun that agree are one size; the food's reference serving breaks a tie.
    @Test func eachResolvesToTheMediumOrTheSingleNamedCount() {
        let banana = Self.food("Banana", portions: [
            Self.portion("NLEA serving", 126), Self.portion("extra large (9\" or longer)", 152),
            Self.portion("large (8\" to 8-7/8\" long)", 136), Self.portion("cup, sliced", 150),
            Self.portion("small (6\" to 6-7/8\" long)", 101), Self.portion("medium (7\" to 7-7/8\" long)", 118)
        ])
        #expect(Self.grams(banana, 1, "each") == 118)
        #expect(Self.grams(banana, 2, "each") == 236)
        let garlic = Self.food("Garlic", portions: [Self.portion("clove", 3), Self.portion("cloves", 9, amount: 3)])
        #expect(Self.grams(garlic, 2, "each") == 6, "\"clove\" and \"3 cloves\" agree: one size")
        let lemon = Self.food("Lemon", portions: [
            Self.portion("fruit (2-3/8\" dia)", 84), Self.portion("fruit (2-1/8\" dia)", 58), Self.portion("NLEA serving", 58)
        ])
        #expect(Self.grams(lemon, 1, "each") == 58, "two fruit sizes; USDA's label serving names the 58 g one")
        let orange = Self.food("Orange", portions: [
            Self.portion("small (2-3/8\" dia)", 96), Self.portion("large (3-1/16\" dia)", 184), Self.portion("fruit (2-5/8\" dia)", 131)
        ])
        #expect(Self.grams(orange, 1, "each") == 131, "sizes without a medium; the one unsized fruit")
        let tortillas = Self.food("Tortillas", portions: [
            Self.portion("tortilla (approx 12\" dia)", 117), Self.portion("tortilla (approx 7-8\" dia)", 49),
            Self.portion("tortilla, medium (approx 6\" dia)", 32)
        ])
        #expect(Self.grams(tortillas, 1, "each") == nil, "three tortilla sizes, one medium: ambiguous")
        let sizesOnly = Self.food("Leather", portions: [Self.portion("large", 20), Self.portion("small", 10)])
        #expect(Self.grams(sizesOnly, 1, "each") == nil, "two sizes and no medium")
        let turkey = Self.food("Turkey, Ground, cooked", portions: [
            Self.portion("oz", 85, amount: 3), Self.portion("patty (4 oz, raw) (yield after cooking)", 82),
            Self.portion("unit, yield from 1 lb raw", 330)
        ])
        #expect(Self.grams(turkey, 1, "each") == nil, "a qualified \"unit\" (a pound's yield) is not one of anything")
        #expect(turkey.preferredRecipeUnit == .gram)
    }

    /// A portion stated exactly as "each" still answers first and strictly, and "slice"/"piece" read
    /// a single qualified portion only when none is stated exactly.
    @Test func exactCountPortionsStillAnswerFirst() {
        let orange = Self.food("Orange", portions: [Self.portion("each", 140), Self.portion("medium", 131), Self.portion("large", 184)])
        #expect(Self.grams(orange, 1, "each") == 140)
        let twoEach = Self.food("Two", portions: [Self.portion("each", 140), Self.portion("each", 150), Self.portion("medium", 131)])
        #expect(Self.grams(twoEach, 1, "each") == nil, "two stated \"each\" portions stay ambiguous")
        let onion = Self.food("Onion", portions: [Self.portion("slice, thin", 9), Self.portion("medium", 110), Self.portion("large", 150)])
        #expect(Self.grams(onion, 1, "slice") == 9, "one qualified slice is the slice")
        let slices = Self.food("Onion", portions: [Self.portion("slice, thin", 9), Self.portion("slice, large (1/4\" thick)", 38)])
        #expect(Self.grams(slices, 1, "slice") == nil)
    }

    /// The tolerant reader only ADDS conversions: a qualified cup answers "1 cup" when it is the only
    /// cup, an exactly stated cup still wins over it, and the exactly stated volume portions' old
    /// answer survives a qualified portion that disagrees with them.
    @Test func qualifiedVolumePortionsOnlyAddConversions() {
        let jalapeno = Self.food("Jalapeno", portions: [Self.portion("pepper", 14), Self.portion("cup, sliced", 90)])
        #expect(Self.grams(jalapeno, 1, "cup") == 90)
        let seeds = Self.food("Seeds", portions: [Self.portion("cup", 140), Self.portion("cup, with hulls", 46)])
        #expect(Self.grams(seeds, 1, "cup") == 140, "the stated cup, not the hulled one")
        let cream = Self.food("Cream cheese", portions: [
            Self.portion("tbsp", 14.5), Self.portion("cup", 232), Self.portion("cup, whipped", 145)
        ])
        #expect(Self.near(Self.grams(cream, 1, "tsp"), 4.84, within: 0.05), "the stated tbsp and cup still agree")
    }

    /// The tap default is "each" when the portions say what one is — ahead of a cup — and a qualified
    /// cup does not move a tap default.
    @Test func eachLeadsTheTapDefault() {
        let egg = Self.food("Egg", portions: [
            Self.portion("cup (4.86 large eggs)", 243), Self.portion("medium", 44), Self.portion("large", 50)
        ])
        #expect(egg.preferredRecipeUnit == .each, "never \"1 cup\" of eggs for a bare \"2 eggs\"")
        #expect(Self.grams(egg, 2, "each") == 88)
        let spinach = Self.food("Spinach", portions: [Self.portion("cup, chopped", 30), Self.portion("bunch", 340)])
        #expect(spinach.preferredRecipeUnit == .gram, "a qualified cup does not become the tap default")
    }

    /// "1 each" on shipped USDA rows (FDC id, the portion it reads, grams). Each value is the row's
    /// own portion weight; these rows refused "each" before this round.
    @Test func shippedCountNounsTakeOneEach() throws {
        let pins: [(fdc: Int, name: String, grams: Double)] = [
            (173_944, "Bananas, raw — medium (7\" to 7-7/8\" long)", 118),
            (170_000, "Onions, raw — medium (2-1/2\" dia)", 110),
            (790_577, "Onions, red, raw — Onion", 197),
            (170_005, "Onions, spring or scallions — medium (4-1/8\" long)", 15),
            (748_967, "Eggs, Grade A, Large, egg whole — egg", 50.3),
            (171_287, "Egg, whole, raw, fresh — medium", 44),
            (169_230, "Garlic, raw — clove (and \"3 cloves\" 9 g)", 3),
            (167_746, "Lemons, raw, without peel — fruit (2-1/8\" dia) = NLEA serving", 58),
            (168_155, "Limes, raw — fruit (2\" dia)", 67),
            (169_097, "Oranges, raw, all commercial varieties — fruit (2-5/8\" dia)", 131),
            (170_393, "Carrots, raw — medium", 61),
            (168_409, "Cucumber, with peel, raw — cucumber (8-1/4\")", 301),
            (168_576, "Peppers, jalapeno, raw — pepper", 14),
            (170_108, "Peppers, sweet, red, raw — medium", 119),
            (169_988, "Celery, raw — stalk, medium", 40),
            (170_026, "Potatoes, flesh and skin, raw — Potato medium", 213),
            (169_291, "Squash, summer, zucchini, includes skin, raw — medium", 196),
            (170_457, "Tomatoes, red, ripe, raw, year round average — medium whole", 123),
            (171_688, "Apples, raw, with skin — medium (3\" dia)", 182),
            (171_706, "Avocados, raw, California — fruit, without skin and seed", 136),
            (167_762, "Strawberries, raw — medium (1-1/4\" dia)", 12),
            (173_410, "Butter, salted — stick", 113),
            (173_241, "Tortillas, corn, without added salt — tortilla, medium", 26)
        ]
        for pin in pins {
            let row = try Self.shipped(pin.fdc)
            #expect(Self.grams(row, 1, "each") == pin.grams, "FDC \(pin.fdc) \(pin.name)")
            #expect(row.preferredRecipeUnit == .each, "FDC \(pin.fdc) taps to one")
        }
        #expect(Self.grams(try Self.shipped(173_242), 1, "each") == nil, "four flour-tortilla sizes: ambiguous")
        #expect(Self.grams(try Self.shipped(2_710_824), 1, "each") == nil, "Avocado, Hass: USDA states RACC only")
        #expect(Self.grams(try Self.shipped(173_944), 1, "cup") == nil, "a banana's two cups still disagree")
    }

    /// Fix round 1 (u2-L-H1, u2-L-M1): what a count word leads is set aside when it is not one of
    /// anything. USDA's "piece, cooked, excluding refuse (yield from 1 lb raw meat with refuse)" is a
    /// pound's cooked yield — 283 g of pork roast, 326 g of top round — and "1 piece" refused before
    /// the tolerant reader; it refuses again. Half an apricot and a box of raisins are not "1 each".
    @Test func yieldsPartsAndPackagesAreNotOne() throws {
        let pork = try Self.shipped(167_894)        // Pork, loin, center rib roast, cooked: oz, piece (yield)
        #expect(Self.grams(pork, 1, "piece") == nil)
        #expect(Self.grams(pork, 2, "piece") == nil)
        #expect(Self.grams(pork, 3, "oz") != nil, "its ounces still convert")
        let steak = try Self.shipped(169_531)       // Beef, round, top round steak, broiled: piece (yield), oz
        #expect(Self.grams(steak, 1, "piece") == nil)
        #expect(steak.preferredRecipeUnit == .gram)
        let apricots = try Self.shipped(171_699)    // Apricots, canned, heavy syrup: apricot half with liquid 40 g
        #expect(Self.grams(apricots, 1, "each") == nil, "\"apricot half\" is half of one")
        #expect(apricots.preferredRecipeUnit != .each)
        let raisins = try Self.shipped(168_165)     // Raisins, dark, seedless: small box (1.5 oz) 43 g
        #expect(Self.grams(raisins, 1, "each") == nil, "a small box is packaging, not one raisin")
        #expect(raisins.preferredRecipeUnit != .each)
        let juice = try Self.shipped(167_747)       // Lemon juice, raw: "lemon yields" 48 g — one lemon's juice
        #expect(Self.grams(juice, 1, "each") == 48)
    }
}
