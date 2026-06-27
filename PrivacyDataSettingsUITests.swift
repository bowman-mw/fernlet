import XCTest

final class PrivacyDataSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLockGateBlocksAccessWhenLocked() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: false)
        openPrivacyData(app)

        XCTAssertTrue(element("privacy.lock.gate", app: app).waitForExistence(timeout: 3))
        XCTAssertFalse(element("privacy.icloud.toggle", app: app).exists)
    }

    @MainActor
    func testLockSetupInterstitialShowsWhenLockNotConfigured() throws {
        let app = launchPrivacyApp(lockConfigured: false, freshAuth: false)
        openPrivacyData(app)

        XCTAssertTrue(app.staticTexts["Set up app lock to access privacy settings"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Set up app lock"].exists)
        XCTAssertFalse(element("privacy.icloud.toggle", app: app).exists)
    }

    @MainActor
    func testICloudDisableShowsConfirmationWithCountsAndRequiresTypedConfirmation() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, iCloudEnabled: true)
        openVerifiedPrivacyData(app)

        labeledElement(containing: "Sync to iCloud", app: app).tap()
        XCTAssertTrue(app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '7 meal logs'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '3 journal entries'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '2 workouts'")).firstMatch.exists)
        XCTAssertFalse(element("privacy.icloud.confirmDelete", app: app).isEnabled)

        app.textFields["privacy.icloud.confirmText"].tap()
        app.textFields["privacy.icloud.confirmText"].typeText("NO")
        XCTAssertFalse(element("privacy.icloud.confirmDelete", app: app).isEnabled)
    }

    @MainActor
    func testICloudDisableShowsSpinnerDuringReload() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, iCloudEnabled: true, slowReload: true)
        openVerifiedPrivacyData(app)

        labeledElement(containing: "Sync to iCloud", app: app).tap()
        XCTAssertTrue(app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 3))
        app.textFields["privacy.icloud.confirmText"].tap()
        app.textFields["privacy.icloud.confirmText"].typeText("DELETE")
        element("privacy.icloud.confirmDelete", app: app).tap()

        XCTAssertTrue(element("privacy.storage.spinner", app: app).waitForExistence(timeout: 2))
    }

    @MainActor
    func testHealthKitMasterToggleDisablesAllCapabilities() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, healthEnabled: true)
        openVerifiedPrivacyData(app)

        let master = labeledElement(containing: "Health integration", app: app)
        XCTAssertTrue(master.waitForExistence(timeout: 3))
        master.tap()

        for title in [
            "Body profile",
            "Cycle tracking",
            "Body context",
            "Activity context",
            "Mindfulness",
            "Intimate logging"
        ] {
            XCTAssertEqual(labeledElement(containing: title, app: app).value as? String, "0")
        }
    }

    @MainActor
    private func launchPrivacyApp(
        lockConfigured: Bool,
        freshAuth: Bool,
        iCloudEnabled: Bool = false,
        healthEnabled: Bool = false,
        slowReload: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_PRIVACY_SERVICES"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_LOCK_CONFIGURED"] = lockConfigured ? "1" : "0"
        app.launchEnvironment["FERNLET_UI_TEST_PRIVACY_AUTH"] = freshAuth ? "1" : "0"
        app.launchEnvironment["FERNLET_UI_TEST_ICLOUD_ENABLED"] = iCloudEnabled ? "1" : "0"
        app.launchEnvironment["FERNLET_UI_TEST_HEALTH_ENABLED"] = healthEnabled ? "1" : "0"
        app.launchEnvironment["FERNLET_UI_TEST_SLOW_RELOAD"] = slowReload ? "1" : "0"
        app.launchEnvironment["FERNLET_UI_TEST_OPEN_PRIVACY_DATA"] = "1"
        app.launch()
        return app
    }

    @MainActor
    private func openPrivacyData(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Privacy & Data"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func element(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func labeledElement(containing text: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }

    @MainActor
    private func openVerifiedPrivacyData(_ app: XCUIApplication) {
        openPrivacyData(app)
        let verifyButton = element("privacy.verify", app: app)
        if verifyButton.waitForExistence(timeout: 2) {
            verifyButton.tap()
        }
        XCTAssertTrue(labeledElement(containing: "Sync to iCloud", app: app).waitForExistence(timeout: 3))
    }
}
