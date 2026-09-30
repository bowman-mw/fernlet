import XCTest

/// The on-screen half of the owner's report of 2026-09-29: "When you click save for period
/// tracking, but you're not sharing to HealthKit, it doesn't work."
///
/// With Fernlet's Health sharing off (the default), a flow level is refused by the write gate, and
/// the whole log with it. The sheet used to say so only in a success-green sentence at the very
/// end of its scroll, below the note box, so tapping Save looked like tapping nothing. This drives
/// that exact path — open the sheet, tap a flow chip, tap Save — and asks that the notice is up
/// front, that the refusal is drawn where the user is looking (hittable, not scrolled away), and
/// that the sheet stayed open with the entry. It then takes the route the refusal used to offer
/// every user, clearing the flow and saving a symptom alone, which with no app lock stores nothing:
/// the sheet must refuse it in words, never announce "Health event saved".
/// `PeriodLogSharingOffTests` pins the store contract.
///
/// Sharing is pinned OFF at launch (`FERNLET_UI_TEST_HEALTH_SHARING_OFF`) rather than read off the
/// sheet: the preferences keychain outlives the app and two Settings suites seed it ON, and a probe
/// that looked at the notice under test skipped exactly when the notice regressed. No UI suite sets
/// up an app lock (a fresh simulator has none; see `LockGateObservabilityUITests`), so this runs
/// the default user: no sharing, no lock.
final class PeriodLogHealthSharingOffUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testARefusedFlowLogIsExplainedBesideSave() {
        let app = UXTestApp.launch(
            openSheet: "logPeriod",
            extraEnvironment: ["FERNLET_UI_TEST_HEALTH_SHARING_OFF": "1"]
        )
        let sheet = app.descendants(matching: .any)["sheet.logPeriod"]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 15), "the period log sheet never opened")

        let notice = app.staticTexts["logPeriod.healthNotice"]
        XCTAssertTrue(notice.exists || notice.waitForExistence(timeout: 5),
                      "with cycle sharing off the sheet must say up front which fields need Apple Health")
        XCTAssertTrue(notice.label.contains("only when app lock is on"),
                      "with no app lock the notice must not promise that notes save: \(notice.label)")

        app.buttons["Medium"].firstMatch.tap()
        app.buttons["Save"].firstMatch.tap()

        let status = app.staticTexts["logPeriod.status"]
        XCTAssertTrue(status.exists || status.waitForExistence(timeout: 10), "a refused Save must say why")
        XCTAssertTrue(status.isHittable, "the refusal must be on screen beside Save, not scrolled out of sight")
        XCTAssertTrue(status.label.contains("Nothing was saved"), "the refusal must not read as a save: \(status.label)")
        XCTAssertFalse(status.label.contains("clear the flow"),
                       "with no app lock, clearing the flow keeps nothing, so the refusal must not offer it")
        XCTAssertTrue(sheet.exists, "a refused Save keeps the sheet, and the entry, open")
        attachScreenshot(of: app, named: "Log period · refused for sharing off")

        assertASymptomOnlyEntryIsRefusedWithoutALock(app, sheet: sheet, status: status)
    }

    /// Clears the flow chip, turns one symptom on and saves: nothing of that entry can be kept
    /// without an app lock, so the sheet must refuse it in words and stay open with it.
    @MainActor
    private func assertASymptomOnlyEntryIsRefusedWithoutALock(
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

        let refused = NSPredicate(format: "label CONTAINS %@", "nothing else to save")
        let sawRefusal = expectation(for: refused, evaluatedWith: status)
        wait(for: [sawRefusal], timeout: 10)
        XCTAssertTrue(status.label.contains("Nothing was saved"), "a symptom-only entry with no lock stores nothing: \(status.label)")
        XCTAssertFalse(status.label.contains("Health event saved"), "nothing reached Health, so nothing may say it did")
        XCTAssertTrue(status.isHittable, "the refusal must be on screen beside Save")
        XCTAssertTrue(sheet.exists, "a refused Save keeps the sheet, and the entry, open")
        XCTAssertTrue(app.buttons["Save"].firstMatch.exists, "a refused Save leaves Save armed, not a frozen Done")
        attachScreenshot(of: app, named: "Log period · symptom only, no app lock")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
