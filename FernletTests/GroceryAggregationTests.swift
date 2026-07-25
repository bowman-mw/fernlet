// GroceryAggregationTests.swift
// F3 — the pure, below-the-wall shopping-list aggregation engine (§4.4) and the tolerant
// `FernletDay.plannedRecipeIDs` day-row field (Phase B). No store, no catalog — value-level only.

import Foundation
import Testing
import FernletDomainModel

struct GroceryAggregationTests {
    private func item(_ name: String, _ qty: Double, _ unit: String, id: UUID = UUID()) -> GroceryAggregation.StructuredItem {
        GroceryAggregation.StructuredItem(foodItemId: id, name: name, quantity: qty, unit: unit)
    }

    // MARK: - Merge rules

    @Test func sameFoodSameUnitSums() {
        let id = UUID()
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "A", structured: [item("Broth", 2, "cup", id: id)]),
            .init(recipeName: "B", structured: [item("Broth", 1.5, "cup", id: id)]),
        ])
        #expect(list.consolidated.count == 1)
        #expect(list.consolidated.first == GroceryAggregation.Line(name: "Broth", quantity: 3.5, unit: "cup"))
        #expect(list.consolidated.first?.display == "Broth (3.5 cup)")
    }

    @Test func incompatibleUnitsKeepSeparateLines() {
        let id = UUID()
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "A", structured: [item("Flour", 1, "cup", id: id)]),
            .init(recipeName: "B", structured: [item("Flour", 200, "g", id: id)]),
        ])
        // Same food, but cup and gram are not compatible under RecipeUnit.normalized → two lines.
        #expect(list.consolidated.count == 2)
        #expect(list.consolidated.contains(GroceryAggregation.Line(name: "Flour", quantity: 1, unit: "cup")))
        #expect(list.consolidated.contains(GroceryAggregation.Line(name: "Flour", quantity: 200, unit: "g")))
    }

    @Test func nameFallbackMergesDifferentIDsSameName() {
        // Two different foodItemIds (e.g. custom-ingredient upserts) that resolve to the same name must
        // still collapse via the FoodItemSearch.normalized name fallback key.
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "A", structured: [item("Olive Oil", 2, "tbsp", id: UUID())]),
            .init(recipeName: "B", structured: [item("olive  oil", 3, "tbsp", id: UUID())]),
        ])
        #expect(list.consolidated.count == 1)
        #expect(list.consolidated.first?.quantity == 5)
        #expect(list.consolidated.first?.unit == "tbsp")
    }

    @Test func rawUSDACodeUnitsAreNeverSummed() {
        // RecipeUnit.normalized returns nil for raw USDA codes (GRM/MLT/...); such lines must NOT be
        // summed (silently adding grams-as-code), they stay separate.
        let id = UUID()
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "A", structured: [item("Sugar", 50, "GRM", id: id)]),
            .init(recipeName: "B", structured: [item("Sugar", 30, "GRM", id: id)]),
        ])
        #expect(list.consolidated.count == 2)
        #expect(list.consolidated.allSatisfy { $0.unit == "GRM" })
    }

    @Test func webImportRecipesGoUnderPerRecipeSections() {
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "Grandma's Cake", freeTextLines: ["2 cups flour", "3 eggs", "   "]),
        ])
        #expect(list.consolidated.isEmpty)
        #expect(list.consolidated.count == 0)
        #expect(list.recipeSections.count == 1)
        #expect(list.recipeSections.first?.recipeName == "Grandma's Cake")
        // Blank/whitespace-only lines are filtered out.
        #expect(list.recipeSections.first?.lines == ["2 cups flour", "3 eggs"])
    }

    @Test func emptyWebImportProducesNoSection() {
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "Empty", freeTextLines: ["   ", ""]),
        ])
        #expect(list.recipeSections.isEmpty)
    }

    @Test func unresolvableItemKeepsMeasureOnlyLine() {
        // A structured ingredient whose food couldn't be resolved (empty name) still contributes a
        // measure-only line rather than vanishing.
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "A", structured: [item("", 4, "each")]),
        ])
        #expect(list.consolidated.count == 1)
        #expect(list.consolidated.first?.display == "4 each")
    }

    // MARK: - Scaled-yield aggregation (composition with RecipeScaling)

    @Test func scaledYieldDoublesConsolidatedQuantities() {
        // Feeding RecipeScaling.scaledIngredients output into the engine composes: a recipe cooked for
        // twice its base yield contributes doubled quantities. (The composer does this resolution; here
        // we prove the value-level composition.)
        let recipe = RecipeDefinition(
            name: "Rice bowl", servings: 2,
            ingredients: [RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "cup")],
            source: "test", createdAt: Date(), updatedAt: Date())
        let scaled = RecipeScaling.scaledIngredients(recipe, forYield: 4)   // 2x
        #expect(scaled.first?.quantity == 2)
        let id = recipe.ingredients[0].foodItemId
        let list = GroceryAggregation.build(from: [
            .init(recipeName: recipe.name,
                  structured: scaled.map { item("Rice", $0.quantity, $0.unit, id: id) }),
        ])
        #expect(list.consolidated.first == GroceryAggregation.Line(name: "Rice", quantity: 2, unit: "cup"))
    }

    // MARK: - Plain-text golden

    @Test func plainTextGoldenLayout() {
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "Soup", structured: [item("Broth", 2, "cup"), item("Salt", 1, "tsp")]),
            .init(recipeName: "Web Cake", freeTextLines: ["2 cups flour", "3 eggs"]),
        ])
        let text = GroceryAggregation.plainText(list)
        #expect(text == """
        Shopping list

        - Broth (2 cup)
        - Salt (1 tsp)

        Web Cake
        - 2 cups flour
        - 3 eggs
        """)
    }

    @Test func plainTextTitleOverrideAndConsolidatedOnly() {
        let list = GroceryAggregation.build(from: [
            .init(recipeName: "Soup", structured: [item("Broth", 2, "cup")]),
        ])
        #expect(GroceryAggregation.plainText(list, title: "This week") == """
        This week

        - Broth (2 cup)
        """)
    }

    // MARK: - FernletDay.plannedRecipeIDs round-trip / tolerant decode

    @Test func plannedRecipeIDsRoundTrip() throws {
        let ids = [UUID(), UUID()]
        var day = FernletDay(date: "2026-07-24")
        day.plannedRecipeIDs = ids
        let decoded = try JSONDecoder().decode(FernletDay.self, from: JSONEncoder().encode(day))
        #expect(decoded.plannedRecipeIDs == ids)
    }

    @Test func plannedRecipeIDsAbsentDecodesToEmpty() throws {
        // A day written before F3 has no plannedRecipeIDs key: tolerant decodeIfPresent → [], never a
        // decode failure (which inside the blob bricks the store; inside a DayRecord drops the row).
        let day = try JSONDecoder().decode(FernletDay.self, from: Data("""
        {"date": "2026-07-24", "bottleCount": 2}
        """.utf8))
        #expect(day.plannedRecipeIDs.isEmpty)
        #expect(day.bottleCount == 2)
    }

    @Test func plannedRecipeIDsPresentDecodes() throws {
        let id = UUID()
        let day = try JSONDecoder().decode(FernletDay.self, from: Data("""
        {"date": "2026-07-24", "plannedRecipeIDs": ["\(id.uuidString)"]}
        """.utf8))
        #expect(day.plannedRecipeIDs == [id])
        #expect(day.hasLoggedContent)   // a plan-only day counts as content, mirroring plannedWorkouts
    }
}
