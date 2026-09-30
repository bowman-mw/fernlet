import XCTest

/// The no-passcode Private tab on screen (period-data design 2026-09-30, §10.1–§10.2; the owner's
/// words: "Keep the unlock screen, but with only an unlock button. Makes showing this information
/// have a little friction").
///
/// Every launch resets the app lock (`FERNLET_UI_TEST_RESET_APP_LOCK`) so the simulator starts with
/// no passcode and no device key whatever other suites left behind. What is pinned:
/// - the gate is ONE button, with no passcode field of any kind, and says plainly what it is;
/// - one tap opens the tab, and backgrounding closes it again;
/// - entries no key on this iPhone can open are NAMED on a card before anything is removed, "Not now"
///   removes nothing, and only "Remove them and open Private" deletes and opens.
/// `LockGateAccessibilityBoundaryTests` is the source half (one `Button(` in the controls region, no
/// credential field, no "locked/protected/secured"); `PrivateHubOpenCoordinatorTests` the store half.
final class PrivateTapGateUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches with no passcode (and, optionally, one entry sealed under a key that is gone), then
    /// opens the Private tab.
    @MainActor
    private func launchToTheGate(seedingUnopenableEntry: Bool = false) -> XCUIApplication {
        var environment = ["FERNLET_UI_TEST_RESET_APP_LOCK": "1"]
        if seedingUnopenableEntry { environment["FERNLET_UI_TEST_SEED_UNOPENABLE_ENTRY"] = "1" }
        let app = UXTestApp.launch(extraEnvironment: environment)
        app.buttons["Private"].firstMatch.tap()
        return app
    }

    @MainActor
    private func unlockButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["lock.tapGate.unlock"].firstMatch
    }

    /// One button, no credential field, honest words — and one tap opens the tab.
    @MainActor
    func testTheGateIsOneButtonAndOneTapOpensPrivate() {
        let app = launchToTheGate()
        let unlock = unlockButton(app)
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "with no passcode the Private tab must show the tap screen")
        XCTAssertEqual(unlock.label, "Unlock")
        XCTAssertTrue(unlock.isHittable, "the one button must be reachable")
        XCTAssertEqual(app.secureTextFields.count, 0, "the no-passcode gate asks for no passcode")
        XCTAssertEqual(app.textFields.matching(identifier: "lock.field.password").count, 0)
        let honesty = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "No passcode is set")).firstMatch
        XCTAssertTrue(honesty.exists, "the gate must say plainly that no passcode stands in front of the page")
        attachScreenshot(of: app, named: "Private · no-passcode tap screen")

        unlock.tap()

        XCTAssertTrue(unlock.waitForNonExistence(timeout: 15), "one tap must open the Private tab")
        attachScreenshot(of: app, named: "Private · opened by the tap")
    }

    /// Backgrounding closes a tap-opened tab: coming back shows the tap screen again.
    @MainActor
    func testBackgroundingClosesTheTapOpenedTab() {
        let app = launchToTheGate()
        let unlock = unlockButton(app)
        XCTAssertTrue(unlock.waitForExistence(timeout: 15))
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 15), "the tap must open the tab first")

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(unlockButton(app).waitForExistence(timeout: 15),
                      "backgrounding must close the tab; the tap screen comes back")
    }

    /// Entries no key here can open are named first; "Not now" deletes nothing; only Remove opens.
    @MainActor
    func testUnopenableEntriesAreNamedBeforeAnythingIsRemoved() {
        let app = launchToTheGate(seedingUnopenableEntry: true)
        let unlock = unlockButton(app)
        XCTAssertTrue(unlock.waitForExistence(timeout: 15))
        unlock.tap()

        let remove = app.buttons["lock.unopenable.remove"].firstMatch
        let notNow = app.buttons["lock.unopenable.notNow"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "a new key over unopenable entries must stop at the card")
        XCTAssertTrue(notNow.exists)
        XCTAssertTrue(app.staticTexts["Cycle entries: 1"].exists, "the card names what it would remove")
        attachScreenshot(of: app, named: "Private · entries this iPhone can't open")

        notNow.tap()
        XCTAssertTrue(unlockButton(app).waitForExistence(timeout: 10), "Not now leaves Private closed")
        unlockButton(app).tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 15), "Not now removed nothing: the same card comes back")

        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 15))
        XCTAssertFalse(unlockButton(app).exists, "after Remove, Private is open")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
