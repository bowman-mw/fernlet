import XCTest
import FernletDomainModel

// MARK: - Storage & Privacy UI Test Suite

/// Covers Scenarios 3, 4, and 7 from the Storage Privacy integration spec:
///   3 – Existing CloudKit data: "Restore from iCloud" prompt visible during onboarding
///   4 – iCloud disable flow: typed DELETE confirmation, spinner, records removed
///   7 – Lock gate: locked state blocks access; not-configured state shows interstitial
///
/// Environment variables (set in launchEnvironment before launch):
///   FERNLET_UI_TEST_PRIVACY_SERVICES  – inject mock services instead of live ones
///   FERNLET_UI_TEST_LOCK_CONFIGURED   – "1" if lock is already set up
///   FERNLET_UI_TEST_PRIVACY_AUTH      – "1" to pre-authenticate (skip biometric prompt)
///   FERNLET_UI_TEST_ICLOUD_ENABLED    – "1" if iCloud sync is on
///   FERNLET_UI_TEST_SLOW_RELOAD       – "1" to simulate a slow persistence reload
///   FERNLET_UI_TEST_OPEN_PRIVACY_DATA – "1" to open Privacy & Data directly on launch
///   FERNLET_UI_TEST_EXISTING_CLOUD_DATA – "1" to inject a non-empty existing data summary
///
/// Launch arguments:
///   -resetOnboarding     – start onboarding from scratch
///   -completeOnboarding  – skip onboarding and land on the main screen
final class StoragePrivacyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Scenario 3: Existing CloudKit data during onboarding

    /// When existing iCloud data is detected during onboarding storage choice,
    /// a "Restore from iCloud" element is visible alongside the data counts.
    @MainActor
    func testOnboarding_existingCloudData_showsRestorePrompt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_EXISTING_CLOUD_DATA"] = "1"
        app.launch()

        // Navigate through welcome → lock setup → arrive at storage choice
        skipToStorageChoiceStep(app)

        // Storage choice screen: iCloud card with detected data should show restore prompt
        let detectingBadge = app.descendants(matching: .any)["onboarding.storage.detecting"]
        if detectingBadge.waitForExistence(timeout: 4) {
            // wait for detection to resolve
            _ = app.descendants(matching: .any)["onboarding.storage.icloud"]
                .waitForExistence(timeout: 8)
        }

        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'Restore from iCloud'"))
                .firstMatch
                .waitForExistence(timeout: 6),
            "Expected a 'Restore from iCloud' label when existing cloud data is present"
        )
    }

    /// When no existing iCloud data is detected, the restore prompt is absent.
    @MainActor
    func testOnboarding_noExistingCloudData_noRestorePrompt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        // Do NOT set FERNLET_UI_TEST_EXISTING_CLOUD_DATA
        app.launch()

        skipToStorageChoiceStep(app)

        _ = app.descendants(matching: .any)["onboarding.storage.icloud"]
            .waitForExistence(timeout: 8)

        // Matched on the affordance's full title, not on the bare word. `CONTAINS 'Restore'` also
        // matched the DETECTION-FAILED copy — "…choose Sync to iCloud to restore it."
        // (`OnboardingStorageChoiceView.swift:115`) — which is exactly what renders on a machine
        // where the live iCloud check cannot complete, since this test deliberately does not set
        // `FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION`. So the assertion failed for having no iCloud
        // account rather than for showing a restore prompt. The card's own title is
        // "Restore from iCloud" (line 57), and nothing else on the screen contains that phrase.
        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'Restore from iCloud'"))
                .firstMatch
                .exists,
            "Restore prompt should be absent when no cloud data exists"
        )
    }

    // MARK: - Scenario 4: iCloud disable flow

    /// Toggling off iCloud sync shows the deletion confirmation sheet with record
    /// counts, requires typing "DELETE", and dismisses when confirmed.
    @MainActor
    func testICloudDisable_fullFlow_confirmationAndDismissal() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, iCloudEnabled: true)
        openVerifiedPrivacyData(app)

        // Toggle off → the two-outcome confirmation sheet appears
        openICloudDisableSheet(app)

        // Confirm button disabled before typing
        let confirmButton = element("privacy.icloud.confirmDelete", in: app)
        XCTAssertFalse(confirmButton.isEnabled, "Confirm button should be disabled before typing DELETE")

        // Partial text: still disabled
        let textField = app.textFields["privacy.icloud.confirmText"]
        textField.tapAndType("DEL")
        XCTAssertFalse(confirmButton.isEnabled, "Confirm button should be disabled with partial text")

        // Clear and type correct confirmation
        textField.clearText()
        textField.typeText("DELETE")
        XCTAssertTrue(confirmButton.isEnabled, "Confirm button should be enabled after typing DELETE")

        // Tap confirm — sheet should dismiss
        confirmButton.tap()
        XCTAssertTrue(
            app.navigationBars["Privacy & Data"].waitForExistence(timeout: 5),
            "Privacy & Data screen should remain after confirming deletion"
        )
    }

    /// Typing DELETE and confirming causes the reload spinner to appear.
    @MainActor
    func testICloudDisable_confirmDelete_spinnerAppearsWhileReloading() throws {
        let app = launchPrivacyApp(
            lockConfigured: true,
            freshAuth: true,
            iCloudEnabled: true,
            slowReload: true
        )
        openVerifiedPrivacyData(app)

        openICloudDisableSheet(app)

        let textField = app.textFields["privacy.icloud.confirmText"]
        textField.tapAndType("DELETE")
        element("privacy.icloud.confirmDelete", in: app).tap()

        XCTAssertTrue(
            element("privacy.storage.spinner", in: app).waitForExistence(timeout: 3),
            "Reload spinner should appear while persistence reloads after deletion"
        )
    }

    /// Tapping cancel on the confirmation sheet leaves iCloud sync enabled.
    @MainActor
    func testICloudDisable_cancelConfirmation_leavesToggleOn() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true, iCloudEnabled: true)
        openVerifiedPrivacyData(app)

        openICloudDisableSheet(app)

        // Dismiss by tapping outside / cancel — look for a Cancel button first
        let cancelButton = app.buttons["Cancel"]
        if cancelButton.waitForExistence(timeout: 2) {
            cancelButton.tap()
        } else {
            // fallback: swipe down to dismiss sheet
            app.swipeDown()
        }

        // Toggle should still show enabled (value "1" for UISwitch)
        let syncRow = labeledElement(containing: "Sync to iCloud", in: app)
        XCTAssertTrue(syncRow.waitForExistence(timeout: 3))
        // If a UISwitch child exists its value should be "1"
        let toggle = syncRow.switches.firstMatch
        if toggle.exists {
            XCTAssertEqual(toggle.value as? String, "1", "Toggle should remain on after cancel")
        }
    }

    // MARK: - Scenario 7: Lock gate on Privacy & Data

    /// When the lock is configured but not yet authenticated, accessing Privacy & Data
    /// shows the lock gate overlay rather than the controls.
    @MainActor
    func testLockGate_lockedState_blocksPrimaryControls() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: false)
        openPrivacyData(app)

        XCTAssertTrue(
            element("privacy.lock.gate", in: app).waitForExistence(timeout: 4),
            "Lock gate overlay should be visible when lock is configured but not authenticated"
        )
        XCTAssertFalse(
            element("privacy.controls", in: app).exists,
            "Primary controls should not be accessible while locked"
        )
    }

    /// When the lock has never been configured, accessing Privacy & Data routes to the
    /// lock setup interstitial instead of the primary settings.
    @MainActor
    func testLockGate_notConfigured_showsSetupInterstitial() throws {
        let app = launchPrivacyApp(lockConfigured: false, freshAuth: false)
        openPrivacyData(app)

        // The setup CTA overlay text (from FernletLockGateModifier.setupCTAOverlay)
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] 'Set up app lock'")
            ).firstMatch.waitForExistence(timeout: 4),
            "Lock setup CTA should appear when lock has not been configured"
        )
        XCTAssertFalse(
            element("privacy.icloud.toggle", in: app).exists,
            "iCloud toggle should not be accessible via the not-configured interstitial"
        )
    }

    /// After authenticating (fresh auth), the primary Privacy & Data controls become visible.
    @MainActor
    func testLockGate_afterAuthentication_controlsAreAccessible() throws {
        let app = launchPrivacyApp(lockConfigured: true, freshAuth: true)
        openVerifiedPrivacyData(app)

        XCTAssertTrue(
            element("privacy.controls", in: app).waitForExistence(timeout: 5),
            "Privacy controls should be visible after successful authentication"
        )
        XCTAssertFalse(
            element("privacy.lock.gate", in: app).exists,
            "Lock gate overlay should be gone after authentication"
        )
    }

    // MARK: - Launch helpers

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
        XCTAssertTrue(
            app.navigationBars["Privacy & Data"].waitForExistence(timeout: 8),
            "Privacy & Data screen should appear"
        )
    }

    @MainActor
    private func openVerifiedPrivacyData(_ app: XCUIApplication) {
        openPrivacyData(app)
        let verifyButton = element("privacy.verify", in: app)
        if verifyButton.waitForExistence(timeout: 2) {
            verifyButton.tap()
        }
        XCTAssertTrue(
            labeledElement(containing: "Sync to iCloud", in: app).waitForExistence(timeout: 4),
            "iCloud toggle should be visible after verification"
        )
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
        let row = labeledElement(containing: "Sync to iCloud", in: app)
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

    /// Tap through welcome and lock-setup screens to reach the storage choice step.
    @MainActor
    private func skipToStorageChoiceStep(_ app: XCUIApplication) {
        // Wait for welcome screen
        let continueButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Continue' OR label CONTAINS[c] 'Get started'")
        ).firstMatch
        if continueButton.waitForExistence(timeout: 5) {
            continueButton.tap()
        }

        // Lock setup: skip if present
        let skipLock = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'Skip' OR label CONTAINS[c] 'Later'")
        ).firstMatch
        if skipLock.waitForExistence(timeout: 3) {
            skipLock.tap()
        }
    }

    // MARK: - Query helpers

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    @MainActor
    private func labeledElement(containing text: String, in app: XCUIApplication) -> XCUIElement {
        // Excludes the page's "privacy.controls" marker container: it is a real accessibility
        // container (.contain) whose aggregated label CONTAINS every child's label, so without
        // the exclusion firstMatch returns the whole stack and a tap lands mid-page.
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label CONTAINS %@ AND identifier != 'privacy.controls'", text
            ))
            .firstMatch
    }
}

// MARK: - XCUIElement helper

extension XCUIElement {
    /// Taps a text field and types only once keyboard focus has actually landed: on the iOS 26
    /// simulator the sheet's field takes focus a beat after the tap, and a bare
    /// `tap(); typeText(...)` fails with "Neither element nor any descendant has keyboard focus"
    /// even though the field is fine for a real user. One re-tap covers a swallowed first tap.
    func tapAndType(_ text: String) {
        tap()
        if !waitForKeyboardFocus(timeout: 2) { tap() }
        XCTAssertTrue(waitForKeyboardFocus(timeout: 2), "text field never took keyboard focus")
        typeText(text)
    }

    /// Polls the element's `hasKeyboardFocus` attribute under a wall-clock deadline instead of
    /// asserting focus that the tap only just requested.
    func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"),
            object: self
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Clear the text in a text field by selecting all and deleting.
    func clearText() {
        guard let text = value as? String, !text.isEmpty else { return }
        tap()
        let selectAll = XCUIApplication().menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 1) {
            selectAll.tap()
            typeText(XCUIKeyboardKey.delete.rawValue)
        } else {
            let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count)
            typeText(deleteString)
        }
    }
}
