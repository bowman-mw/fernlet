import XCTest

// MARK: - Onboarding appearance
//
// Walks the 8-screen onboarding flow once, capturing a labeled screenshot of each screen and
// asserting its title + primary action button render on-screen (not clipped). Complements
// OnboardingFlowUITests (which covers behavior/branching) with a visual + layout pass.

final class OnboardingAppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testOnboardingScreensAppearance() throws {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        // Keep the storage step deterministic (no live iCloud detection during the gallery run).
        app.launchEnvironment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] = "1"
        app.launch()

        // 1 · Welcome
        try probe("Onboarding · Welcome", title: "Welcome to Fernlet", action: app.buttons["Continue"], app: app)
        advance(app)

        // 2 · Lock setup
        try probe("Onboarding · Lock setup", title: "Protect private spaces",
              action: app.buttons["onboarding.lock.biometrics"], app: app)
        tap("onboarding.lock.biometrics", app: app)

        // 3 · Storage choice (Continue is disabled until a card is selected)
        try probe("Onboarding · Storage choice", title: "Choose where logs live",
              action: app.buttons["onboarding.storage.local"], app: app)
        tap("onboarding.storage.local", app: app)
        advance(app)

        // 4 · Goal & plan
        try probe("Onboarding · Goal", title: "Plan your goals", action: app.buttons["Continue"], app: app)
        advance(app)

        // 5 · Starter customization
        try probe("Onboarding · Starter", title: "Make Fernlet yours", action: app.buttons["Continue"], app: app)
        advance(app)

        // 6 · Personal details
        try probe("Onboarding · Personal details", title: "Add personal details", action: app.buttons["Continue"], app: app)
        advance(app)

        // 7 · Dietary pattern
        try probe("Onboarding · Dietary pattern", title: "Pick an eating pattern", action: app.buttons["Continue"], app: app)
        advance(app)

        // 8 · Permissions
        try probe("Onboarding · Permissions", title: "Permissions when needed",
              action: app.buttons["Start Fernlet"], app: app)
    }

    // MARK: - Helpers

    @MainActor
    private func probe(_ name: String, title: String, action: XCUIElement, app: XCUIApplication) throws {
        let p = UXScreenProbe(app, name, in: self)
        try p.assertElementOnScreen(app.staticTexts[title], "title \"\(title)\"")
            .assertElementOnScreen(action, "primary action button")
            .assertBelowStatusBarElement(app.staticTexts[title])
            .capture()
    }

    @MainActor
    private func tap(_ identifier: String, app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 3), "missing onboarding control \(identifier)")
        button.tap()
    }

    /// Taps the "Continue" save bar, first waiting for it to become enabled — the Storage
    /// step disables Continue until a card is selected, and the enabled state can lag the
    /// selection tap by a render.
    @MainActor
    private func advance(_ app: XCUIApplication) {
        let cont = app.buttons["Continue"]
        XCTAssertTrue(cont.waitForExistence(timeout: 5), "Continue button missing")
        let deadline = Date().addingTimeInterval(5)
        while !cont.isEnabled && Date() < deadline { usleep(100_000) }
        XCTAssertTrue(cont.isEnabled, "Continue never became enabled")
        cont.tap()
    }
}
