// GroceryListComposerTests.swift
// F3 — the app-target composer (catalog resolution + F4 scaling + web-import routing) and the
// buildDataExport coverage of the new FernletDay.plannedRecipeIDs plan field.

import XCTest
import FernletDomainModel
@testable import Fernlet

@MainActor
final class GroceryListComposerTests: XCTestCase {

    private func food(_ name: String, id: UUID) -> FoodItem {
        FoodItem(
            id: id, name: name, brandSource: nil, servingSize: 100, servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 1, carbs: 1, fat: 1), micronutrients: Micronutrients(),
            category: "Test", source: .usda, tags: [name.lowercased()])
    }

    private func recipe(_ name: String, ingredients: [RecipeIngredient], servings: Int = 2) -> RecipeDefinition {
        RecipeDefinition(name: name, servings: servings, ingredients: ingredients,
                         source: "test", createdAt: Date(), updatedAt: Date())
    }

    // MARK: - Structured resolution + merge through the composer

    func testStructuredRecipesResolveAndMergeAcrossSelections() {
        let brothID = UUID()
        let broth = food("Broth", id: brothID)
        let store = makeTestStore(bundledFoodItems: [broth])
        let a = recipe("Soup", ingredients: [RecipeIngredient(foodItemId: brothID, quantity: 2, unit: "cup")])
        let b = recipe("Stew", ingredients: [RecipeIngredient(foodItemId: brothID, quantity: 1, unit: "cup")])

        let list = store.groceryList(for: [.init(recipe: a), .init(recipe: b)])
        XCTAssertEqual(list.consolidated.count, 1)
        XCTAssertEqual(list.consolidated.first, GroceryAggregation.Line(name: "Broth", quantity: 3, unit: "cup"))
    }

    // MARK: - Scaled-yield aggregation

    func testCookForNScalesConsolidatedQuantities() {
        let riceID = UUID()
        let store = makeTestStore(bundledFoodItems: [food("Rice", id: riceID)])
        let r = recipe("Rice bowl", ingredients: [RecipeIngredient(foodItemId: riceID, quantity: 1, unit: "cup")], servings: 2)

        // Base yield 2 → cook for 4 doubles the 1-cup ingredient to 2 cups.
        let scaled = store.groceryList(for: [.init(recipe: r, yieldOverride: 4)])
        XCTAssertEqual(scaled.consolidated.first, GroceryAggregation.Line(name: "Rice", quantity: 2, unit: "cup"))

        // No override keeps the base quantity.
        let base = store.groceryList(for: [.init(recipe: r)])
        XCTAssertEqual(base.consolidated.first, GroceryAggregation.Line(name: "Rice", quantity: 1, unit: "cup"))
    }

    // MARK: - Web imports become per-recipe sections

    func testWebImportRecipeBecomesFreeTextSection() {
        let store = makeTestStore()
        let web = RecipeDefinition(
            name: "Grandma's Cake", servings: 8, ingredients: [], source: "web",
            createdAt: Date(), updatedAt: Date(),
            webImport: RecipeWebImport(sourceURLString: "https://example.com",
                                       ingredientLines: ["2 cups flour", "3 eggs"],
                                       macros: Macros(protein: 0, carbs: 0, fat: 0),
                                       micronutrients: Micronutrients()))
        let list = store.groceryList(for: [.init(recipe: web)])
        XCTAssertTrue(list.consolidated.isEmpty)
        XCTAssertEqual(list.recipeSections.count, 1)
        XCTAssertEqual(list.recipeSections.first?.recipeName, "Grandma's Cake")
        XCTAssertEqual(list.recipeSections.first?.lines, ["2 cups flour", "3 eggs"])
        // A web import cannot be scaled: a yield override is ignored, not applied to free-text.
        let scaled = store.groceryList(for: [.init(recipe: web, yieldOverride: 24)])
        XCTAssertEqual(scaled.recipeSections.first?.lines, ["2 cups flour", "3 eggs"])
    }

    // MARK: - Planner selection resolution (dangling drop + dedupe)

    func testGrocerySelectionsDropDanglingAndDeduplicate() {
        let idA = UUID(), idB = UUID()
        let store = makeTestStore()
        store.recipes = [recipe("A", ingredients: []), recipe("B", ingredients: [])]
        store.recipes[0].id = idA
        store.recipes[1].id = idB
        let dangling = UUID()

        // idA appears twice (planned on two days), plus a since-deleted recipe id.
        let selections = store.grocerySelections(forPlannedRecipeIDs: [idA, dangling, idA, idB])
        XCTAssertEqual(selections.map(\.recipe.id), [idA, idB])
    }

    // MARK: - Re-planning updates the meal slot (FOOD-35 picker re-pick)

    /// Planning an already-planned recipe again must UPDATE the typed entry's meal slot in place —
    /// never a silent no-op (the picker lists planned recipes and forces a slot choice, so a
    /// re-pick IS a slot change) and never a duplicated legacy id. Also pins the legacy upgrade:
    /// a slotless entry acquires the picked slot.
    func testReplanUpdatesMealSlotWithoutDuplicatingLegacyID() {
        let store = makeTestStore()
        let id = UUID()

        // A slotless (legacy-facade) plan, then a re-pick with a slot: the entry acquires it.
        store.planRecipe(id, date: store.todayKey)
        store.planRecipe(id, mealType: .dinner, date: store.todayKey)
        var day = store.loadDay(for: store.todayKey)
        XCTAssertEqual(day.plannedRecipeIDs, [id], "the legacy id must never duplicate")
        XCTAssertEqual(day.plannedMeals?.map(\.mealType), [.dinner],
                       "a slotless entry must acquire the picked slot")

        // A second re-pick changes the slot in place — still one typed entry, one legacy id.
        store.planRecipe(id, mealType: .lunch, date: store.todayKey)
        day = store.loadDay(for: store.todayKey)
        XCTAssertEqual(day.plannedRecipeIDs, [id], "a slot change must not re-append the legacy id")
        XCTAssertEqual(day.plannedMeals?.map(\.mealType), [.lunch],
                       "a re-pick must update the slot, not silently no-op")
    }

    // MARK: - Export coverage of the plan field

    func testExportCoversPlannedMeals() {
        let store = makeTestStore()
        var r = recipe("Chili", ingredients: [])
        let id = UUID()
        r.id = id
        store.recipes = [r]
        store.planRecipe(id, date: store.todayKey)

        let export = store.buildDataExport()
        let today = export.days.first { $0.day == store.todayKey }
        XCTAssertEqual(today?.plannedMeals, ["Chili"])
    }

    func testExportDropsDanglingPlannedRecipe() {
        let store = makeTestStore()
        // Plan an id that has no matching recipe in either store: it resolves to no name and drops.
        store.planRecipe(UUID(), date: store.todayKey)

        let export = store.buildDataExport()
        let today = export.days.first { $0.day == store.todayKey }
        // The day is exported (a plan is logged content), but the dangling plan yields no plannedMeals.
        XCTAssertNil(today?.plannedMeals)
    }

    // MARK: - Share text golden through the composer

    func testShareTextGoldenThroughComposer() {
        let brothID = UUID()
        let store = makeTestStore(bundledFoodItems: [food("Broth", id: brothID)])
        let r = recipe("Soup", ingredients: [RecipeIngredient(foodItemId: brothID, quantity: 2, unit: "cup")])
        let text = store.groceryListText(for: [.init(recipe: r)], title: "Shopping list")
        XCTAssertEqual(text, """
        Shopping list

        - Broth (2 cup)
        """)
    }
}
