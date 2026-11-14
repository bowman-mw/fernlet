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

    // MARK: - Home (the World map) and its panels
    //
    // The World look has no tab bar: Home is the live map, with the status plate at the top and the
    // item bar at the bottom, and every other "tab" is a full-screen panel the item bar opens (its
    // slots carry the old tab names, so the panel probes below keep their `… tab` names and
    // baselines). Home's cards moved into the Today panel, which the status plate opens; that is
    // audited as its own screen, `Today`.

    @MainActor
    func testHomeTabAppearance() throws {
        let app = UXTestApp.launch()
        // Renamed from "Home tab" (no baseline entry): the screen it audited, the card feed, is now
        // the Today panel, and Home is the map.
        try UXScreenProbe(app, "Home · Map", in: self)
            .assertOnScreen("world.statusPlate")
            .assertBelowStatusBar("world.statusPlate")
            .assertOnScreen("world.itemBar")
            .capture()
    }

    @MainActor
    func testTodayPanelAppearance() throws {
        let app = UXTestApp.launch()
        let plate = app.buttons["world.statusPlate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 10), "the map's status plate is missing")
        plate.tap()
        try UXScreenProbe(app, "Today", in: self)
            .assertOnScreen("world.panel.close")
            .assertBelowStatusBar("world.panel.close")
            .assertNotEmpty(containing: "Arrange Today")
            .capture()
    }

    @MainActor
    func testFoodTabAppearance() throws {
        let app = UXTestApp.launch()
        app.buttons["Food"].firstMatch.tap()
        try UXScreenProbe(app, "Food tab", in: self)
            .assertOnScreen("screen.food")
            .assertBelowStatusBar("screen.food")
            .assertNotEmpty(containing: "Greek yogurt")
            .capture()
    }

    @MainActor
    func testMoveTabAppearance() throws {
        let app = UXTestApp.launch()
        app.buttons["Move"].firstMatch.tap()
        try UXScreenProbe(app, "Move tab", in: self)
            .assertOnScreen("screen.move")
            .assertBelowStatusBar("screen.move")
            .assertNotEmpty(containing: "Upper body")
            .capture()
    }

    @MainActor
    func testFriendsTabAppearance() throws {
        let app = UXTestApp.launch()
        app.buttons["Album"].firstMatch.tap()
        try UXScreenProbe(app, "Friends tab", in: self)
            .assertOnScreen("screen.friends")
            .assertBelowStatusBar("screen.friends")
            .capture()
    }

    // MARK: - Private hub (lock gate bypassed for appearance review)

    @MainActor
    func testPrivateHubJournalAppearance() throws {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        app.buttons["Private"].firstMatch.tap()
        try UXScreenProbe(app, "Private · Journal", in: self)
            .assertOnScreen("screen.journal")
            .assertBelowStatusBar("screen.journal")
            .assertBelowElement("screen.journal", app.buttons["Journal"].firstMatch, describe: "the hub's section picker")
            .capture()
    }

    // The merged Cycle page replaces the separate Period and Intimacy pages: one layered
    // calendar whose halves gate independently. All three visibility combinations that render
    // the page are covered (both halves, period-only, intimacy-only); the both-hidden case has
    // no page to review. The hide flags are consumed by the demo seed on every launch.

    @MainActor
    func testPrivateHubCycleAppearance() throws {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        app.buttons["Private"].firstMatch.tap()
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6))
        cycle.tap()
        try UXScreenProbe(app, "Private · Cycle (both halves)", in: self)
            .assertOnScreen("screen.cycle")
            .assertBelowElement("screen.cycle", cycle, describe: "the hub's section picker")
            .capture()
    }

    @MainActor
    func testPrivateHubCyclePeriodOnlyAppearance() throws {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: ["FERNLET_UI_TEST_HIDE_INTIMACY": "1"]
        )
        app.buttons["Private"].firstMatch.tap()
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6))
        cycle.tap()
        try UXScreenProbe(app, "Private · Cycle (period only)", in: self)
            .assertOnScreen("screen.cycle")
            .capture()
    }

    @MainActor
    func testPrivateHubCycleIntimacyOnlyAppearance() throws {
        let app = UXTestApp.launch(
            bypassPrivateLock: true,
            extraEnvironment: ["FERNLET_UI_TEST_HIDE_PERIOD": "1"]
        )
        app.buttons["Private"].firstMatch.tap()
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6))
        cycle.tap()
        try UXScreenProbe(app, "Private · Cycle (intimacy only)", in: self)
            .assertOnScreen("screen.cycle")
            .capture()
    }

    // MARK: - Logging / editor sheets (opened directly via the launch hook)

    @MainActor
    func testMealSheetAppearance() throws              { try probeSheet("meal", "Sheet · Meal") }
    @MainActor
    func testWaterSheetAppearance() throws             { try probeSheet("water", "Sheet · Water") }
    @MainActor
    func testSleepSheetAppearance() throws             { try probeSheet("sleep", "Sheet · Sleep") }
    @MainActor
    func testJournalSheetAppearance() throws           { try probeSheet("journal", "Sheet · Journal") }
    @MainActor
    func testWorkoutSheetAppearance() throws           { try probeSheet("workout", "Sheet · Workout") }
    @MainActor
    func testWorkoutSuggestionSheetAppearance() throws { try probeSheet("workoutSuggestion", "Sheet · Workout suggestion") }
    @MainActor
    func testGoalsSheetAppearance() throws             { try probeSheet("goals", "Sheet · Goals") }
    @MainActor
    func testHygieneSheetAppearance() throws           { try probeSheet("hygiene", "Sheet · Hygiene") }
    @MainActor
    func testTrendsSheetAppearance() throws            { try probeSheet("trends", "Sheet · Trends") }
    /// Anchored on the Stamp book page inside the sheet: `MilestonesView` carries its own framed
    /// sheet, so `sheet.milestones` sits OUTSIDE the frame and reports its 3pt border bleeding past
    /// both screen edges, which is the frame's drawing, not clipped content.
    @MainActor
    func testMilestonesSheetAppearance() throws {
        let app = UXTestApp.launch(openSheet: "milestones")
        XCTAssertTrue(app.descendants(matching: .any)["sheet.milestones"].firstMatch.waitForExistence(timeout: 8),
                      "the Milestones sheet did not open")
        try UXScreenProbe(app, "Sheet · Milestones", in: self)
            .assertOnScreen("screen.milestones")
            .capture()
    }
    @MainActor
    func testFirstAidSheetAppearance() throws          { try probeSheet("firstAid", "Sheet · First aid") }
    @MainActor
    func testRecipeSheetAppearance() throws            { try probeSheet("recipe", "Sheet · Recipe") }
    @MainActor
    func testRecipeBookSheetAppearance() throws        { try probeSheet("recipeBook", "Sheet · Recipe book") }
    @MainActor
    func testLogPeriodSheetAppearance() throws         { try probeSheet("logPeriod", "Sheet · Log period") }
    @MainActor
    func testLogIntimacySheetAppearance() throws       { try probeSheet("logIntimacy", "Sheet · Log intimacy") }
    @MainActor
    func testEditRecipeSheetAppearance() throws        { try probeSheet("editRecipe", "Sheet · Edit recipe") }
    @MainActor
    func testEditSavedRecipeSheetAppearance() throws   { try probeSheet("editSavedRecipe", "Sheet · Saved recipe notes") }

    // MARK: - Helpers

    @MainActor
    private func probeSheet(_ id: String, _ name: String) throws {
        let app = UXTestApp.launch(openSheet: id)
        try UXScreenProbe(app, name, in: self)
            .assertOnScreen("sheet.\(id)")
            .capture()
    }
}
