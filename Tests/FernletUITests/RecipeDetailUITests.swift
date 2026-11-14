import XCTest

/// Tail #1 — the recipe detail view. Opens the recipe book and taps a seeded recipe, which now pushes a
/// read-only detail (photo, per-serving macros, ingredients, notes) instead of jumping into the editor.
/// Verifies the detail renders with its log + add-photo affordances, and screenshots it.
final class RecipeDetailUITests: XCTestCase {
    @MainActor
    func testRecipeRowOpensDetailView() throws {
        let app = UXTestApp.launch()  // Home, demo-seeded (seeds "Overnight oats" + another recipe)

        openFoodPanel(in: app)

        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food")
        XCTAssertTrue(scrollIntoClearView(recipeBook, in: app), "Recipe book button not reachable on Food")
        recipeBook.tap()

        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found in the book")
        row.tap()

        // The detail view: its plate title, the log action, the ingredients, and the add-photo affordance.
        XCTAssertTrue(waitForPushedPage("Recipe", in: app), "recipe detail did not open")
        XCTAssertTrue(app.buttons["recipeDetail.log"].waitForExistence(timeout: 4), "detail is missing the log action")
        XCTAssertTrue(app.buttons["recipeDetail.addPhoto"].waitForExistence(timeout: 4), "detail is missing the add-photo affordance")
        // Ingredient names resolved (seeded oats recipe lists Rolled oats / Greek yogurt / Blueberries).
        let ingredient = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "oats")).firstMatch
        XCTAssertTrue(ingredient.waitForExistence(timeout: 4), "ingredient lines did not render")

        try UXScreenProbe(app, "Food · Recipe detail", in: self).capture()
    }

    /// The Food page's own Recipes section used to jump straight into the editor on tap; it now pushes
    /// the same read-only detail as the recipe book, so every recipe row behaves identically.
    @MainActor
    func testFoodPageRecipeRowOpensDetailView() {
        let app = UXTestApp.launch()  // Home, demo-seeded (seeds "Overnight oats" in the Recipes section)

        openFoodPanel(in: app)

        // The recipe row in the Food page's Recipes section (NOT the "Recipe book" button).
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found in the Food page Recipes section")
        XCTAssertTrue(scrollIntoClearView(row, in: app), "seeded recipe row not reachable on Food")
        row.tap()

        // Tapping now pushes the detail rather than presenting the editor sheet.
        XCTAssertTrue(waitForPushedPage("Recipe", in: app), "recipe detail did not open from the Food page")
        XCTAssertTrue(app.buttons["recipeDetail.log"].waitForExistence(timeout: 4), "detail is missing the log action")
    }

    /// Opens the Food panel from the map's item bar (`world.item.food`) and waits for its page. One
    /// retry: a tap in the first seconds after launch is occasionally lost.
    @MainActor
    private func openFoodPanel(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let page = app.descendants(matching: .any)["screen.food"].firstMatch
        let slot = app.buttons["world.item.food"].firstMatch
        for _ in 0..<2 where !page.exists {
            XCTAssertTrue(slot.waitForExistence(timeout: 30), "the item bar has no Food slot", file: file, line: line)
            slot.tap()
            _ = page.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(page.exists, "the Food panel never showed screen.food", file: file, line: line)
    }

    /// Waits for a page titled `title` pushed inside the Food panel: the World frame draws its title
    /// on the plate beside `plate.back` (whose own label names the page it returns to).
    @MainActor
    private func waitForPushedPage(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 6) -> Bool {
        let back = app.buttons["plate.back"].firstMatch
        let plateTitle = app.staticTexts[title].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if back.exists, plateTitle.exists, back.label != "Back to \(title)" { return true }
            _ = back.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        return false
    }

    /// Drags the Food panel's page until the element sits wholly between the panel's plate and the
    /// bottom of the screen, and has stopped moving (a second read agrees), so the tap lands on its
    /// centre. Each suite keeps its own copy.
    private func scrollIntoClearView(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let topClear: CGFloat = 130
        let bottomClear: CGFloat = 40
        for _ in 0..<14 {
            guard element.exists else { dragFeed(by: 300, in: app); continue }
            let frame = element.frame
            let bottom = window.frame.maxY - bottomClear
            let top = window.frame.minY + topClear
            if frame.maxY > bottom {
                dragFeed(by: frame.maxY - bottom + 40, in: app)
            } else if frame.minY < top {
                dragFeed(by: frame.minY - top - 40, in: app)
            } else if element.isHittable, element.frame == frame {
                return true
            }
        }
        return false
    }

    /// Moves the page's content up by about `distance` points (down when negative) with a
    /// press-drag-hold, which ends where it is told to — unlike `swipeUp()`, whose fling keeps the
    /// page moving after the frame is read. Never under 60pt of travel: a press that moves less than
    /// the scroll view's ~10pt slop is a tap on whatever sits under it, and that slop is added back.
    private func dragFeed(by distance: CGFloat, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let height = window.frame.height
        let travel = min(max(abs(distance) + 10, 60), height * 0.45) / height
        let startY: CGFloat = distance > 0 ? 0.70 : 0.30
        let endY = distance > 0 ? startY - travel : startY + travel
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
    }
}
