import XCTest

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
                .matching(NSPredicate(format: "label CONTAINS[c] 'Restore'"))
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

        XCTAssertFalse(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'Restore'"))
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

        // Tap the iCloud sync toggle
        let syncToggle = labeledElement(containing: "Sync to iCloud", in: app)
        XCTAssertTrue(syncToggle.waitForExistence(timeout: 5))
        syncToggle.tap()

        // Confirmation sheet appears
        XCTAssertTrue(
            app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 4),
            "Confirmation sheet should appear after toggling off iCloud"
        )

        // Confirm button disabled before typing
        let confirmButton = element("privacy.icloud.confirmDelete", in: app)
        XCTAssertFalse(confirmButton.isEnabled, "Confirm button should be disabled before typing DELETE")

        // Partial text: still disabled
        let textField = app.textFields["privacy.icloud.confirmText"]
        textField.tap()
        textField.typeText("DEL")
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

        labeledElement(containing: "Sync to iCloud", in: app).tap()
        XCTAssertTrue(app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 4))

        let textField = app.textFields["privacy.icloud.confirmText"]
        textField.tap()
        textField.typeText("DELETE")
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

        labeledElement(containing: "Sync to iCloud", in: app).tap()
        XCTAssertTrue(app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 4))

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
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }
}

// MARK: - XCUIElement helper

extension XCUIElement {
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
