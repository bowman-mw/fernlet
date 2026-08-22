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

        // The toggle entry presents the two-outcome sheet (batch 5): "Turn off iCloud sync?" with
        // Stop-syncing beside the typed-DELETE-gated delete. The delete-only entry point keeps the
        // old "Delete iCloud data?" title; this flow is the toggle one.
        openICloudDisableSheet(app)
        XCTAssertTrue(element("privacy.icloud.stopSync", app: app).exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '7 meal logs'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '3 journal entries'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '2 workouts'")).firstMatch.exists)
        XCTAssertFalse(element("privacy.icloud.confirmDelete", app: app).isEnabled)

        app.textFields["privacy.icloud.confirmText"].tapAndType("NO")
        XCTAssertFalse(element("privacy.icloud.confirmDelete", app: app).isEnabled)
    }

    @MainActor
    func testICloudDisableShowsSpinnerDuringReload() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, iCloudEnabled: true, slowReload: true)
        openVerifiedPrivacyData(app)

        openICloudDisableSheet(app)
        app.textFields["privacy.icloud.confirmText"].tapAndType("DELETE")
        element("privacy.icloud.confirmDelete", app: app).tap()

        XCTAssertTrue(element("privacy.storage.spinner", app: app).waitForExistence(timeout: 2))
    }

    /// SETT-27 + WS-5: disabling the Health master switch must PURGE the per-capability
    /// preferences, not merely mask them. Asserting "Not shared" with the master off proves
    /// nothing — `state(of:)` short-circuits to `.notShared` whenever the master is off — so the
    /// mask is lifted first: re-enable the master (which flips ONLY the master flag; the mock's
    /// `enableIntegration` seeds no capabilities) and THEN require every card — all six, the
    /// sensitive cycle/intimate kinds included — to still read "Not shared" from the stored
    /// preferences themselves. If `disableIntegration`'s capability reset regresses, the seeded
    /// `true` preferences survive the round-trip and the cards read "Shared" again.
    @MainActor
    func testHealthKitMasterToggleDisablesAllCapabilities() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, healthEnabled: true)
        openVerifiedPrivacyData(app)
        openHealthAccessPage(app)

        // Baseline: the harness seeds every capability on, so cards start "Shared" — without
        // this, the final "Not shared" could be vacuous (a seed that never took).
        let firstCard = element("health.card.state.bodyMeasurements", app: app)
        XCTAssertTrue(firstCard.waitForExistence(timeout: 3))
        XCTAssertEqual(firstCard.label, "Shared")

        let master = element("privacy.health.master", app: app)
        XCTAssertTrue(master.waitForExistence(timeout: 3))
        master.tap()

        // WS-5: disabling warns (it purges cached clinical data) before committing. Confirm it.
        XCTAssertTrue(app.staticTexts["Turn off Health integration?"].waitForExistence(timeout: 3))
        app.buttons["Turn off"].tap()
        XCTAssertTrue(waitForValue(master, "0", timeout: 3), "master did not turn off after confirming")

        // Lift the master-off mask, then prove the purge held.
        master.tap()
        XCTAssertTrue(waitForValue(master, "1", timeout: 3), "master did not come back on")

        let allCards = ["bodyMeasurements", "workoutsActivity", "bodySignals",
                        "mindfulness", "cycleTracking", "intimateLogging"]
        for card in allCards {
            let state = element("health.card.state.\(card)", app: app)
            XCTAssertTrue(state.waitForExistence(timeout: 3), "no state line for \(card)")
            XCTAssertEqual(state.label, "Not shared",
                           "\(card) reads shared with the master back on — disableIntegration failed to reset its preference")
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
        // Scroll first: without iCloud the Multiple-devices callout renders above, and the
        // switch's center then sits just past the fold — a tap on the unscrolled position lands
        // on nothing and the warning never appears (state-dependent, seen on a sim carrying
        // prior suites' app state).
        app.swipeUp()
        let toggle = labeledElement(containing: "Include local data in iOS backup", app: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertEqual(toggle.value as? String, "1")
        // Tap the switch CONTROL (a row-center tap lands on inert text), retrying a cold tap
        // the page's post-verification settle may swallow.
        let warning = app.staticTexts["Exclude Fernlet data from device backups?"]
        let control = toggle.switches.firstMatch
        for _ in 0..<3 where !warning.exists {
            (control.exists ? control : toggle).tap()
            if warning.waitForExistence(timeout: 2.5) { break }
        }
        XCTAssertTrue(warning.exists, "the exclude warning never presented after 3 toggle taps")
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
        // Excludes the page's "privacy.controls" marker container: it is a real accessibility
        // container (.contain) whose aggregated label CONTAINS every child's label, so without
        // the exclusion firstMatch returns the whole stack and a tap lands mid-page.
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS %@ AND identifier != 'privacy.controls'", text
            ))
            .firstMatch
    }

    /// Polls an element's accessibility value (a toggle reads "0"/"1") under a wall-clock
    /// deadline, instead of asserting a value the async commit may not have landed yet.
    @MainActor
    private func waitForValue(_ element: XCUIElement, _ expected: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expected),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
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

    /// Taps the Sync-to-iCloud toggle until the disable sheet presents. Under the seeded-auth
    /// harness the page's async verification can still be settling when a cold first tap lands,
    /// and a pre-verification toggle change is snapped back silently (fail-closed) — so one tap
    /// is not always enough. Bounded retries, then a hard assert.
    @MainActor
    private func openICloudDisableSheet(_ app: XCUIApplication) {
        let title = app.staticTexts["Turn off iCloud sync?"]
        // The row activates only on its switch CONTROL: the labeled element spans the whole row
        // and a tap at its center lands on inert text (verified against the live sheet), so tap
        // the inner bare Switch when one exists.
        let row = labeledElement(containing: "Sync to iCloud", app: app)
        let control = row.switches.firstMatch
        for _ in 0..<3 {
            (control.exists ? control : row).tap()
            if title.waitForExistence(timeout: 2.5) {
                // The sheet can present at its shorter detent with the typed-DELETE field at the
                // fold; swiping up raises the detent / scrolls the field fully on-screen so the
                // follow-on field tap lands (verified from the failure recording).
                app.swipeUp()
                return
            }
        }
        XCTFail("the iCloud disable sheet never presented after 3 toggle taps")
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
