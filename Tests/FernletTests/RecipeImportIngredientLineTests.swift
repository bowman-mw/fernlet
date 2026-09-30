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
// a row with a count portion, and a bare count ("1 lemon") tries "each" and then one serving only
// where that serving is one item (fix round 1: never an SR row's 100 g reference amount); and a line
// that still cannot be counted is skipped AND COUNTED, so the page keeps every other line's nutrition
// and says how many it left out. Against the shipped catalog, cold.
//
// F4b (2026-09-30): a line the bound row's own data cannot weigh is counted by the USDA typical size of
// the ingredient that row IS (`TypicalPortionTable`) — "3 cloves garlic" on the RACC-only raw garlic
// row is 3 × 3 g, "2 cups all-purpose flour" on the RACC-only flour row 2 × 125 g. A row that is not the
// ingredient ("1 cup chocolate chips" still binds a chip cookie) gets no typical size and stays left out.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
import AppServices
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
        /// Whether it was counted by the USDA typical size of the ingredient the row IS
        /// (`TypicalPortionTable`, F4b) because the row's own data cannot weigh it.
        var byTypicalSize = false
    }

    static let pins: [LinePin] = [
        LinePin(line: "2 large eggs", quantity: 2, unit: "each", name: "eggs", reading: .countWord,
                boundName: "Eggs, Grade A, Large, egg whole", countedUnit: "each"),
        LinePin(line: "100 grams flour", quantity: 100, unit: "g", name: "flour", reading: .stated,
                boundName: "Flour, 00", countedUnit: "g"),
        // The machine bind is lemongrass (report F5), which has no count portion; its serving is SR's
        // 100 g reference amount, not one item, so the line is left out and counted (fix round 1,
        // u3-L-U3-4) rather than adding 100 g of lemongrass.
        LinePin(line: "1 lemon", quantity: 1, unit: "serving", name: "lemon", reading: .bareCount,
                boundName: "Lemon grass (citronella), raw", countedUnit: nil),
        LinePin(line: "2 garlic cloves", quantity: 2, unit: "serving", name: "garlic cloves", reading: .bareCount,
                boundName: "Garlic Cloves With Fine Herbs", countedUnit: "each"),
        LinePin(line: "1 cup chocolate chips", quantity: 1, unit: "cup", name: "chocolate chips", reading: .stated,
                boundName: "Cookies, marshmallow, with rice cereal and chocolate chips", countedUnit: nil),
        // The machine bind lands on the RACC-only "Garlic, raw" twin (the typed list's one-row-per-name
        // collapse is typed-only), which has no clove of its own. F4b counts it by USDA's typical clove
        // (3 g, SR 169230) — 9 g, not a 100 g "serving"; before F4b it was left out and counted.
        LinePin(line: "3 cloves garlic, minced", quantity: 3, unit: "each", name: "garlic", reading: .countWord,
                boundName: "Garlic, raw", countedUnit: "each", byTypicalSize: true),
        // F4b: the RACC-only all-purpose flour row has no cup; USDA's typical cup (125 g, SR 168894)
        // counts it — 250 g.
        LinePin(line: "2 cups all-purpose flour", quantity: 2, unit: "cup", name: "all-purpose flour", reading: .stated,
                boundName: "Flour, wheat, all-purpose, enriched, bleached", countedUnit: "cup", byTypicalSize: true),
        LinePin(line: "1 banana", quantity: 1, unit: "serving", name: "banana", reading: .bareCount,
                boundName: "Bananas, raw", countedUnit: "each"),
        // F4b: the branded chips row states only its label serving; USDA's typical cup of semisweet chips
        // (168 g, SR 167976) counts it.
        LinePin(line: "1 cup semisweet chocolate chips", quantity: 1, unit: "cup", name: "semisweet chocolate chips",
                reading: .stated, boundName: "Akoma Extra Semisweet Chocolate Chips, Akoma Extra Semisweet",
                countedUnit: "cup", byTypicalSize: true),
        // F4b: the Hass row states only its RACC; USDA's typical avocado (136 g, SR 171706) counts one.
        LinePin(line: "1 avocado", quantity: 1, unit: "serving", name: "avocado", reading: .bareCount,
                boundName: "Avocado, Hass, peeled, raw", countedUnit: "each", byTypicalSize: true),
        // F4b: the Foundation creamy row states no portion; USDA's tablespoon (16 g, SR 174265) counts it.
        LinePin(line: "2 tbsp peanut butter", quantity: 2, unit: "tbsp", name: "peanut butter", reading: .stated,
                boundName: "Peanut butter, creamy", countedUnit: "tbsp", byTypicalSize: true),
        // The machine bind for "milk" is a cereal bar (its identity is "bar", not milk), so no typical size
        // applies and the line stays left out — a typical size never weighs a row that is not the ingredient.
        LinePin(line: "1 cup milk", quantity: 1, unit: "cup", name: "milk", reading: .stated,
                boundName: "Milk and cereal bar", countedUnit: nil),
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
            let own = bound.flatMap { row in
                parsed.candidateUnits(on: row).first {
                    RecipeIngredient(foodItemId: row.id, quantity: parsed.quantity, unit: $0).servingConversion(using: row) != nil
                }
            }
            let typical = own == nil ? bound.flatMap { row in
                parsed.candidateUnits(on: row).first { unit in
                    RecipeUnit.normalized(unit).flatMap { TypicalPortionTable.grams(quantity: parsed.quantity, unit: $0, for: row) } != nil
                }
            } : nil
            let counted = own ?? typical
            #expect(counted == pin.countedUnit, "\(pin.line): counted in \(counted ?? "nothing")")
            #expect((typical != nil) == pin.byTypicalSize, "\(pin.line): by typical size \(typical != nil)")
            #expect((RecipeWebImporter.estimatedMacros(for: parsed, catalog: catalog) != nil) == (pin.countedUnit != nil))
        }
        // Together: the page keeps every line that counts and says how many it left out (before F11 the
        // chips cup alone voided the estimate).
        let estimate = try #require(RecipeWebImporter.ingredientEstimate(Self.pins.map(\.line), servings: 4, catalog: catalog))
        #expect(estimate.uncountedLines == Self.pins.filter { $0.countedUnit == nil }.count)
        // …and how many it weighed by a USDA typical size, which the recipe now says too (F4b fix round
        // 1, finding s2-L-F4b-DT-3): those lines used to be left out and noted.
        #expect(estimate.estimatedLines == Self.pins.filter(\.byTypicalSize).count)
        #expect(estimate.estimatedLines > 0, "the pins include typical-size lines")
    }

    /// The typical-size count rides the import to the saved recipe's note (F4b fix round 1): an
    /// estimate built partly on typical sizes says so; one built on the rows' own data does not.
    @Test func aTypicalSizeLineIsCountedAsEstimated() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        let estimate = try #require(RecipeWebImporter.ingredientEstimate(
            ["3 cloves garlic, minced", "2 cups all-purpose flour", "2 large eggs"], servings: 1, catalog: catalog))
        #expect(estimate.uncountedLines == 0 && estimate.estimatedLines == 2, "\(estimate)")
        let imported = ImportedRecipe(sourceURL: try #require(URL(string: "https://example.com/r")), name: "Bread",
                                      ingredients: ["3 cloves garlic"], summary: "", servings: 1, protein: 1, carbs: 1, fat: 1,
                                      estimatedIngredientCount: estimate.estimatedLines)
        #expect(RecipeDefinition(importedRecipe: imported).webImport?.estimatedIngredientLines == 2)
        let own = try #require(RecipeWebImporter.ingredientEstimate(["2 large eggs"], servings: 1, catalog: catalog))
        #expect(own.estimatedLines == 0)
        let noTypical = ImportedRecipe(sourceURL: try #require(URL(string: "https://example.com/r")), name: "Eggs",
                                       ingredients: ["2 large eggs"], summary: "", servings: 1, protein: 1, carbs: 1, fat: 1)
        #expect(RecipeDefinition(importedRecipe: noTypical).webImport?.estimatedIngredientLines == nil, "no key written")
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
        #expect(line?.candidateUnits(on: ramen) == ["each"])
        #expect(line.flatMap { RecipeWebImporter.estimatedMacros(for: $0, catalog: catalog) } == nil)
        let estimate = RecipeWebImporter.ingredientEstimate(["2 large ramen", "200 g ramen", "salt to taste"],
                                                            servings: 2, catalog: catalog)
        #expect(estimate == IngredientMacroEstimate(protein: 5, carbs: 10, fat: 2, uncountedLines: 1),
                "the size-word line is left out and counted; a line with no amount joins neither side")
    }

    /// A bare count counts one serving only where that serving is one item (fix round 1, u3-L-U3-4):
    /// a label serving or a serving stated as a count, never SR's 100 g reference amount — "1 bay
    /// leaf" used to count 100 g of the spice (404 kcal) and "6 strawberries" 600 g.
    @Test func aBareCountCountsAServingOnlyWhereTheServingIsOneItem() {
        func row(_ name: String, _ size: Double, _ unit: String, _ type: FoodDataType,
                 _ source: FoodItemSource = .usda) -> FoodItem {
            var item = FoodItem(name: name, servingSize: size, servingUnit: unit,
                                macros: Macros(protein: 1, carbs: 20, fat: 4), micronutrients: Micronutrients(),
                                category: "Fixtures", source: source, tags: [])
            item.dataType = type
            return item
        }
        let reference = row("Spices, bay leaf", 100, "g", .srLegacy)
        let label = row("Bagels, branded", 95, "g", .branded)
        let sandwich = row("Sandwich, survey", 1, "sandwich", .survey)
        let dishCup = row("Stew, survey", 1, "cup", .survey)
        let own = row("My granola bar", 40, "g", .srLegacy, .manual)
        #expect(!ParsedIngredientLine.servingIsAnItem(reference))
        #expect(!ParsedIngredientLine.servingIsAnItem(dishCup))
        #expect(ParsedIngredientLine.servingIsAnItem(label))
        #expect(ParsedIngredientLine.servingIsAnItem(sandwich))
        #expect(ParsedIngredientLine.servingIsAnItem(own))
        let line = RecipeWebImporter.parseIngredientLine("1 bay leaf")
        #expect(line?.candidateUnits(on: reference) == ["each"])
        #expect(line?.candidateUnits(on: label) == ["each", "serving"])
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([reference]))
        #expect(RecipeWebImporter.ingredientEstimate(["1 bay leaf"], servings: 1, catalog: catalog) == nil,
                "no line counted — the estimate is nil, not 100 g of bay leaf")
    }

    /// A Unicode fraction is an amount (fix round 1, u3-L-U3-2): ICU's `\d` never matched "½", so
    /// "½ cup butter" had no leading amount and was dropped without being counted.
    @Test func aUnicodeFractionReadsAsItsAmount() throws {
        let cases: [(line: String, quantity: Double, unit: String, name: String)] = [
            ("½ cup butter", 0.5, "cup", "butter"), ("¾ cup sugar", 0.75, "cup", "sugar"),
            ("1½ cups flour", 1.5, "cup", "flour"), ("1 ½ cups flour", 1.5, "cup", "flour"),
            ("⅓ cup milk", 1.0 / 3.0, "cup", "milk"), ("1⁄2 tsp salt", 0.5, "tsp", "salt"),
            ("2¼ cups oats", 2.25, "cup", "oats"),
        ]
        for (line, quantity, unit, name) in cases {
            let parsed = try #require(RecipeWebImporter.parseIngredientLine(line), "\(line) no longer parses")
            #expect(abs(parsed.quantity - quantity) < 1e-9, "\(line): quantity is now \(parsed.quantity)")
            #expect(parsed.unit == unit, "\(line): unit is now \(parsed.unit)")
            #expect(parsed.name == name, "\(line): name is now \(parsed.name)")
        }
    }

    /// Every unit spelling the pattern matches is one the reader can use (fix round 1, u3-L-U3-3):
    /// "tbsps", "tsps" and a spaced-out "fl  oz" used to fall through to a bare count — two 100 g
    /// servings of oil for "2 tbsps olive oil".
    @Test func everyUnitSpellingThePatternMatchesIsRead() throws {
        let spellings = [
            "fluid ounce", "fluid  ounces", "extra large", "extra  small", "milliliter", "millilitres",
            "tablespoons", "kilogram", "milligrams", "teaspoon", "fl oz", "floz", "fl  oz", "FL OZ", "glass",
            "glasses", "ounces", "pound", "liters", "litre", "gram", "slices", "piece", "cloves", "medium",
            "large", "small", "whole", "tbsp", "tbsps", "Tbsps", "tsp", "tsps", "cup", "cups", "each", "lb",
            "lbs", "mg", "kg", "ml", "oz", "g", "l",
        ]
        for spelling in spellings {
            let parsed = try #require(RecipeWebImporter.parseIngredientLine("2 \(spelling) butter"), "\(spelling) no longer parses")
            #expect(parsed.unitReading != .bareCount, "\(spelling) is read as a bare count")
            #expect(parsed.name == "butter", "\(spelling): the name is now \(parsed.name)")
        }
        #expect(RecipeWebImporter.parseIngredientLine("2 tbsps olive oil")?.unit == "tbsp")
        #expect(RecipeWebImporter.parseIngredientLine("3 tsps baking powder")?.unit == "tsp")
        #expect(RecipeWebImporter.parseIngredientLine("8 fl  oz milk")?.unit == "fl oz")
        #expect(RecipeWebImporter.parseIngredientLine("8 fluid  ounces milk")?.unit == "fl oz")
    }

    /// A line that opens with an amount but cannot be read past it is counted as left out; a line with
    /// no amount still joins neither side (fix round 1, u3-L-U3-2).
    @Test func anAmountTheReaderCannotFinishIsCountedAsLeftOut() {
        let ramen = FoodItem(name: "Ramen", servingSize: 100, servingUnit: "g",
                             macros: Macros(protein: 5, carbs: 10, fat: 2), micronutrients: Micronutrients(),
                             category: "Fixtures", source: .usda, tags: [])
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([ramen]))
        #expect(RecipeWebImporter.parseIngredientLine("10 oz") == nil, "no name to search")
        #expect(RecipeWebImporter.startsWithAmount("  ½ something"))
        #expect(!RecipeWebImporter.startsWithAmount("salt to taste"))
        let estimate = RecipeWebImporter.ingredientEstimate(["200 g ramen", "10 oz", "½ cup ramen", "salt to taste"],
                                                            servings: 1, catalog: catalog)
        #expect(estimate?.uncountedLines == 2, "\"10 oz\" is an amount of nothing; \"½ cup\" of a row with no cup")
        #expect(estimate?.protein == 10)
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
