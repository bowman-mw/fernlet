import XCTest

/// Tail #1 — the recipe detail view. Opens the recipe book and taps a seeded recipe, which now pushes a
/// read-only detail (photo, per-serving macros, ingredients, notes) instead of jumping into the editor.
/// Verifies the detail renders with its log + add-photo affordances, and screenshots it.
final class RecipeDetailUITests: XCTestCase {
    @MainActor
    func testRecipeRowOpensDetailView() throws {
        let app = UXTestApp.launch()  // Home, demo-seeded (seeds "Overnight oats" + another recipe)

        app.buttons["Food"].firstMatch.tap()

        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food")
        // Clear of the tab bar, not merely hittable: see `scrollClearOfTabBar`.
        XCTAssertTrue(scrollClearOfTabBar(recipeBook, in: app), "Recipe book button not reachable on Food")
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

        try UXScreenProbe(app, "Food · Recipe detail", in: self).capture()
    }

    /// The Food page's own Recipes section used to jump straight into the editor on tap; it now pushes
    /// the same read-only detail as the recipe book, so every recipe row behaves identically.
    @MainActor
    func testFoodPageRecipeRowOpensDetailView() {
        let app = UXTestApp.launch()  // Home, demo-seeded (seeds "Overnight oats" in the Recipes section)

        app.buttons["Food"].firstMatch.tap()

        // The recipe row in the Food page's Recipes section (NOT the "Recipe book" button).
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found in the Food page Recipes section")
        // Clear of the tab bar, not merely hittable: see `scrollClearOfTabBar`.
        XCTAssertTrue(scrollClearOfTabBar(row, in: app), "seeded recipe row not reachable on Food")
        row.tap()

        // Tapping now pushes the detail rather than presenting the editor sheet.
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 6), "recipe detail did not open from the Food page")
        XCTAssertTrue(app.buttons["recipeDetail.log"].waitForExistence(timeout: 4), "detail is missing the log action")
    }

    /// Drags the Food page until the element sits wholly between the status bar and the floating tab
    /// bar, and reports whether it got there. Each suite keeps its own copy; this one is shaped like
    /// HomeCardsRedesignUITests'.
    ///
    /// Hittable is not enough. The tab bar is the app's own view drawn over the page, and XCUITest
    /// steers its tap point off the tab BUTTONS' accessibility frames only — not off the pill drawn
    /// around them. Measured 2026-09-24 with the "Overnight oats" row under the compact bar: with its
    /// centre at y=789 or y=835, `isHittable` was true, the tap point was that centre — 1pt above or
    /// below Move's frame (790–834), inside the pill — and `tap()` selected the Move tab. The "Recipe
    /// book" link did not misfire in the same sweep: its centre, x≈341, is where the pill's rounded
    /// end has already curved away from those strips. The old swipe loop reached either target clear
    /// only because one fling happened to carry the page to its end. With the whole frame above the
    /// bar there is nothing to steer around, and the tap lands on the element's centre.
    private func scrollClearOfTabBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        // The page scrolls up under the status bar. The pill reaches 6pt past the tab buttons, and a
        // tap just outside a tab can still select it.
        let topClear: CGFloat = 100
        let tabBarClear: CGFloat = 16
        for _ in 0..<14 {
            guard element.exists else { dragFeed(by: 300, in: app); continue }
            let frame = element.frame
            // Re-read every pass: the bar compacts, and drops 30pt, once the page has scrolled.
            let bottom = tabBarTop(in: app) - tabBarClear
            let top = window.frame.minY + topClear
            if frame.maxY > bottom {
                dragFeed(by: frame.maxY - bottom + 40, in: app)
            } else if frame.minY < top {
                dragFeed(by: frame.minY - top - 40, in: app)
            } else if element.isHittable, element.frame == frame {
                // A second read that agrees: the page has stopped moving.
                return true
            }
        }
        return false
    }

    /// The top of the floating tab bar, read off its Home tab as `UXScreenProbe.assertAboveTabBar`
    /// does. `app.tabBars` is no use here: the bar is a custom SwiftUI view, and on a tab root the
    /// query finds nothing.
    private func tabBarTop(in app: XCUIApplication) -> CGFloat {
        let homeTab = app.buttons["Home"].firstMatch
        return homeTab.exists ? homeTab.frame.minY : app.windows.firstMatch.frame.maxY
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
