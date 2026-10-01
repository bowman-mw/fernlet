import XCTest

/// The on-screen half of the owner's report of 2026-09-29 — "When you click save for period
/// tracking, but you're not sharing to HealthKit, it doesn't work." — and of their answer the next
/// day, Option B: every period log is saved in Fernlet's own encrypted store whatever the Health
/// switches say (period-data design 2026-09-30, §6.3, §10.4).
///
/// The default user, end to end: no Health sharing, no passcode. Open the log sheet, tap a flow chip
/// and a symptom, tap Save — the save SUCCEEDS (with the Private tab closed it is held until the tab
/// next opens, and the sheet says so), then open Private with its one Unlock button and the day is on
/// the cycle calendar with its flow. `PeriodLogSharingOffTests` pins the store contract.
///
/// Sharing is pinned OFF at launch (`FERNLET_UI_TEST_HEALTH_SHARING_OFF`) rather than read off the
/// sheet: the preferences keychain outlives the app and two Settings suites seed it ON. The app lock
/// is reset at launch (`FERNLET_UI_TEST_RESET_APP_LOCK`), so this runs with no passcode and the
/// Private tab's tap gate.
final class PeriodLogHealthSharingOffUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testAFlowLogSavesWithSharingOffAndTheDayShows() {
        let app = UXTestApp.launch(
            openSheet: "logPeriod",
            extraEnvironment: ["FERNLET_UI_TEST_HEALTH_SHARING_OFF": "1", "FERNLET_UI_TEST_RESET_APP_LOCK": "1"]
        )
        let sheet = app.descendants(matching: .any)["sheet.logPeriod"]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 15), "the period log sheet never opened")

        let notice = app.staticTexts["logPeriod.healthNotice"]
        XCTAssertTrue(notice.exists || notice.waitForExistence(timeout: 5),
                      "with cycle sharing off the sheet must say up front that the entry is not copied to Health")
        XCTAssertTrue(notice.label.contains("Saved privately in Fernlet"), "the notice must promise the private save: \(notice.label)")

        app.buttons["Medium"].firstMatch.tap()
        turnOnCramps(in: app)
        app.buttons["Save"].firstMatch.tap()

        let status = app.staticTexts["logPeriod.status"]
        let held = NSPredicate(format: "label CONTAINS %@", "next time you open Private")
        wait(for: [expectation(for: held, evaluatedWith: status)], timeout: 10)
        XCTAssertFalse(status.label.contains("Nothing was saved"), "a flow log with sharing off saves: \(status.label)")
        XCTAssertTrue(status.isHittable, "the outcome must be on screen beside the bar")
        attachScreenshot(of: app, named: "Log period · saved with sharing off")

        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Done closes the sheet")

        assertTheDayIsOnTheCalendar(app)
    }

    /// Opens Private with its one button, goes to Cycle, and finds today's cell carrying the flow.
    @MainActor
    private func assertTheDayIsOnTheCalendar(_ app: XCUIApplication) {
        app.buttons["Private"].firstMatch.tap()
        let unlock = app.buttons["lock.tapGate.unlock"].firstMatch
        XCTAssertTrue(unlock.waitForExistence(timeout: 15), "with no passcode the Private tab shows the tap screen")
        unlock.tap()
        XCTAssertTrue(unlock.waitForNonExistence(timeout: 15), "one tap opens Private")

        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 8), "the Private hub has no Cycle section")
        cycle.tap()
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Today, day", "Medium")).firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 15), "the day saved with sharing off must be on the calendar with its flow")
        attachScreenshot(of: app, named: "Cycle · the day saved with sharing off")
    }

    /// Turns the Cramps symptom on.
    @MainActor
    private func turnOnCramps(in app: XCUIApplication) {
        let cramps = app.switches["Cramps"].firstMatch
        XCTAssertTrue(cramps.exists || cramps.waitForExistence(timeout: 5), "the Cramps symptom toggle is missing")
        cramps.tap()
        if cramps.value as? String != "1" {
            // A SwiftUI toggle row can take the tap on its label; the switch sits at the trailing edge.
            cramps.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(cramps.value as? String, "1", "could not turn the Cramps symptom on")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
