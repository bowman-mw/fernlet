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

    /// A cup default that converts is kept (butter's stated cup); one that cannot — a cup portion on
    /// a serving the converter cannot weigh — is not, and the tap lands on "1 serving".
    @Test func aCandidateIsKeptOnlyWhenItConverts() throws {
        let butter = try Self.shipped(173_410)
        #expect(butter.preferredRecipeUnit == .cup && Self.tapConverts(butter))
        let syrup = Self.food("Syrup", portions: [FoodPortion(amount: 1, unit: "cup", gramWeight: 300)], size: 1, unit: "IU")
        #expect(!syrup.tapDefaultConverts(.cup))
        #expect(syrup.preferredRecipeUnit == .serving && Self.tapConverts(syrup))
    }
}
