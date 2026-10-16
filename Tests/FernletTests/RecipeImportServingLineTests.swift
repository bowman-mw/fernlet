// RecipeImportServingLineTests.swift
// FernletTests
//
// A shared recipe line counted in servings ("2 servings of pesto", or a line with no unit, which the
// importer reads as servings) must import at the sender's grams. Each `fernlet.recipe` ingredient
// carries the grams of the WHOLE line, and `FernletStore.importRecipe(from:id:)` mints a food holding
// exactly that line — `servingSize` = the line's quantity, `servingUnit` = its unit, `macros` = its
// grams — the same shape `CustomIngredientUpsert` mints for a custom row in the recipe editor, and the
// shape `RecipeEditorInputs` reopens (a custom food's grams ARE its row's grams).
//
// Since 2026-08-24 (0ba40d90) `RecipeServingConversion` has answered "N servings" as N of the food's
// declared serving without reading how many servings that declared serving holds, so a 2-serving line
// whose food declares "2 servings" counted 2 × 2 servings: every quantity-N serving line imported,
// re-shared, or typed in the editor counted N times its grams (and a re-share sent the inflated
// grams on, compounding per hop). A food whose serving is itself counted in servings now scales
// N servings by N / servingSize; every other food — every catalog row, whose serving-unit servings
// are all exactly 1 — keeps "N servings = N × its declared serving".

import Foundation
import Testing
import FernletDomainModel
import FernletExchange
import FoodCatalog
@testable import Fernlet

/// Pins that a shared or hand-typed recipe line counted in servings totals the sender's grams once,
/// across every import path that mints a food from a wire line, while catalog servings are unchanged.
struct RecipeImportServingLineTests {
    /// A 2-serving pesto line, a 2-slice bread line with a blank unit (read as servings), and a gram
    /// control line; each line's grams are the sender's totals for that line.
    static let sentLines = [
        SharedRecipeIngredient(name: "Pesto", quantity: 2, unit: "serving", protein: 20, carbs: 8, fat: 30),
        SharedRecipeIngredient(name: "Sourdough", quantity: 2, unit: "", protein: 10, carbs: 40, fat: 2),
        SharedRecipeIngredient(name: "Rolled oats", quantity: 80, unit: "g", protein: 10, carbs: 54, fat: 6),
    ]

    /// The sum of ``sentLines``' grams: what the recipe weighs on the sender's phone.
    static let sentTotals = MacroTotals(protein: 40, carbs: 102, fat: 38)

    /// Paste / mesh `.local` / Messages / `.fernletrecipe`: every one of them lands in
    /// `importRecipe(from:id:)`. The recipe totals the sender's grams, a serving is half of them, and
    /// the lines still read as the amounts the sender wrote.
    @MainActor
    @Test func aServingLineImportsAtTheSendersGrams() throws {
        let payload = SharedRecipePayload(name: "Pesto toast", servings: 2, notes: "", ingredients: Self.sentLines)
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        let store = makeTestStore()

        let imported = try store.importRecipe(from: text)

        let totals = store.macroTotals(for: imported)
        #expect(totals == Self.sentTotals, "imported totals \(totals), sent \(Self.sentTotals)")
        let meal = try #require(MealBuilder.mealFromRecipe(imported, mealType: .lunch,
                                                           foodItems: store.foodCatalog.items(forRecipe: imported)))
        #expect(meal.macros == Macros(protein: 20, carbs: 51, fat: 19), "one serving logs \(meal.macros)")
        #expect(imported.ingredients.map(\.quantity) == [2, 2, 80])
        #expect(imported.ingredients.map(\.unit) == ["serving", "serving", "g"])
    }

    /// The `.fernletrecipe` file (Shortcuts) and the Messages card carry the exchange packet's recipe,
    /// which the exchange service re-encodes into the same import.
    @MainActor
    @Test func anExchangePacketsServingLineImportsAtTheSendersGrams() throws {
        let sender = makeTestStore()
        let sent = try sender.importRecipe(from: String(decoding: try JSONEncoder().encode(
            SharedRecipePayload(name: "Pesto toast", servings: 2, notes: "", ingredients: Self.sentLines)), as: UTF8.self))
        let packet = try RecipeExchangePacket(recipe: sent, foodItems: sender.foodCatalog.items(forRecipe: sent),
                                              includesNotes: true)
        #expect(packet.recipe.ingredients.map(\.protein) == [20, 10, 10], "the packet re-sends the sender's grams")

        let receiver = makeTestStore()
        let text = String(decoding: try JSONEncoder().encode(packet.recipe), as: UTF8.self)
        let imported = try receiver.importRecipe(from: text, id: packet.originContentID)
        #expect(receiver.macroTotals(for: imported) == Self.sentTotals)
    }

    /// Nearby sharing from a recipe built on a catalog food served per serving: the receiver totals
    /// what the sender's phone shows, and sharing it on again sends the same grams (no growth per hop).
    @MainActor
    @Test func aMeshShareOfServingLinesKeepsItsGramsAcrossHops() throws {
        let hummus = FoodItem(name: "Hummus", servingSize: 1, servingUnit: RecipeUnit.serving.rawValue,
                              macros: Macros(protein: 2, carbs: 4, fat: 5), micronutrients: Micronutrients(),
                              category: "test", source: .usda, tags: [])
        let recipe = RecipeDefinition(name: "Mezze", servings: 1,
                                      ingredients: [RecipeIngredient(foodItemId: hummus.id, quantity: 3, unit: "serving")],
                                      notes: "", source: "manual", createdAt: Date(), updatedAt: Date())
        let senderTotals = MealBuilder.macroTotals(for: recipe, foodItems: [hummus])
        #expect(senderTotals == MacroTotals(protein: 6, carbs: 12, fat: 15))

        let firstHop = makeTestStore()
        try firstHop.importProximityRecipeShare(RecipeShareCodec.proximityPayload(for: recipe, foodItems: [hummus]))
        let received = try #require(firstHop.recipes.first)
        #expect(firstHop.macroTotals(for: received) == senderTotals)

        let onward = RecipeShareCodec.payload(for: received, foodItems: firstHop.foodCatalog.items(forRecipe: received))
        #expect(onward.ingredients.map(\.protein) == [6], "re-shared grams \(onward.ingredients.map(\.protein))")
        let secondHop = makeTestStore()
        let reReceived = try secondHop.importRecipe(from: String(decoding: try JSONEncoder().encode(onward), as: UTF8.self))
        #expect(secondHop.macroTotals(for: reReceived) == senderTotals)
    }

    /// The recipe editor mints a custom row's food in the same shape (its amount as the serving, its
    /// typed grams as the food's), so "2 servings, 20 g protein" totals 20 g, not 40.
    @MainActor
    @Test func anEditorCustomServingRowTotalsItsTypedGrams() {
        var foods: [FoodItem] = []
        let lines = CustomIngredientUpsert.recipeIngredients(
            from: [ManualRecipeIngredientInput(name: "Pesto", quantity: 2, unit: "serving", protein: 20, carbs: 8, fat: 30),
                   ManualRecipeIngredientInput(name: "Sourdough", quantity: 3, unit: "servings", protein: 15, carbs: 60, fat: 3)],
            in: &foods, verifiedAt: Date())
        let recipe = RecipeDefinition(name: "Pesto toast", servings: 1, ingredients: lines, notes: "",
                                      source: "manual", createdAt: Date(), updatedAt: Date())
        let totals = MealBuilder.macroTotals(for: recipe, foodItems: foods)
        #expect(totals == MacroTotals(protein: 35, carbs: 68, fat: 33), "editor totals \(totals)")
    }

    /// The control: "N servings" of a food whose serving is NOT counted in servings — grams, an IU or
    /// survey-unit serving, and a catalog row served per one serving — is still N × that serving; a
    /// food declaring S servings scales N servings by N / S.
    @Test func catalogServingsKeepTheirMeaning() throws {
        func scale(_ quantity: Double, servingsOf size: Double, _ unit: String) throws -> Double {
            let food = FoodItem(name: "Fixture", servingSize: size, servingUnit: unit,
                                macros: Macros(protein: 10, carbs: 10, fat: 10), micronutrients: Micronutrients(),
                                category: "test", source: .usda, tags: [])
            let line = RecipeIngredient(foodItemId: food.id, quantity: quantity, unit: RecipeUnit.serving.rawValue)
            return try #require(line.servingConversion(using: food)).servingScale
        }
        #expect(try scale(2, servingsOf: 100, "g") == 2, "2 servings of a 100 g serving is 200 g")
        #expect(try scale(2, servingsOf: 250, "IU") == 2)
        #expect(try scale(2, servingsOf: 1, "sandwich") == 2)
        #expect(try scale(2, servingsOf: 1, "serving") == 2)
        #expect(try scale(3, servingsOf: 1, "Servings") == 3)
        #expect(try scale(2, servingsOf: 2, "serving") == 1)
        #expect(try scale(1, servingsOf: 4, "servings") == 0.25)
    }
}
