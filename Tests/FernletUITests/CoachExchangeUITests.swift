import XCTest

// MARK: - The manual coach exchange (Move tab → Share with a trainer)
//
// Pins the three things a unit test can't see: that the gate actually gates, that the two coach
// cards are REACHABLE from the Move tab (the screen moved off Settings → Privacy & Data on
// 2026-08-12), and that the paste sheet refuses junk with a visible error instead of accepting it.
//
// The copy button is deliberately only checked for existence and hittability — tapping it presents a
// confirmation alert about data leaving the device, and a UI test should not be the thing that
// teaches anyone that dialog is skippable.

final class CoachExchangeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Off by default: with no launch hook, neither coach card exists — the default install has no
    /// unsigned-plan ingestion path at all. This is the test that would catch the gate being
    /// defaulted to `true`.
    @MainActor
    func testCoachCardsAreAbsentWhenTheGateIsOff() {
        let app = openTrainerScreen(coachExchange: false)

        XCTAssertTrue(element("trainer.prepare", in: app).waitForExistence(timeout: 5),
                      "the shipped file-export half must still be there with the gate off")
        XCTAssertFalse(element("trainer.copyForAI", in: app).exists,
                       "the clipboard card must not exist unless the exchange is switched on")
        XCTAssertFalse(element("trainer.pastePlan", in: app).exists,
                       "the import card must not exist unless the exchange is switched on")
    }

    /// With the gate on, both halves are present and reachable on the same consent surface.
    @MainActor
    func testCoachCardsAppearAndAreReachableWhenTheGateIsOn() {
        let app = openTrainerScreen(coachExchange: true)

        let copy = element("trainer.copyForAI", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the copy-for-an-AI card never rendered")
        XCTAssertTrue(scrollTo(copy, in: app).isHittable, "the copy card is not reachable")

        let paste = element("trainer.pastePlan", in: app)
        XCTAssertTrue(paste.exists, "the paste-a-plan card never rendered")
        XCTAssertTrue(scrollTo(paste, in: app).isHittable, "the paste card is not reachable")
    }

    /// Junk in must produce a visible, honest error — not silence, and not a review screen over a
    /// plan that was never read.
    @MainActor
    func testPastingNonsenseShowsAnErrorAndOpensNoReviewScreen() {
        let app = openTrainerScreen(coachExchange: true)

        let paste = element("trainer.pastePlan", in: app)
        XCTAssertTrue(scrollTo(paste, in: app).isHittable, "the paste card is not reachable")
        paste.tap()

        let editor = element("coachPaste.editor", in: app)
        XCTAssertTrue(editor.waitForExistence(timeout: 6), "the paste sheet did not open")
        editor.tap()
        editor.typeText("I can't help with that.")

        let read = element("coachPaste.read", in: app)
        XCTAssertTrue(scrollTo(read, in: app).isHittable, "the Read plan button is not reachable")
        read.tap()

        XCTAssertTrue(element("coachPaste.error", in: app).waitForExistence(timeout: 5),
                      "pasting prose produced no visible error")
        XCTAssertFalse(app.navigationBars["Review plan"].exists,
                       "an unreadable paste must never reach the review gate")
    }

    // MARK: - Helpers

    /// Move tab → "Share with a trainer", with the coach gate seeded on or off.
    @MainActor
    private func openTrainerScreen(coachExchange: Bool) -> XCUIApplication {
        var environment: [String: String] = [:]
        if coachExchange { environment["FERNLET_UI_TEST_COACH_EXCHANGE"] = "1" }
        let app = UXTestApp.launch(extraEnvironment: environment)

        let move = app.buttons["Move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 15), "no Move tab")
        move.tap()

        // The header pill that replaced "Suggest" (2026-08-12). In the header, so no scrolling.
        let share = element("move.trainerShare", in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 10), "the Share pill never rendered in the Move header")
        XCTAssertTrue(share.isHittable, "the Share pill is not tappable")
        share.tap()

        XCTAssertTrue(app.navigationBars["Share with a trainer"].waitForExistence(timeout: 8),
                      "the trainer screen did not open")
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Inertia-free scroll until `target` is hittable and clear of the sheet's top/bottom chrome —
    /// the same press-drag-hold shape the other suites use, because `swipeUp()`'s deceleration keeps
    /// moving rows after hittability is sampled.
    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let topClear: CGFloat = 150
        let bottomClear: CGFloat = 170

        for _ in 0..<14 {
            if target.exists, target.isHittable {
                let frame = target.frame
                let bounds = window.frame
                if frame.minY > bounds.minY + topClear && frame.maxY < bounds.maxY - bottomClear { return target }
            }
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
        return target
    }
}
