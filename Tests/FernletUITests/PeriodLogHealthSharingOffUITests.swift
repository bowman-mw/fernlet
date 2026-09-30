import XCTest

/// The on-screen half of the owner's report of 2026-09-29: "When you click save for period
/// tracking, but you're not sharing to HealthKit, it doesn't work."
///
/// With Fernlet's Health sharing off (the default), a flow level is refused by the write gate, and
/// the whole log with it. The sheet used to say so only in a success-green sentence at the very
/// end of its scroll, below the note box, so tapping Save looked like tapping nothing. This drives
/// that exact path — open the sheet, tap a flow chip, tap Save — and asks that the notice is up
/// front, that the refusal is drawn where the user is looking (hittable, not scrolled away), and
/// that the sheet stayed open with the entry. It then takes the route the refusal offers — clearing
/// the flow and saving a symptom alone — which since 2026-09-30 is KEPT with no passcode (held for
/// the Private tab's next open, sealed under its no-passcode key): the sheet says so and freezes
/// with Done, never "Health event saved". `PeriodLogSharingOffTests` pins the store contract.
///
/// Sharing is pinned OFF at launch (`FERNLET_UI_TEST_HEALTH_SHARING_OFF`) rather than read off the
/// sheet: the preferences keychain outlives the app and two Settings suites seed it ON, and a probe
/// that looked at the notice under test skipped exactly when the notice regressed. The app lock is
/// reset at launch (`FERNLET_UI_TEST_RESET_APP_LOCK`), so this runs the default user: no sharing,
/// no passcode.
final class PeriodLogHealthSharingOffUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testARefusedFlowLogIsExplainedBesideSave() {
        let app = UXTestApp.launch(
            openSheet: "logPeriod",
            extraEnvironment: ["FERNLET_UI_TEST_HEALTH_SHARING_OFF": "1", "FERNLET_UI_TEST_RESET_APP_LOCK": "1"]
        )
        let sheet = app.descendants(matching: .any)["sheet.logPeriod"]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 15), "the period log sheet never opened")

        let notice = app.staticTexts["logPeriod.healthNotice"]
        XCTAssertTrue(notice.exists || notice.waitForExistence(timeout: 5),
                      "with cycle sharing off the sheet must say up front which fields need Apple Health")
        XCTAssertTrue(notice.label.contains("Notes and symptoms still save privately in Fernlet"),
                      "with no passcode, notes and symptoms still save: the notice must say so: \(notice.label)")

        app.buttons["Medium"].firstMatch.tap()
        app.buttons["Save"].firstMatch.tap()

        let status = app.staticTexts["logPeriod.status"]
        XCTAssertTrue(status.exists || status.waitForExistence(timeout: 10), "a refused Save must say why")
        XCTAssertTrue(status.isHittable, "the refusal must be on screen beside Save, not scrolled out of sight")
        XCTAssertTrue(status.label.contains("Nothing was saved"), "the refusal must not read as a save: \(status.label)")
        XCTAssertTrue(status.label.contains("clear the flow"),
                      "notes and symptoms save without a passcode, so the refusal offers that route")
        XCTAssertTrue(sheet.exists, "a refused Save keeps the sheet, and the entry, open")
        attachScreenshot(of: app, named: "Log period · refused for sharing off")

        assertASymptomOnlyEntryIsKeptWithoutAPasscode(app, sheet: sheet, status: status)
    }

    /// Clears the flow chip, turns one symptom on and saves: with no passcode and Private closed the
    /// symptom is held for Private's next open, so the sheet says it saved and freezes with Done.
    @MainActor
    private func assertASymptomOnlyEntryIsKeptWithoutAPasscode(
        _ app: XCUIApplication,
        sheet: XCUIElement,
        status: XCUIElement
    ) {
        app.buttons["Medium"].firstMatch.tap()
        let cramps = app.switches["Cramps"].firstMatch
        XCTAssertTrue(cramps.exists || cramps.waitForExistence(timeout: 5), "the Cramps symptom toggle is missing")
        cramps.tap()
        if cramps.value as? String != "1" {
            // A SwiftUI toggle row can take the tap on its label; the switch sits at the trailing edge.
            cramps.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(cramps.value as? String, "1", "could not turn the Cramps symptom on")

        app.buttons["Save"].firstMatch.tap()

        let kept = NSPredicate(format: "label CONTAINS %@", "Note saved")
        let sawKept = expectation(for: kept, evaluatedWith: status)
        wait(for: [sawKept], timeout: 10)
        XCTAssertFalse(status.label.contains("Nothing was saved"), "a symptom-only entry is kept with no passcode: \(status.label)")
        XCTAssertFalse(status.label.contains("Health event saved"), "nothing reached Health, so nothing may say it did")
        XCTAssertTrue(status.isHittable, "the outcome must be on screen beside the bar")
        XCTAssertTrue(sheet.exists, "a save with a caveat freezes the sheet so the sentence can be read")
        attachScreenshot(of: app, named: "Log period · symptom only, no passcode")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
