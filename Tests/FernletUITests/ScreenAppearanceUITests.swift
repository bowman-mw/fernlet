import XCTest

// MARK: - Screen appearance: tabs, private hub, and logging sheets
//
// Goal: confirm every primary screen renders correctly (no clipped headers, content within
// the screen, populated not blank) and attach a labeled screenshot of each for visual "vibe"
// review. Backed by UXScreenProbe / UXTestApp. Each test launches the app pre-seeded with demo
// content (FERNLET_UI_TEST_SEED_DEMO) so screens show realistic cards.
//
// Out of scope (require a live nearby peer / active mesh session, not reachable single-device):
// the disposable camera, friend photo feed/review, connection-success overlay, mesh admission
// prompt, and the proximity recipe-share send/review sheets. Those need a second device or a
// mesh-session injection the app doesn't currently expose to UI tests.

final class ScreenAppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true   // gallery run: capture every screen even if one is off
    }

    // MARK: - Tabs

    @MainActor
    func testHomeTabAppearance() {
        let app = UXTestApp.launch()
        UXScreenProbe(app, "Home tab", in: self)
            .assertOnScreen("screen.home")
            .assertBelowStatusBar("screen.home")
            .assertAboveTabBar("screen.home")
            .capture()
    }

    @MainActor
    func testFoodTabAppearance() {
        let app = UXTestApp.launch()
        app.buttons["Food"].firstMatch.tap()
        UXScreenProbe(app, "Food tab", in: self)
            .assertOnScreen("screen.food")
            .assertBelowStatusBar("screen.food")
            .assertNotEmpty(containing: "Greek yogurt")
            .capture()
    }

    @MainActor
    func testMoveTabAppearance() {
        let app = UXTestApp.launch()
        app.buttons["Move"].firstMatch.tap()
        UXScreenProbe(app, "Move tab", in: self)
            .assertOnScreen("screen.move")
            .assertBelowStatusBar("screen.move")
            .assertNotEmpty(containing: "Upper body")
            .capture()
    }

    @MainActor
    func testFriendsTabAppearance() {
        let app = UXTestApp.launch()
        app.buttons["Friends"].firstMatch.tap()
        UXScreenProbe(app, "Friends tab", in: self)
            .assertOnScreen("screen.friends")
            .assertBelowStatusBar("screen.friends")
            .capture()
    }

    // MARK: - Private hub (lock gate bypassed for appearance review)

    @MainActor
    func testPrivateHubJournalAppearance() {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        app.buttons["Private"].firstMatch.tap()
        UXScreenProbe(app, "Private · Journal", in: self)
            .assertOnScreen("screen.journal")
            .assertBelowStatusBar("screen.journal")
            .capture()
    }

    // The merged Cycle page replaces the separate Period and Intimacy pages: one layered
    // calendar whose halves gate independently. All three visibility combinations that render
    // the page are covered (both halves, period-only, intimacy-only); the both-hidden case has
    // no page to review. The hide flags are consumed by the demo seed on every launch.

    @MainActor
    func testPrivateHubCycleAppearance() {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        app.buttons["Private"].firstMatch.tap()
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6))
        cycle.tap()
        UXScreenProbe(app, "Private · Cycle (both halves)", in: self)
            .assertOnScreen("screen.cycle")
            .capture()
    }

    @MainActor
    func testPrivateHubCyclePeriodOnlyAppearance() {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: ["FERNLET_UI_TEST_HIDE_INTIMACY": "1"]
        )
        app.buttons["Private"].firstMatch.tap()
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6))
        cycle.tap()
        UXScreenProbe(app, "Private · Cycle (period only)", in: self)
            .assertOnScreen("screen.cycle")
            .capture()
    }

    @MainActor
    func testPrivateHubCycleIntimacyOnlyAppearance() {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: ["FERNLET_UI_TEST_HIDE_PERIOD": "1"]
        )
        app.buttons["Private"].firstMatch.tap()
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6))
        cycle.tap()
        UXScreenProbe(app, "Private · Cycle (intimacy only)", in: self)
            .assertOnScreen("screen.cycle")
            .capture()
    }

    // MARK: - Logging / editor sheets (opened directly via the launch hook)

    @MainActor
    func testMealSheetAppearance()              { probeSheet("meal", "Sheet · Meal") }
    @MainActor
    func testWaterSheetAppearance()             { probeSheet("water", "Sheet · Water") }
    @MainActor
    func testSleepSheetAppearance()             { probeSheet("sleep", "Sheet · Sleep") }
    @MainActor
    func testJournalSheetAppearance()           { probeSheet("journal", "Sheet · Journal") }
    @MainActor
    func testWorkoutSheetAppearance()           { probeSheet("workout", "Sheet · Workout") }
    @MainActor
    func testWorkoutSuggestionSheetAppearance() { probeSheet("workoutSuggestion", "Sheet · Workout suggestion") }
    @MainActor
    func testGoalsSheetAppearance()             { probeSheet("goals", "Sheet · Goals") }
    @MainActor
    func testHygieneSheetAppearance()           { probeSheet("hygiene", "Sheet · Hygiene") }
    @MainActor
    func testTrendsSheetAppearance()            { probeSheet("trends", "Sheet · Trends") }
    @MainActor
    func testMilestonesSheetAppearance()        { probeSheet("milestones", "Sheet · Milestones") }
    @MainActor
    func testFirstAidSheetAppearance()          { probeSheet("firstAid", "Sheet · First aid") }
    @MainActor
    func testRecipeSheetAppearance()            { probeSheet("recipe", "Sheet · Recipe") }
    @MainActor
    func testRecipeBookSheetAppearance()        { probeSheet("recipeBook", "Sheet · Recipe book") }
    @MainActor
    func testLogPeriodSheetAppearance()         { probeSheet("logPeriod", "Sheet · Log period") }
    @MainActor
    func testLogIntimacySheetAppearance()       { probeSheet("logIntimacy", "Sheet · Log intimacy") }
    @MainActor
    func testEditRecipeSheetAppearance()        { probeSheet("editRecipe", "Sheet · Edit recipe") }
    @MainActor
    func testEditSavedRecipeSheetAppearance()   { probeSheet("editSavedRecipe", "Sheet · Saved recipe notes") }

    // MARK: - Helpers

    @MainActor
    private func probeSheet(_ id: String, _ name: String) {
        let app = UXTestApp.launch(openSheet: id)
        UXScreenProbe(app, name, in: self)
            .assertOnScreen("sheet.\(id)")
            .capture()
    }
}
