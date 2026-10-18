import XCTest

// MARK: - Larger Text at AX5: the common tasks
//
// The App Store's Larger Text row asks for no truncation at the LARGEST accessibility text size
// across all common tasks: log a meal, log water, log a mood, complete a workout, plus onboarding
// and Settings. `ScreenAppearanceUITests` audits at `large`, where the audit's own Dynamic Type pass
// re-lays an already open screen out at the other sizes. This suite launches the app AT AX5
// (`-UIPreferredContentSizeCategoryName`), so every screen opens the way an AX5 user opens it: the
// accessibility-size layouts from the first frame, and each sheet at the detent it picks there.
// Each probe attaches the AX5 screenshot (the owner's device pass reads the same screens) and runs
// the same ratchet as every other probe, under its own "AX5 · " name.
//
// Three screens are SCREENSHOT-ONLY — attached for the device pass, not audited — because their
// findings would not be stable identities: the workout plan is today's plan (its title, exercises
// and eyebrow change with the weekday), the manual Log sheet's Recent chips run off the edge in an
// order set by the seed's dates, and the mood row is reached by a scroll whose stop moves. A frozen
// line that rotates with the calendar is the time bomb `UXScreenProbe.auditBaselines`' notes
// describe; the owner reads those three at AX5 instead.
//
// What it cannot see: a screen it does not open. The guided runner is reached only on a day whose
// suggested session is guidable; anything not listed is on the device-pass checklist, not claimed.

final class LargerTextAX5UITests: XCTestCase {
    /// The largest accessibility text size, as `UIPreferredContentSizeCategoryName` spells it.
    static let ax5 = "UICTContentSizeCategoryAccessibilityXXXL"

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: Home: the way into every task

    @MainActor
    func testHomeAtAX5() throws {
        let app = launchAtAX5()
        try UXScreenProbe(app, "AX5 · Home", in: self)
            .assertOnScreen("screen.home")
            .capture()
    }

    /// Log a mood: the one-tap row on Home.
    @MainActor
    func testHomeMoodRowAtAX5() throws {
        let app = launchAtAX5()
        let mood = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'quickMood.'")).firstMatch
        let title = app.staticTexts["How today felt"]
        scrollUntilHittable(mood, in: app)
        // Park the mood card's title just under the top edge: a swipe stops anywhere, and a stop
        // that cuts the quick-log tiles in half reports them as clipped text that is not.
        if title.exists {
            let top = app.windows.firstMatch.frame.minY + 100
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let distance = title.frame.minY - top
            start.press(forDuration: 0.05,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        UXScreenProbe(app, "AX5 · Home · Mood", in: self)
            .assertElementOnScreen(mood, "first quick-mood chip")
        attachScreenshot(of: app, "AX5 · Home · Mood")
    }

    // MARK: Logging sheets

    @MainActor
    func testMealSheetAtAX5() throws { try probeSheet("meal", "AX5 · Sheet · Meal") }
    @MainActor
    func testWaterSheetAtAX5() throws { try probeSheet("water", "AX5 · Sheet · Water") }
    /// Log a mood, written: the journal sheet's feeling chips and editor.
    @MainActor
    func testJournalSheetAtAX5() throws { try probeSheet("journal", "AX5 · Sheet · Journal") }
    /// Screenshot-only: see the note at the top of this file.
    @MainActor
    func testWorkoutSheetAtAX5() throws {
        let app = launchAtAX5(openSheet: "workout")
        UXScreenProbe(app, "AX5 · Sheet · Workout", in: self).assertOnScreen("sheet.workout")
        attachScreenshot(of: app, "AX5 · Sheet · Workout")
    }

    /// Complete a workout: suggest one, then the guided runner it starts.
    @MainActor
    func testGuidedWorkoutAtAX5() throws {
        let app = launchAtAX5(openSheet: "workoutSuggestion")
        try UXScreenProbe(app, "AX5 · Sheet · Workout suggestion", in: self)
            .assertOnScreen("sheet.workoutSuggestion")
            .capture()
        let suggest = app.buttons["workout.suggest"]
        XCTAssertTrue(suggest.waitForExistence(timeout: 8), "no Suggest button")
        suggest.tap()
        let approve = app.buttons["workout.approvePlan"]
        XCTAssertTrue(approve.waitForExistence(timeout: 30), "the suggestion never produced a plan")
        attachScreenshot(of: app, "AX5 · Sheet · Workout plan")
        // Only a guidable session offers Start now; a cardio-only day's plan does not, by design,
        // and the runner is then on the device-pass checklist rather than claimed here.
        let start = app.buttons["workout.startGuided"]
        guard start.waitForExistence(timeout: 2) else {
            throw XCTSkip("Today's suggested session is not guidable, so the runner was not reached.")
        }
        start.tap()
        let end = app.buttons["workout.guided.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 10), "the guided runner did not open")
        UXScreenProbe(app, "AX5 · Guided workout", in: self)
            .assertElementOnScreen(end, "End workout")
        attachScreenshot(of: app, "AX5 · Guided workout")
    }

    // MARK: Settings and onboarding

    @MainActor
    func testSettingsHubAtAX5() throws {
        let app = launchAtAX5(openSheet: "settings")
        try UXScreenProbe(app, "AX5 · Settings · Hub", in: self)
            .assertOnScreen("sheet.settings")
            .capture()
    }

    @MainActor
    func testOnboardingAtAX5() throws {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding", "-UIPreferredContentSizeCategoryName", Self.ax5]
        app.launchEnvironment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] = "1"
        app.launch()
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 20), "onboarding did not start")
        try UXScreenProbe(app, "AX5 · Onboarding · Welcome", in: self).capture()
        continueButton.tap()
        let biometrics = app.buttons["onboarding.lock.biometrics"]
        XCTAssertTrue(biometrics.waitForExistence(timeout: 6), "no lock step")
        try UXScreenProbe(app, "AX5 · Onboarding · Lock setup", in: self).capture()
        scrollUntilHittable(biometrics, in: app)
        biometrics.tap()
        let local = app.buttons["onboarding.storage.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 6), "no storage step")
        try UXScreenProbe(app, "AX5 · Onboarding · Storage choice", in: self).capture()
    }

    // MARK: Helpers

    /// ``UXTestApp/launch(openSheet:bypassPrivateLock:extraEnvironment:file:line:)``'s seeded app,
    /// at AX5.
    @MainActor
    private func launchAtAX5(openSheet sheetID: String? = nil) -> XCUIApplication {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding", "-UIPreferredContentSizeCategoryName", Self.ax5]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        if let sheetID { app.launchEnvironment["FERNLET_UI_TEST_OPEN_SHEET"] = sheetID }
        app.launch()
        UXTestApp.waitForLaunchHandover(app, openSheet: sheetID)
        return app
    }

    @MainActor
    private func probeSheet(_ id: String, _ name: String) throws {
        let app = launchAtAX5(openSheet: id)
        try UXScreenProbe(app, name, in: self)
            .assertOnScreen("sheet.\(id)")
            .capture()
    }

    /// Attaches a kept screenshot without auditing it, for the screens named at the top of this file.
    @MainActor
    private func attachScreenshot(of app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Swipes up until `element` can be tapped, at most eight times.
    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
    }
}
