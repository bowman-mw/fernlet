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
            FoodItem(id: try #require(UUID(uuidString: id)), name: "Row", servingSize: size, servingUnit: unit,
                     macros: Macros(protein: 10, carbs: 20, fat: 5), micronutrients: Micronutrients(),
                     category: "Test", source: .usda, dataType: type, tags: [])
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
}
