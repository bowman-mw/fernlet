// RecipeImportIngredientLineTests.swift
// FernletTests
//
// F10 of Docs/Ingredient-Search-Deep-Research-2026-09-29.md, third instrument: what the web recipe
// importer's USDA fallback does with five everyday ingredient lines (report §3.5).
//
// `RecipeWebImporter.parseIngredient`'s unit alternation lists "l" before "large"/"liters" and "g"
// before "grams"/"glasses", and `\s*` lets the unit swallow the first letter of the food: "2 large
// eggs" parses as 2 "l" of "arge eggs". The mangled name matches nothing, so the line is silently
// skipped and the estimate undercounts. A line that does parse can still void the whole page: "1 cup
// chocolate chips" binds a chip cookie whose only portion is a 22 g bar, "cup" cannot convert, and
// `estimateMacrosFromIngredients` returns nil for everything.
//
// These pins photograph TODAY'S WRONG ANSWERS on purpose, so the parser fix (F11) flips them in a
// deliberate, reviewable edit rather than a silent drift. Against the shipped catalog, cold.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import AIProviders

/// Today's parse and bind of five everyday recipe lines through the web importer's USDA fallback.
struct RecipeImportIngredientLineTests {
    /// One pinned line: what `parseIngredient` returns, what that name binds in the shipped catalog
    /// (`nil` when the mangled name matches nothing), and whether the parsed amount converts on it.
    struct LinePin: Sendable {
        /// The recipe line, a frozen English matching input.
        let line: String
        /// Parsed quantity.
        let quantity: Double
        /// Parsed unit token.
        let unit: String
        /// Parsed (cleaned) food name.
        let name: String
        /// The catalog row the importer binds (`results(for:limit: 1, context: .machineGenerated)`).
        let boundName: String?
        /// Whether the parsed amount converts on that row; nil when nothing binds.
        let converts: Bool?
    }

    /// Four of five are wrong today (report §3.5); the chips line parses but voids the page.
    static let pins: [LinePin] = [
        LinePin(line: "2 large eggs", quantity: 2, unit: "l", name: "arge eggs", boundName: nil, converts: nil),
        LinePin(line: "100 grams flour", quantity: 100, unit: "g", name: "rams flour", boundName: nil, converts: nil),
        LinePin(line: "1 lemon", quantity: 1, unit: "l", name: "emon", boundName: nil, converts: nil),
        LinePin(line: "2 garlic cloves", quantity: 2, unit: "g", name: "arlic cloves", boundName: nil, converts: nil),
        LinePin(line: "1 cup chocolate chips", quantity: 1, unit: "cup", name: "chocolate chips",
                boundName: "Cookies, marshmallow, with rice cereal and chocolate chips", converts: false)
    ]

    @Test func everydayLinesParseToTheirPinnedAnswers() throws {
        for pin in Self.pins {
            let parsed = try #require(RecipeWebImporter.parseIngredient(pin.line), "\(pin.line) no longer parses")
            #expect(parsed.quantity == pin.quantity, "\(pin.line): quantity")
            #expect(parsed.unit == pin.unit, "\(pin.line): unit is now \(parsed.unit)")
            #expect(parsed.name == pin.name, "\(pin.line): name is now \(parsed.name)")
        }
    }

    @Test func everydayLinesBindAndConvertToTheirPinnedAnswers() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        for pin in Self.pins {
            let bound = catalog.results(for: pin.name, limit: 1, context: .machineGenerated).first
            #expect(bound?.name == pin.boundName, "\(pin.line) now binds \(bound?.name ?? "nothing")")
            let converts = bound.map {
                RecipeIngredient(foodItemId: $0.id, quantity: pin.quantity, unit: pin.unit).servingConversion(using: $0) != nil
            }
            #expect(converts == pin.converts, "\(pin.line): conversion is now \(String(describing: converts))")
        }
        // Together: four lines skipped, one voiding the page — no estimate at all.
        #expect(RecipeWebImporter.estimateMacrosFromIngredients(
            Self.pins.map(\.line), servings: 4, catalog: catalog
        ) == nil)
    }

    /// The control: a line the parser handles today still estimates, so the nil above is the lines,
    /// not a broken fallback.
    @Test func aCleanLineStillEstimates() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount >= FoodSearchCorpusTests.shippedRowCount, "the shipped catalog must be loaded")
        #expect(RecipeWebImporter.estimateMacrosFromIngredients(["100 g butter"], servings: 1, catalog: catalog) != nil)
    }
}
