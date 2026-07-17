import XCTest

/// Item creation now splits in two: the editor is just the drawing (with a "Next" bar), and NAMING +
/// shop-listing move to a follow-up confirmation screen. This drives the path to the editor (the
/// customization sheet is opened via a launch hook — its real entry is a long-press XCUITest can't send)
/// and asserts the name/shop controls are NO LONGER on the editor and that it leads to a Next step.
///
/// The confirmation screen itself is only reachable after painting (Next stays disabled on a blank
/// canvas), and XCUITest can't drive the custom UIScrollView canvas's paint gesture — that half is
/// covered by manual/on-device walkthrough. What this pins is exactly the requested move: name + shop
/// are gone from the drawing screen.
final class ItemCreationFlowUITests: XCTestCase {
    @MainActor
    func testNameAndShopAreOffTheEditorAndLeadToNext() {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_OPEN_CUSTOMIZE"] = "1"
        app.launch()

        // Open the Clothing slot picker (a custom slot → carries the Wardrobe route).
        let clothing = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Clothing")).firstMatch
        XCTAssertTrue(clothing.waitForExistence(timeout: 8), "customization sheet did not open")
        for _ in 0..<6 where !clothing.isHittable { app.swipeUp() }
        clothing.tap()

        let wardrobe = app.buttons["companion.wardrobe"]
        for _ in 0..<8 where !wardrobe.isHittable { app.swipeUp() }
        XCTAssertTrue(wardrobe.waitForExistence(timeout: 6), "Wardrobe route not found")
        wardrobe.tap()

        let design = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Design a new item")).firstMatch
        XCTAssertTrue(design.waitForExistence(timeout: 6), "Design a new item not found")
        design.tap()

        // Editor: the canvas is here, but the name + shop controls are NOT — they moved to the
        // confirmation step. Instead the editor leads onward with a "Next" bar.
        XCTAssertTrue(app.descendants(matching: .any)["studio.canvas"].waitForExistence(timeout: 6),
                      "editor canvas did not render")
        XCTAssertFalse(app.textFields["studio.confirm.name"].exists, "name field must NOT be on the editor screen")
        XCTAssertFalse(app.descendants(matching: .any)["studio.confirm.listToggle"].exists,
                       "shop listing must NOT be on the editor screen")
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 4),
                      "editor should lead to a Next step, not save directly")

        UXScreenProbe(app, "Studio · Editor (name/shop moved off)", in: self).capture()
    }
}
