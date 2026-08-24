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
