import XCTest

/// Focused interaction coverage for the meal composer's catalog front door and deterministic miss.
final class FoodComposerSearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCatalogResultCanBeStagedBeforeSave() {
        let app = UXTestApp.launch(openSheet: "meal")
        let search = app.descendants(matching: .any)["mealComposer.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))

        enter("apple", in: search, app: app)

        let results = app.descendants(matching: .any)["mealComposer.catalogResults"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 8))
        results.tap()

        let selection = app.descendants(matching: .any)["mealComposer.selectedCatalogFood"].firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 3))

        let change = app.buttons["mealComposer.changeCatalogSelection"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(change.frame.height, 44)
        change.tap()
        XCTAssertTrue(results.waitForExistence(timeout: 8))
        XCTAssertFalse(selection.exists)
    }

    @MainActor
    func testEditedQueryMakesSettledRowsImmediatelyUntappable() {
        let app = UXTestApp.launch(openSheet: "meal")
        let search = app.descendants(matching: .any)["mealComposer.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))

        enter("apple", in: search, app: app)
        let results = app.descendants(matching: .any)["mealComposer.catalogResults"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 8))

        search.tap()
        search.typeText(" zzznotfood")
        XCTAssertTrue(app.descendants(matching: .any)["mealComposer.catalogMiss"].firstMatch
            .waitForExistence(timeout: 8))
        XCTAssertFalse(results.exists)
        XCTAssertFalse(app.descendants(matching: .any)["mealComposer.selectedCatalogFood"].firstMatch.exists)
    }

    @MainActor
    func testCatalogMissOffersManualMacros() {
        let app = UXTestApp.launch(openSheet: "meal")
        let search = app.descendants(matching: .any)["mealComposer.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))

        enter("zzzzzzzznotfood", in: search, app: app)

        let miss = app.descendants(matching: .any)["mealComposer.catalogMiss"].firstMatch
        XCTAssertTrue(miss.waitForExistence(timeout: 8))
        app.buttons["Enter macros by hand"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Protein"].firstMatch.waitForExistence(timeout: 3))
    }

    // MARK: - Decimal ingredient grams (2026-09-29)

    /// A custom recipe ingredient's protein takes "3.4" on the decimal pad and the row shows it back.
    @MainActor
    func testRecipeCustomIngredientTakesDecimalGrams() {
        let app = UXTestApp.launch(openSheet: "recipe")
        enterCustomIngredientProtein("3.4", expecting: "3.4g", app: app)
    }

    /// The same entry with a German number format: the decimal pad's key is a comma, "3,4" commits
    /// 3.4 g, and the row shows it back in the locale's own spelling.
    @MainActor
    func testRecipeCustomIngredientTakesALocaleDecimalComma() {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding", "-AppleLocale", "de_DE"]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_OPEN_SHEET"] = "recipe"
        app.launch()
        UXTestApp.waitForLaunchHandover(app, openSheet: "recipe")
        enterCustomIngredientProtein("3,4", expecting: "3,4g", app: app)
    }

    /// Settles a catalog miss in the recipe editor's first ingredient, types `typed` into Protein, and
    /// moves focus to Carbs (focus loss is when a macro row commits).
    @MainActor
    private func enterCustomIngredientProtein(_ typed: String, expecting shown: String, app: XCUIApplication) {
        let search = app.descendants(matching: .any)["recipeIngredient.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        enter("zzqq house granola", in: search, app: app)
        let create = app.buttons["Create custom ingredient"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 8))
        create.tap()

        let protein = app.buttons["0g"].firstMatch
        XCTAssertTrue(protein.waitForExistence(timeout: 3))
        protein.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        app.typeText(typed)
        app.buttons["0g"].firstMatch.tap()

        XCTAssertTrue(app.buttons[shown].firstMatch.waitForExistence(timeout: 3),
                      "Protein should read \(shown) after typing \(typed)")
    }

    @MainActor
    private func enter(_ text: String, in field: XCUIElement, app: XCUIApplication) {
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            field.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        field.typeText(text)
    }
}
