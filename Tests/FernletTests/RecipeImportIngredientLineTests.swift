// RecipeImportIngredientLineTests.swift
// FernletTests
//
// F10 of Docs/Ingredient-Search-Deep-Research-2026-09-29.md, third instrument: what the web recipe
// importer's USDA fallback does with everyday ingredient lines (report §3.5) — flipped by F11.
//
// Before F11, `RecipeWebImporter.parseIngredient`'s unit alternation listed "l" before
// "large"/"liters" and "g" before "grams"/"glasses", and `\s*` let the unit swallow the first letter
// of the food: "2 large eggs" parsed as 2 "l" of "arge eggs", "1 lemon" as a liter of "emon". The
// mangled names matched nothing, so those lines were silently skipped. A line that did parse could
// void the whole page: "1 cup chocolate chips" bound a chip cookie whose only portion is a 22 g bar,
// "cup" could not convert, and the estimator returned nil for everything.
//
// F11: the alternation is longest first and a unit must END (whitespace, comma, the line's end, or a
// period before one of those); a count or size word ("large", "cloves", "medium") binds "each" only on
// a row with a count portion, and a bare count ("1 lemon") tries "each" before one 100 g serving; and
// a line that still cannot be counted is skipped AND COUNTED, so the page keeps every other line's
// nutrition and says how many it left out. Against the shipped catalog, cold.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import AIProviders

/// The web importer's parse, bind and count of everyday recipe lines through its USDA fallback.
struct RecipeImportIngredientLineTests {
    /// One pinned line: what the parser reads, what that name binds in the shipped catalog, and which
    /// unit the estimator counted it in (nil: the line is skipped and counted as left out).
    struct LinePin: Sendable {
        /// The recipe line, a frozen English matching input.
        let line: String
        /// Parsed quantity.
        let quantity: Double
        /// Parsed unit token.
        let unit: String
        /// Parsed (cleaned) food name.
        let name: String
        /// How the parser read the unit.
        let reading: ParsedIngredientLine.UnitReading
        /// The catalog row the importer binds (`results(for:limit: 1, context: .machineGenerated)`).
        let boundName: String?
        /// The unit token the line was counted in on that row; nil when it was left out.
        let countedUnit: String?
    }

    static let pins: [LinePin] = [
        LinePin(line: "2 large eggs", quantity: 2, unit: "each", name: "eggs", reading: .countWord,
                boundName: "Eggs, Grade A, Large, egg whole", countedUnit: "each"),
        LinePin(line: "100 grams flour", quantity: 100, unit: "g", name: "flour", reading: .stated,
                boundName: "Flour, 00", countedUnit: "g"),
        LinePin(line: "1 lemon", quantity: 1, unit: "serving", name: "lemon", reading: .bareCount,
                boundName: "Lemon grass (citronella), raw", countedUnit: "serving"),
        LinePin(line: "2 garlic cloves", quantity: 2, unit: "serving", name: "garlic cloves", reading: .bareCount,
                boundName: "Garlic Cloves With Fine Herbs", countedUnit: "each"),
        LinePin(line: "1 cup chocolate chips", quantity: 1, unit: "cup", name: "chocolate chips", reading: .stated,
                boundName: "Cookies, marshmallow, with rice cereal and chocolate chips", countedUnit: nil),
        // The machine bind lands on the RACC-only "Garlic, raw" twin (the typed list's one-row-per-name
        // collapse is typed-only), which has no clove: left out and counted, not a 100 g "serving".
        LinePin(line: "3 cloves garlic, minced", quantity: 3, unit: "each", name: "garlic", reading: .countWord,
                boundName: "Garlic, raw", countedUnit: nil),
        LinePin(line: "1 medium onion, diced", quantity: 1, unit: "each", name: "onion", reading: .countWord,
                boundName: "Onions, raw", countedUnit: "each"),
        LinePin(line: "2 tbsp. butter", quantity: 2, unit: "tbsp", name: "butter", reading: .stated,
                boundName: "Egg omelet or scrambled egg, made with butter", countedUnit: "tbsp"),
        LinePin(line: "1 1/2 cups whole milk", quantity: 1.5, unit: "cup", name: "whole milk", reading: .stated,
                boundName: "Cheese, ricotta, whole milk", countedUnit: nil),
    ]

    @Test func everydayLinesParseToTheirPinnedAnswers() throws {
        for pin in Self.pins {
            let parsed = try #require(RecipeWebImporter.parseIngredientLine(pin.line), "\(pin.line) no longer parses")
            #expect(parsed.quantity == pin.quantity, "\(pin.line): quantity is now \(parsed.quantity)")
            #expect(parsed.unit == pin.unit, "\(pin.line): unit is now \(parsed.unit)")
            #expect(parsed.name == pin.name, "\(pin.line): name is now \(parsed.name)")
            #expect(parsed.unitReading == pin.reading, "\(pin.line): read as \(parsed.unitReading)")
            let tuple = try #require(RecipeWebImporter.parseIngredient(pin.line))
            #expect(tuple.unit == parsed.unit && tuple.name == parsed.name, "\(pin.line): the tuple form disagrees")
        }
    }

    @Test func everydayLinesBindAndCountToTheirPinnedAnswers() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        for pin in Self.pins {
            let parsed = try #require(RecipeWebImporter.parseIngredientLine(pin.line))
            let bound = catalog.results(for: parsed.name, limit: 1, context: .machineGenerated).first
            #expect(bound?.name == pin.boundName, "\(pin.line) now binds \(bound?.name ?? "nothing")")
            let counted = bound.flatMap { row in
                parsed.candidateUnits.first {
                    RecipeIngredient(foodItemId: row.id, quantity: parsed.quantity, unit: $0).servingConversion(using: row) != nil
                }
            }
            #expect(counted == pin.countedUnit, "\(pin.line): counted in \(counted ?? "nothing")")
            #expect((RecipeWebImporter.estimatedMacros(for: parsed, catalog: catalog) != nil) == (pin.countedUnit != nil))
        }
        // Together: the page keeps every line that counts and says how many it left out (before F11 the
        // chips cup alone voided the estimate).
        let estimate = try #require(RecipeWebImporter.ingredientEstimate(Self.pins.map(\.line), servings: 4, catalog: catalog))
        #expect(estimate.uncountedLines == Self.pins.filter { $0.countedUnit == nil }.count)
    }

    /// A unit word must end where it ends: "g" never takes the "g" of "garlic", "l" never the "l" of
    /// "lime", and a unit read whole ("glasses", "liters") still reads.
    @Test func aUnitNeverSwallowsTheFoodsFirstLetter() throws {
        let cases: [(line: String, unit: String, name: String)] = [
            ("1 lime", "serving", "lime"), ("1 leek", "serving", "leek"), ("1 glass milk", "glass", "milk"),
            ("2 liters water", "l", "water"), ("1 l milk", "l", "milk"), ("250g sugar", "g", "sugar"),
            ("2 lbs chicken", "lb", "chicken"), ("1 gallon milk", "serving", "gallon milk"),
            ("2 cups, sifted flour", "cup", "sifted flour"), ("4 oz. cheddar", "oz", "cheddar"),
        ]
        for (line, unit, name) in cases {
            let parsed = try #require(RecipeWebImporter.parseIngredientLine(line), "\(line) no longer parses")
            #expect(parsed.unit == unit, "\(line): unit is now \(parsed.unit)")
            #expect(parsed.name == name, "\(line): name is now \(parsed.name)")
        }
    }

    /// A size word binds "each" only on a row with a count portion: on one without, the line is left
    /// out — it is never read as a 100 g serving, and it never voids the rest of the page.
    @Test func aSizeWordCountsOnlyWhereTheRowHasACount() {
        let ramen = FoodItem(name: "Ramen", servingSize: 100, servingUnit: "g",
                             macros: Macros(protein: 5, carbs: 10, fat: 2), micronutrients: Micronutrients(),
                             category: "Fixtures", source: .usda, tags: [])
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([ramen]))
        let line = RecipeWebImporter.parseIngredientLine("2 large ramen")
        #expect(line?.candidateUnits == ["each"])
        #expect(line.flatMap { RecipeWebImporter.estimatedMacros(for: $0, catalog: catalog) } == nil)
        let estimate = RecipeWebImporter.ingredientEstimate(["2 large ramen", "200 g ramen", "salt to taste"],
                                                            servings: 2, catalog: catalog)
        #expect(estimate == IngredientMacroEstimate(protein: 5, carbs: 10, fat: 2, uncountedLines: 1),
                "the size-word line is left out and counted; a line with no amount joins neither side")
    }

    /// The control: a clean line still estimates, with nothing left out.
    @Test func aCleanLineStillEstimates() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        let estimate = RecipeWebImporter.ingredientEstimate(["100 g butter"], servings: 1, catalog: catalog)
        #expect(estimate?.uncountedLines == 0)
        #expect((estimate?.fat ?? 0) > 0)
    }
}
