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

    // MARK: - Per-food unit menu (ingredient-search round F4b, 2026-09-30)

    /// A banana taps to one medium (118 g), and its cup is a CHOICE in the unit menu — USDA's sliced
    /// (150 g) or mashed (225 g) — where the editor used to refuse "1 cup" outright.
    @MainActor
    func testRecipeBananaCupIsAChoiceInTheUnitMenu() {
        let app = UXTestApp.launch(openSheet: "recipe")
        let search = app.descendants(matching: .any)["recipeIngredient.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        enter("banana", in: search, app: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Bananas, raw")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        let caption = app.staticTexts["recipeIngredient.householdAmount"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        XCTAssertEqual(caption.label, "Counted as 1 medium (118 g)")

        let menu = app.descendants(matching: .any)["recipeIngredient.unit"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        // VoiceOver hears the choice, not just "Unit" (fix round 1, s2-C-F4B-C5 / s2-L-F4b-DT-4).
        XCTAssertEqual(menu.value as? String, "1 medium (118 g)")
        menu.tap()
        let sliced = app.buttons["1 cup, sliced (150 g)"].firstMatch
        XCTAssertTrue(sliced.waitForExistence(timeout: 3), "the banana's own cups are listed")
        XCTAssertTrue(app.buttons["1 cup, mashed (225 g)"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Cups"].firstMatch.exists, "a cup that cannot convert on its own is hidden")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "banana-unit-menu"
        shot.lifetime = .keepAlways
        add(shot)
        sliced.tap()
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        XCTAssertEqual(caption.label, "Counted as 1 cup, sliced (150 g)")

        // Picking Grams keeps the weight (fix round 1, s2-C-F4B-C1): 150 g, never "1 g".
        menu.tap()
        let grams = app.buttons["Grams"].firstMatch
        XCTAssertTrue(grams.waitForExistence(timeout: 3))
        grams.tap()
        let quantity = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Qty")).firstMatch
        XCTAssertTrue(quantity.waitForExistence(timeout: 3))
        XCTAssertEqual(quantity.value as? String, "150")
        XCTAssertEqual(menu.value as? String, "Grams")
    }

    /// USDA's Hass avocado row states only a reference amount, so the menu offers USDA's typical
    /// California avocado (136 g, SR 171706) — badged as an estimate, with its grams editable.
    @MainActor
    func testRecipeAvocadoOffersATypicalSizeEstimate() {
        let app = UXTestApp.launch(openSheet: "recipe")
        let search = app.descendants(matching: .any)["recipeIngredient.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        enter("avocado", in: search, app: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Avocado, Hass, peeled, raw")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        let menu = app.descendants(matching: .any)["recipeIngredient.unit"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let fruit = app.buttons["1 fruit (136 g)"].firstMatch
        XCTAssertTrue(fruit.waitForExistence(timeout: 3), "the typical size is offered where the row states none")
        fruit.tap()

        XCTAssertTrue(app.staticTexts["recipeIngredient.portionBadge"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["recipeIngredient.portionBadge"].firstMatch.label, "USDA typical size, estimate")
        XCTAssertTrue(app.textFields["recipeIngredient.portionGrams"].firstMatch.exists, "the estimate's grams are editable")
        XCTAssertEqual(app.staticTexts["recipeIngredient.householdAmount"].firstMatch.label, "Counted as 1 fruit (136 g)")
        XCTAssertEqual(menu.value as? String, "1 fruit (136 g), USDA typical size, estimate",
                       "the closed menu says it is an estimate to VoiceOver too")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "avocado-typical-size"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Report §6.3 Rung E (fix round 1): USDA's almond flour states nothing to count, so the unit menu
    /// asks "How many grams is one?"; the answer counts the row in the person's own size.
    @MainActor
    func testRecipeAlmondFlourAsksHowManyGramsIsOne() {
        let app = UXTestApp.launch(openSheet: "recipe")
        let search = app.descendants(matching: .any)["recipeIngredient.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        enter("almond flour", in: search, app: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Flour, almond")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()

        let menu = app.descendants(matching: .any)["recipeIngredient.unit"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        menu.tap()
        let ask = app.buttons["How many grams is one?"].firstMatch
        XCTAssertTrue(ask.waitForExistence(timeout: 3), "nothing on the menu counts, so it asks")
        ask.tap()

        let field = app.textFields["recipeIngredient.askGrams"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        enter("150", in: field, app: app)
        let quantity = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Qty")).firstMatch
        quantity.tap()  // focus loss commits the typed grams

        let caption = app.staticTexts["recipeIngredient.householdAmount"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        XCTAssertEqual(caption.label, "Counted as 1 item (150 g)")
        XCTAssertEqual(app.staticTexts["recipeIngredient.portionBadge"].firstMatch.label, "Your size")
        XCTAssertEqual(menu.value as? String, "1 item (150 g), your size")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "almond-flour-grams-for-one"
        shot.lifetime = .keepAlways
        add(shot)
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
