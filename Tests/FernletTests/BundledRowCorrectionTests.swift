// BundledRowCorrectionTests.swift
// FernletTests
//
// The load-time corrections `SQLiteBundledFoodSource` applies to rows of the committed
// `FoodCatalog.sqlite` (FoodCatalog's `BundledRowCorrection`), pinned on real shipped rows —
// Docs/Ingredient-Search-Deep-Research-2026-09-29.md §8.
//
// F2, the branded per-100 g basis (§6.5): 59,227 compact-source branded rows state USDA's per-100 g
// nutrients against the product's label serving. "String Cheese" (HENNING'S, FDC 358925) is the
// report's own witness: P29 F18 on a 28 g stick, where the label says P8 F5.
//
// F1(a), raw FDC unit codes (§3.4, "Rung 0a"): 14,600 GTIN rows serve in `GRM`/`GM`/`MLT`, which the
// converter could not read, so they converted nothing — not even grams — and failed on tap; and a
// serving the converter cannot read at all (IU, MC, survey units) refused even "1 serving".

import Foundation
import Testing
import FernletDomainModel
@testable import FoodCatalog
import AIProviders
@testable import Fernlet

/// Pins the load-time catalog row corrections on shipped rows, through every surface they reach.
struct BundledRowCorrectionTests {
    /// HENNING'S String Cheese, FDC 358925 — compact-source branded, 28 g label, per-100 g macros.
    static let stringCheeseID = UUID(uuidString: "00000000-0000-5000-8000-000000358925")
    /// "Chocolate Chips, Chocolate" (Bloom), FDC 1897681 — the report's broken row 64235.
    static let rebasedChipsID = UUID(uuidString: "00000000-0000-5000-8000-000001897681")
    /// Its GTIN twin, row 106868 — the same product on the label basis, never rebased.
    static let gtinChipsID = UUID(uuidString: "88C4EB4B-4E4E-41FA-91A4-811533FD52C6")
    /// "2% MILKFAT REDUCED FAT MILK", FDC 1125242 — a 240 ml label on per-100 ml macros.
    static let milkID = UUID(uuidString: "00000000-0000-5000-8000-000001125242")
    /// "Chocolate Chips, Chocolate" (Lieber), row 107005 — a GTIN row served in `GRM`.
    static let grmChipsID = UUID(uuidString: "5FB8309B-B672-466E-9782-BFF762002DE3")
    /// "12OZ 6PK Cans Pink Grapefruit Dry", row 68431 — a GTIN row served in `MLT`.
    static let mltSodaID = UUID(uuidString: "DB6AF4A2-BC19-4900-B93E-55A646D682F9")
    /// "1% Milkfat Small Curd Cottage Cheese", row 78840 — a GTIN row served in `GM`.
    static let gmCottageCheeseID = UUID(uuidString: "54C74C43-A4C0-4C17-BEF0-1CB5C6E09955")
    /// "100% Instant Nonfat Dry Milk", row 68381 — a GTIN row served in `IU` (no mass, no volume).
    static let iuDryMilkID = UUID(uuidString: "FBA86D0F-7B54-4395-96F5-3B3901382878")
    /// "Club sandwich on wheat", FDC 2706995 — a survey row served in "sandwich".
    static let clubSandwichID = UUID(uuidString: "00000000-0000-5000-8000-000002706995")
    /// "Olive Oil", FDC 410984 — a compact-source branded oil: 15 ml label, per-100 ml macros.
    static let oliveOilID = UUID(uuidString: "00000000-0000-5000-8000-000000410984")
    /// "100% California Extra Virgin Olive Oil…", row 68349 — a GTIN oil served in `MLT` (15).
    static let mltOliveOilID = UUID(uuidString: "697CAE77-17D1-424C-A973-1287EF2C084D")

    static func shipped(_ id: UUID?) throws -> FoodItem {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        let id = try #require(id)
        return try #require(catalog.item(id: id), "shipped row \(id) must resolve")
    }

    static func macros(_ item: FoodItem, _ quantity: Double, _ unit: RecipeUnit) -> Macros? {
        RecipeIngredient(foodItemId: item.id, quantity: quantity, unit: unit.rawValue)
            .servingConversion(using: item)?.scaledMacros(for: item)
    }

    // MARK: - F2

    /// The row itself: a 100 g basis with the stored macros, and the 28 g label kept as "each".
    @Test func stringCheeseIsRebasedOntoOneHundredGrams() throws {
        let cheese = try Self.shipped(Self.stringCheeseID)
        #expect(cheese.servingSize == 100)
        #expect(cheese.servingUnit == "g")
        #expect(cheese.macros == Macros(protein: 29, carbs: 0, fat: 18), "the stored macros are per 100 g — unchanged")
        #expect(cheese.portions == [FoodPortion(amount: 1, unit: "each", gramWeight: 28, description: "1 serving (28 g)")])
        #expect(cheese.preferredRecipeUnit == .each)
        #expect(cheese.defaultRecipeQuantity(for: .each) == 1)
        #expect(Self.macros(cheese, 1, .each) == Macros(protein: 8, carbs: 0, fat: 5), "one stick is the label's P8 F5")
        #expect(Self.macros(cheese, 100, .gram) == Macros(protein: 29, carbs: 0, fat: 18))
        #expect(Self.macros(cheese, 28, .gram) == Macros(protein: 8, carbs: 0, fat: 5))
        #expect(Self.macros(cheese, 1, .serving) == Macros(protein: 29, carbs: 0, fat: 18), "1 serving is the 100 g basis")
    }

    /// Quick-log's bare count: "2 string cheese" bound to the rebased row is two 28 g sticks
    /// (P16), not 2 × 100 g (P58) — the reason the label serving is a COUNT portion (report §6.5).
    @MainActor @Test func quickLogBareCountMeansTwoLabelServings() throws {
        let cheese = try Self.shipped(Self.stringCheeseID)
        let candidates = [FoodSelectionCandidate(id: 1, foodItem: cheese)]
        let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
            description: "2 string cheese", candidates: candidates, fallbackType: nil
        ))
        let ingredient = try #require(plan.items.first?.ingredients.first)
        #expect(ingredient.unit == "each")
        #expect(ingredient.quantity == 2)
        let conversion = try #require(
            RecipeIngredient(foodItemId: cheese.id, quantity: ingredient.quantity, unit: ingredient.unit)
                .servingConversion(using: cheese)
        )
        #expect(conversion.grams == 56)
        #expect(conversion.scaledMacros(for: cheese) == Macros(protein: 16, carbs: 0, fat: 10))
    }

    /// A recipe line on a rebased row totals from grams on the 100 g basis — through the editor's
    /// `resolvedMacros` and through `MealBuilder`'s recipe totals.
    @MainActor @Test func brandedRecipeLineTotalsOnTheRebasedBasis() throws {
        let cheese = try Self.shipped(Self.stringCheeseID)
        let input = ManualRecipeIngredientInput(name: cheese.name, selectedFoodItemId: cheese.id, quantity: 56, unit: "g")
        #expect(input.resolvedMacros(foodItems: [cheese]) == Macros(protein: 16, carbs: 0, fat: 10))
        let recipe = RecipeDefinition(
            name: "Snack plate", servings: 1,
            ingredients: [RecipeIngredient(foodItemId: cheese.id, quantity: 2, unit: "each")],
            source: "manual", createdAt: Date(), updatedAt: Date()
        )
        #expect(MealBuilder.macroTotals(for: recipe, foodItems: [cheese]) == MacroTotals(protein: 16, carbs: 0, fat: 10))
    }

    /// The report's chips pair (§2.5): the rebased 64235 now agrees with its label-basis GTIN twin,
    /// which the correction leaves alone.
    @Test func rebasedChipsAgreeWithTheirGTINTwin() throws {
        let rebased = try Self.shipped(Self.rebasedChipsID)
        let twin = try Self.shipped(Self.gtinChipsID)
        #expect(rebased.servingSize == 100 && rebased.macros == Macros(protein: 0, carbs: 67, fat: 27))
        #expect(twin.servingSize == 15 && twin.portions.isEmpty, "a GTIN row is on the label basis already")
        #expect(Self.macros(rebased, 1, .each) == Self.macros(twin, 1, .serving))
        #expect(Self.macros(rebased, 15, .gram) == Macros(protein: 0, carbs: 10, fat: 4))
    }

    /// A milliliter label is rebased to 100 ml without a count portion — a count cannot reach a
    /// volume serving without a density — so its tap default still converts.
    @Test func milliliterLabelsRebaseWithoutACountPortion() throws {
        let milk = try Self.shipped(Self.milkID)
        #expect(milk.servingSize == 100 && milk.servingUnit == "ml")
        #expect(milk.portions.isEmpty)
        #expect(milk.macros == Macros(protein: 3, carbs: 5, fat: 2))
        #expect(Self.macros(milk, 240, .milliliter) == Macros(protein: 7, carbs: 12, fat: 5))
        let unit = milk.preferredRecipeUnit
        #expect(Self.macros(milk, milk.defaultRecipeQuantity(for: unit), unit) != nil)
    }

    /// The guard, on synthetic rows: only a compact-source id with a branded (or restaurant) type
    /// and a gram or milliliter label other than 100 is touched.
    @Test func onlyCompactSourceBrandedLabelsAreRebased() throws {
        func row(_ id: String, _ type: FoodDataType, _ size: Double, _ unit: String) throws -> FoodItem {
            // An SR Legacy food group, so F6's retype of misfiled branded products leaves these alone.
            FoodItem(id: try #require(UUID(uuidString: id)), name: "Row", servingSize: size, servingUnit: unit,
                     macros: Macros(protein: 10, carbs: 20, fat: 5), micronutrients: Micronutrients(),
                     category: "Sweets", source: .usda, dataType: type, tags: [])
        }
        let compact = "00000000-0000-5000-8000-000000000001"
        let gtin = "5FB8309B-B672-466E-9782-BFF762002DE3"
        let untouched = [
            try row(compact, .srLegacy, 28, "g"),
            try row(compact, .survey, 28, "g"),
            try row(compact, .branded, 100, "g"),
            try row(compact, .branded, 1, "cup"),
            try row(gtin, .branded, 28, "g")
        ]
        for item in untouched {
            #expect(BundledRowCorrection.corrected(item) == item, "\(item.dataType) \(item.servingSize) \(item.servingUnit)")
        }
        let restaurant = BundledRowCorrection.corrected(try row(compact, .restaurant, 31, "g"))
        #expect(restaurant.servingSize == 100 && restaurant.portions.map(\.gramWeight) == [31])
    }

    // MARK: - F1(a)

    /// A `GRM` row now reads as grams: its tap default (15 g) converts, and so do grams and ounces —
    /// the report's row 107005, which "converts nothing in a recipe, not even grams" (§2.5).
    @Test func grmRowsConvertInGrams() throws {
        let chips = try Self.shipped(Self.grmChipsID)
        #expect(chips.servingUnit == "g" && chips.servingSize == 15)
        #expect(chips.preferredRecipeUnit == .gram && chips.defaultRecipeQuantity(for: .gram) == 15)
        #expect(Self.macros(chips, 15, .gram) == Macros(protein: 0, carbs: 10, fat: 4))
        #expect(Self.macros(chips, 30, .gram) == Macros(protein: 0, carbs: 20, fat: 8))
        #expect(Self.macros(chips, 1, .serving) == Macros(protein: 0, carbs: 10, fat: 4))
        #expect(Self.macros(chips, 1, .ounce) != nil)
        #expect(Self.macros(chips, 1, .cup) == nil, "a mass serving still refuses volume without a portion")
        let cottage = try Self.shipped(Self.gmCottageCheeseID)
        #expect(cottage.servingUnit == "g" && Self.macros(cottage, 113, .gram) == Macros(protein: 13, carbs: 0, fat: 2))
    }

    /// An `MLT` row now reads as milliliters: volume units convert, grams still do not (no density).
    @Test func mltRowsConvertInVolume() throws {
        let soda = try Self.shipped(Self.mltSodaID)
        #expect(soda.servingUnit == "ml" && soda.servingSize == 360)
        #expect(soda.preferredRecipeUnit == .milliliter)
        #expect(Self.macros(soda, 360, .milliliter) == Macros(protein: 0, carbs: 38, fat: 0))
        #expect(Self.macros(soda, 12, .fluidOunce) != nil)
        #expect(Self.macros(soda, 100, .gram) == nil, "a volume serving is not mass without a density")
    }

    /// A serving the converter cannot read at all still means one serving — IU, and a survey row
    /// served "per sandwich" — while every physical unit keeps refusing it.
    @Test func unreadableServingUnitsStillResolveServings() throws {
        let dryMilk = try Self.shipped(Self.iuDryMilkID)
        #expect(dryMilk.servingUnit == "IU")
        #expect(Self.macros(dryMilk, 1, .serving) == Macros(protein: 7, carbs: 11, fat: 0))
        #expect(Self.macros(dryMilk, 2, .serving) == Macros(protein: 14, carbs: 22, fat: 0))
        #expect(Self.macros(dryMilk, 21, .gram) == nil)
        let sandwich = try Self.shipped(Self.clubSandwichID)
        #expect(sandwich.servingUnit == "sandwich")
        #expect(Self.macros(sandwich, 1, .serving) == Macros(protein: 21, carbs: 28, fat: 10))
        #expect(sandwich.preferredRecipeUnit == .serving, "the tap default is the serving, which now resolves")
        let conversion = try #require(
            RecipeIngredient(foodItemId: sandwich.id, quantity: 1, unit: "serving").servingConversion(using: sandwich)
        )
        #expect(conversion.grams == nil && conversion.provenance == .exactServingBasis)
        #expect(Self.macros(sandwich, 1, .each) == nil)
    }

    /// The alias guard on synthetic rows: only the three codes move, case-insensitively, and `MG`
    /// (which `RecipeUnit.normalized` already reads as milligrams) and `IU` stay.
    @Test func onlyTheRawCodesAreAliased() {
        func row(_ unit: String) -> FoodItem {
            FoodItem(name: "Row", servingSize: 10, servingUnit: unit, macros: Macros(protein: 1, carbs: 1, fat: 1),
                     micronutrients: Micronutrients(), category: "Test", source: .usda, dataType: .branded, tags: [])
        }
        #expect(BundledRowCorrection.corrected(row("GRM")).servingUnit == "g")
        #expect(BundledRowCorrection.corrected(row("grm")).servingUnit == "g")
        #expect(BundledRowCorrection.corrected(row("GM")).servingUnit == "g")
        #expect(BundledRowCorrection.corrected(row("MLT")).servingUnit == "ml")
        for unchanged in ["MG", "IU", "MC", "g", "ml", "cup", "sandwich"] {
            #expect(BundledRowCorrection.corrected(row(unchanged)).servingUnit == unchanged)
        }
    }

    /// An oil served by volume taps to ONE tablespoon. The tap default used to be the serving's size
    /// in tablespoons — "15 tbsp" (221 ml) for a 15 ml serving, and "100 tbsp" once F2 put the branded
    /// oils on a 100 ml basis — and F1(a) would have added the `MLT` oils to it. Quick-log's bare
    /// count rides the same default, so "2 olive oil" is two tablespoons.
    @MainActor @Test func volumeServedOilsTapToOneTablespoon() throws {
        let oil = try Self.shipped(Self.oliveOilID)
        #expect(oil.servingSize == 100 && oil.servingUnit == "ml")
        #expect(oil.preferredRecipeUnit == .tablespoon)
        #expect(oil.defaultRecipeQuantity(for: .tablespoon) == 1)
        #expect(oil.defaultRecipeQuantity(for: .milliliter) == 100, "the serving's own unit still taps the serving")
        #expect(Self.macros(oil, 1, .tablespoon) == Macros(protein: 0, carbs: 0, fat: 14))
        let mlt = try Self.shipped(Self.mltOliveOilID)
        #expect(mlt.servingUnit == "ml" && mlt.preferredRecipeUnit == .tablespoon)
        #expect(mlt.defaultRecipeQuantity(for: .tablespoon) == 1)
        #expect(Self.macros(mlt, 1, .tablespoon) == Macros(protein: 0, carbs: 0, fat: 14))
        let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
            description: "2 olive oil", candidates: [FoodSelectionCandidate(id: 1, foodItem: oil)], fallbackType: nil
        ))
        let ingredient = try #require(plan.items.first?.ingredients.first)
        #expect(ingredient.unit == "tbsp" && ingredient.quantity == 2)
    }
}
