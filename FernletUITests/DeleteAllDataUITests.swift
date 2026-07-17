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

        let alert = app.alerts["Delete everything?"]
        XCTAssertTrue(presentDialog(tapping: deleteButton, alert: alert), "no confirm dialog")

        // The confirm dialog must name what it deletes and disclose what it keeps — a delete that
        // overpromises is the defect being fixed, so the disclosure is asserted, not assumed.
        let body = alert.staticTexts.element(boundBy: 1).label
        XCTAssertTrue(body.contains("journal entries"), "dialog does not name the data it deletes: \(body)")
        XCTAssertTrue(body.contains("Kept on purpose"), "dialog does not disclose the survivors: \(body)")

        // Cancelling must mutate nothing — the destructive-confirmation contract.
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(alert.exists, "dialog stayed up after Cancel")

        XCTAssertTrue(presentDialog(tapping: deleteButton, alert: alert), "no confirm dialog on second tap")
        // "Delete" when Health is off; "Delete, keep Health" when the Health choice is offered.
        let confirm = alert.buttons["Delete"].exists ? alert.buttons["Delete"] : alert.buttons["Delete, keep Health"]
        XCTAssertTrue(confirm.exists, "no destructive confirm button: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
        confirm.tap()

        // A clean wipe dismisses Settings; a failed one raises the failure alert instead.
        XCTAssertFalse(app.alerts["Couldn't delete everything"].waitForExistence(timeout: 3),
                       "the wipe reported a failure")

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

    /// Taps until the dialog is up, retrying once.
    ///
    /// Not papering over a product bug: a tap issued while the Settings list is still decelerating from
    /// the scroll above lands on nothing, and XCUITest reports that as "the alert never appeared" — which
    /// looks exactly like a broken button. Retrying keeps the failure meaning "the button doesn't open
    /// the dialog", which is what this test is actually here to catch.
    private func presentDialog(tapping button: XCUIElement, alert: XCUIElement) -> Bool {
        for _ in 0..<2 {
            button.tap()
            if alert.waitForExistence(timeout: 5) { return true }
        }
        return false
    }
}
