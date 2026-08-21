import XCTest
import FernletDomainModel

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

    /// SETT-27: the Health master switch and per-capability controls moved onto the one Health
    /// surface (Settings › Health), reached from this page's single "Health access" row. Disabling
    /// the master still warns (it purges cached clinical data) before committing, and every card
    /// then reads "Not shared".
    @MainActor
    func testHealthKitMasterToggleDisablesAllCapabilities() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, healthEnabled: true)
        openVerifiedPrivacyData(app)
        openHealthAccessPage(app)

        let master = labeledElement(containing: "Share with Health", app: app)
        XCTAssertTrue(master.waitForExistence(timeout: 3))
        master.tap()

        // WS-5: disabling now warns (it purges cached clinical data) before committing. Confirm it.
        let warning = app.staticTexts["Turn off Health integration?"]
        XCTAssertTrue(warning.waitForExistence(timeout: 3))
        app.buttons["Turn off"].tap()

        for card in ["bodyMeasurements", "workoutsActivity", "bodySignals", "mindfulness"] {
            let state = element("health.card.state.\(card)", app: app)
            XCTAssertTrue(state.waitForExistence(timeout: 3), "no state line for \(card)")
            XCTAssertEqual(state.label, "Not shared", "\(card) still reads shared after the master went off")
        }
    }

    /// WS-5: cancelling the HealthKit-disable warning must leave the integration ON (only mutates on
    /// confirm). The seeded capabilities stay shared.
    @MainActor
    func testHealthKitMasterDisableWarningCancelKeepsItOn() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, healthEnabled: true)
        openVerifiedPrivacyData(app)
        openHealthAccessPage(app)

        let master = labeledElement(containing: "Share with Health", app: app)
        XCTAssertTrue(master.waitForExistence(timeout: 3))
        master.tap()

        XCTAssertTrue(app.staticTexts["Turn off Health integration?"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()

        // Still on: a seeded card remains shared.
        let state = element("health.card.state.bodyMeasurements", app: app)
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.label, "Shared")
    }

    /// WS-5: excluding local data from device backups drops the sealed store with no cloud recovery, so
    /// it must warn before committing. Cancelling keeps the data included.
    @MainActor
    func testExcludeLocalBackupShowsWarningAndCancelKeepsIncluded() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true)
        openVerifiedPrivacyData(app)

        // Defaults to ON (data included). Tapping it tries to EXCLUDE → must warn first.
        let toggle = labeledElement(containing: "Include local data in iOS backup", app: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.tap()

        XCTAssertTrue(app.staticTexts["Exclude Fernlet data from device backups?"].waitForExistence(timeout: 3))
        app.buttons["Cancel"].tap()

        // Cancelled → still included (value "1"), nothing excluded.
        XCTAssertEqual(labeledElement(containing: "Include local data in iOS backup", app: app).value as? String, "1")
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

    /// Pushes the Health surface from this page's single "Health access" row (SETT-27).
    @MainActor
    private func openHealthAccessPage(_ app: XCUIApplication) {
        let row = element("privacy.health.access", app: app)
        XCTAssertTrue(row.waitForExistence(timeout: 3), "no Health access row on Privacy & Data")
        row.tap()
        XCTAssertTrue(app.navigationBars["Health"].waitForExistence(timeout: 4), "the Health page did not open")
    }
}
