import XCTest

/// End-to-end proof that "Delete everything" empties the app AND that the data stays gone across a
/// relaunch.
///
/// The relaunch half is the whole point. The bug this feature exists to fix was invisible in the app and
/// in the diff: "Reset everything" cleared the in-memory diary so the screens looked empty, while every
/// logged day sat on disk waiting for `loadAllDays()` on the next launch. Any test that only asserts the
/// UI went blank would have passed against the bug.
///
/// The second launch deliberately does NOT set `FERNLET_UI_TEST_SEED_DEMO`. The demo seeder bails only
/// when TODAY's meals already exist — so after a successful delete it would happily re-seed, and a
/// re-seeded meal is indistinguishable from a resurrected one. Seeding on the relaunch would turn this
/// test into one that passes whether or not the delete works.
@MainActor
final class DeleteAllDataUITests: XCTestCase {

    /// A meal the demo seeder writes. Its presence is the proxy for "the user's logged data exists".
    private let seededMeal = "Chicken rice bowl"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDeletingEverythingEmptiesTheAppAndSurvivesARelaunch() throws {
        // Launch 1: seeded, so there is real logged data to destroy.
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "settings sheet did not open")

        let deleteButton = app.descendants(matching: .any)["settings.deleteAll"]
        scrollUntilHittable(deleteButton, in: app)
        XCTAssertTrue(deleteButton.isHittable, "the delete-everything button is not reachable in Settings")

        // 2026-08-21 (artboard 5e): the confirm is a typed-gate SHEET, not a system alert.
        let sheetTitle = app.staticTexts["Delete everything?"]
        XCTAssertTrue(presentSheet(tapping: deleteButton, title: sheetTitle), "no confirm sheet")

        // The sheet must name what it deletes and disclose what it keeps — a delete that
        // overpromises is the defect being fixed, so the disclosure is asserted, not assumed.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Journal entries'")).firstMatch.exists,
            "the sheet does not name the data it deletes")
        XCTAssertTrue(app.descendants(matching: .any)["deleteAll.keptList"].exists,
                      "the sheet does not disclose the survivors")

        // Cancelling must mutate nothing — the mutation-only-on-confirm contract. Cancel is a
        // real, always-rendered button (XCUT-02), in the sheet header.
        app.descendants(matching: .any)["sheet.cancel"].tap()
        XCTAssertFalse(sheetTitle.waitForExistence(timeout: 2), "sheet stayed up after Cancel")

        XCTAssertTrue(presentSheet(tapping: deleteButton, title: sheetTitle), "no confirm sheet on second tap")

        // The terracotta confirm stays disabled — opacity, never a red error — until the word is
        // typed. ("Delete everything" when Health is not offered; "Delete, keep Health" when it is —
        // both carry the same identifier.)
        let confirm = app.descendants(matching: .any)["deleteAll.confirm"]
        scrollUntilHittable(confirm, in: app)
        XCTAssertTrue(confirm.exists, "no confirm button on the sheet")
        XCTAssertFalse(confirm.isEnabled, "the confirm button must be disabled before the word is typed")

        let field = app.textFields["deleteAll.confirmText"]
        scrollUntilHittable(field, in: app)
        XCTAssertTrue(field.isHittable, "the typed gate is not reachable")
        field.tap()
        field.typeText("DELETE\n")

        XCTAssertTrue(confirm.waitForExistence(timeout: 2))
        XCTAssertTrue(confirm.isEnabled, "typing the word did not arm the confirm button")
        confirm.tap()

        // A clean wipe raises the success alert; a failed one raises the failure alert instead.
        XCTAssertFalse(app.alerts["Couldn't delete everything"].waitForExistence(timeout: 3),
                       "the wipe reported a failure")
        let successDone = app.alerts["Everything deleted"].buttons["Done"]
        if successDone.waitForExistence(timeout: 8) { successDone.tap() }

        assertMealAbsent(in: app, context: "immediately after deleting")
        app.terminate()

        // Launch 2: NO seed. Anything that reappears came off disk, which is the original bug.
        let relaunched = XCUIApplication()
        relaunched.launchArguments = ["-completeOnboarding"]
        relaunched.launch()
        assertMealAbsent(in: relaunched, context: "after a relaunch")
    }

    // MARK: - Helpers

    private func assertMealAbsent(in app: XCUIApplication, context: String) {
        let food = app.buttons["Food"].firstMatch
        if food.waitForExistence(timeout: 10), food.isHittable { food.tap() }
        let meal = app.staticTexts[seededMeal]
        XCTAssertFalse(meal.waitForExistence(timeout: 3), "'\(seededMeal)' still present \(context)")
    }

    /// Sanity check on the proxy itself: the seeded meal must actually be visible before a wipe, or the
    /// absence assertions above would pass against a test that never had data to delete.
    func testSeededMealIsVisibleBeforeAnyDelete() {
        let app = UXTestApp.launch()
        let food = app.buttons["Food"].firstMatch
        XCTAssertTrue(food.waitForExistence(timeout: 10), "no Food tab")
        food.tap()
        XCTAssertTrue(app.staticTexts[seededMeal].waitForExistence(timeout: 5),
                      "the demo seed did not produce '\(seededMeal)' — the delete test's proxy is invalid")
    }

    /// Bounded scroll — the reset section sits at the bottom of a long Settings list.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    /// Taps until the confirm sheet is up, retrying once.
    ///
    /// Not papering over a product bug: a tap issued while the Settings list is still decelerating from
    /// the scroll above lands on nothing, and XCUITest reports that as "the sheet never appeared" — which
    /// looks exactly like a broken button. Retrying keeps the failure meaning "the button doesn't open
    /// the sheet", which is what this test is actually here to catch.
    private func presentSheet(tapping button: XCUIElement, title: XCUIElement) -> Bool {
        for _ in 0..<2 {
            button.tap()
            if title.waitForExistence(timeout: 5) { return true }
        }
        return false
    }
}
