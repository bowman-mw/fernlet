import XCTest

/// The on-screen half of the owner's report of 2026-09-29: "When you click save for period
/// tracking, but you're not sharing to HealthKit, it doesn't work."
///
/// With Fernlet's Health sharing off (the default), a flow level is refused by the write gate, and
/// the whole log with it. The sheet used to say so only in a success-green sentence at the very
/// end of its scroll, below the note box, so tapping Save looked like tapping nothing. This drives
/// that exact path — open the sheet, tap a flow chip, tap Save — and asks that the notice is up
/// front, that the refusal is drawn where the user is looking (hittable, not scrolled away), and
/// that the sheet stayed open with the entry. `PeriodLogSharingOffTests` pins the store contract.
final class PeriodLogHealthSharingOffUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testARefusedFlowLogIsExplainedBesideSave() throws {
        let app = UXTestApp.launch(openSheet: "logPeriod")
        let sheet = app.descendants(matching: .any)["sheet.logPeriod"]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 15), "the period log sheet never opened")

        // The preferences keychain outlives the app on a simulator, and two Settings suites seed
        // "Share with Health" ON. With sharing on this path writes to Health instead of refusing
        // (and the sheet asks in context), so there is nothing to test — say so, never pass vacuously.
        let notice = app.staticTexts["logPeriod.healthNotice"]
        guard notice.exists || notice.waitForExistence(timeout: 5) else {
            throw XCTSkip("Fernlet's cycle sharing with Health is ON in this simulator's keychain; this case needs the default (off).")
        }

        app.buttons["Medium"].firstMatch.tap()
        app.buttons["Save"].firstMatch.tap()

        let status = app.staticTexts["logPeriod.status"]
        XCTAssertTrue(status.exists || status.waitForExistence(timeout: 10), "a refused Save must say why")
        XCTAssertTrue(status.isHittable, "the refusal must be on screen beside Save, not scrolled out of sight")
        XCTAssertTrue(status.label.contains("Nothing was saved"), "the refusal must not read as a save: \(status.label)")
        XCTAssertTrue(sheet.exists, "a refused Save keeps the sheet, and the entry, open")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Log period · refused for sharing off"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
