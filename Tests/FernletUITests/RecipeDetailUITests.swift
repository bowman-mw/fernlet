import XCTest

/// Tail #1 — the recipe detail view. Opens the recipe book and taps a seeded recipe, which now pushes a
/// read-only detail (photo, per-serving macros, ingredients, notes) instead of jumping into the editor.
/// Verifies the detail renders with its log + add-photo affordances, and screenshots it.
final class RecipeDetailUITests: XCTestCase {
    @MainActor
    func testRecipeRowOpensDetailView() {
        let app = UXTestApp.launch()  // Home, demo-seeded (seeds "Overnight oats" + another recipe)

        app.buttons["Food"].firstMatch.tap()

        let recipeBook = app.buttons["Recipe book"]
        for _ in 0..<8 where !recipeBook.isHittable { app.swipeUp() }
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food")
        recipeBook.tap()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found in the book")
        row.tap()

        // The detail view: nav title, the log action, the ingredients, and the add-photo affordance.
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 6), "recipe detail did not open")
        XCTAssertTrue(app.buttons["recipeDetail.log"].waitForExistence(timeout: 4), "detail is missing the log action")
        XCTAssertTrue(app.buttons["recipeDetail.addPhoto"].waitForExistence(timeout: 4), "detail is missing the add-photo affordance")
        // Ingredient names resolved (seeded oats recipe lists Rolled oats / Greek yogurt / Blueberries).
        let ingredient = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "oats")).firstMatch
        XCTAssertTrue(ingredient.waitForExistence(timeout: 4), "ingredient lines did not render")

        UXScreenProbe(app, "Food · Recipe detail", in: self).capture()
    }

    /// The Food page's own Recipes section used to jump straight into the editor on tap; it now pushes
    /// the same read-only detail as the recipe book, so every recipe row behaves identically.
    @MainActor
    func testFoodPageRecipeRowOpensDetailView() {
        let app = UXTestApp.launch()  // Home, demo-seeded (seeds "Overnight oats" in the Recipes section)

        app.buttons["Food"].firstMatch.tap()

        // The recipe row in the Food page's Recipes section (NOT the "Recipe book" button).
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found in the Food page Recipes section")
        row.tap()

        // Tapping now pushes the detail rather than presenting the editor sheet.
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 6), "recipe detail did not open from the Food page")
        XCTAssertTrue(app.buttons["recipeDetail.log"].waitForExistence(timeout: 4), "detail is missing the log action")
    }
}
