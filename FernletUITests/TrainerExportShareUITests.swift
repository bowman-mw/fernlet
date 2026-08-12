import XCTest

// MARK: - Trainer / nutritionist export share control
//
// The trainer summary's share control moved from SwiftUI's `ShareLink` to the
// `UIActivityViewController`-backed `ActivityShareView`, because `ShareLink` has no completion
// callback and the prepared summary is a PLAINTEXT file (workouts, nutrition, injury notes, and —
// when opted in — sickness days and wellbeing scores) that must be deleted the moment sharing
// finishes. That swap replaced the element carrying the `trainer.share` identifier, so this suite
// pins both halves: the identifier still resolves to a hittable control, and finishing the share
// actually runs the cleanup seam (the screen falls back to "Prepare summary").
//
// The route is the MOVE TAB, not Settings: the trainer screen moved there on 2026-08-12 when it
// gained its import half (a plan coming back belongs beside the plans). This suite drives the real
// route rather than a launch hook, so it also pins that relocation — if the card ever drifts back
// into Settings, or off Move, these tests fail rather than silently testing a screen nobody can
// reach.

final class TrainerExportShareUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPreparedTrainerSummaryExposesAHittableShareControl() {
        let app = launchToPreparedTrainerSummary()

        // Preparing swaps the button for the share control. The identifier is the contract the swap
        // had to preserve; hittability is what makes it a real control rather than a stray label.
        let share = element("trainer.share", in: app)
        XCTAssertTrue(share.isHittable, "'trainer.share' exists but can't be tapped")
        XCTAssertFalse(element("trainer.prepare", in: app).exists,
                       "the Prepare button should be replaced once a summary is prepared")
    }

    /// The point of the `ShareLink` → `ActivityShareView` swap: dismissing the share sheet runs
    /// `onFinish`, which deletes the plaintext summary and clears `preparedFile`. The screen falling
    /// back to "Prepare summary" is the observable proof that the completion handler ran — a
    /// `ShareLink` had no such callback, so the file used to linger until the next purge.
    @MainActor
    func testDismissingTheShareSheetRunsTheCleanupSeam() {
        let app = launchToPreparedTrainerSummary()

        element("trainer.share", in: app).tap()

        // The activity sheet is hosted inside this screen's own sheet, so its chrome is in-process.
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8), "the system share sheet never presented")
        close.tap()

        // Hittable, not merely present: that also pins the share sheet actually going away rather than
        // sitting over a screen that happens to have re-rendered underneath it.
        let prepare = element("trainer.prepare", in: app)
        XCTAssertTrue(prepare.waitForExistence(timeout: 8), "share completion did not clear the prepared summary")
        XCTAssertTrue(prepare.isHittable, "the share sheet did not dismiss after completing")
        XCTAssertFalse(element("trainer.share", in: app).exists, "the share control outlived the completed share")
    }

    // MARK: - Helpers

    /// Move tab → trainer sheet → "Prepare summary", leaving the screen on the prepared state with
    /// `trainer.share` on-screen.
    @MainActor
    private func launchToPreparedTrainerSummary() -> XCUIApplication {
        let app = UXTestApp.launch()

        let move = app.buttons["Move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 15), "no Move tab")
        move.tap()

        // The "Share" header pill, which replaced "Suggest" on 2026-08-12. In the header, so it
        // needs no scrolling — but keep the id-based lookup: the label is deliberately short and
        // could plausibly be reworded.
        let openTrainer = element("move.trainerShare", in: app)
        XCTAssertTrue(openTrainer.waitForExistence(timeout: 10), "the Share pill never rendered in the Move header")
        XCTAssertTrue(openTrainer.isHittable, "the Share pill is not tappable")
        openTrainer.tap()

        let prepare = element("trainer.prepare", in: app)
        XCTAssertTrue(prepare.waitForExistence(timeout: 5), "the Prepare summary button never appeared")
        prepare.tap()

        XCTAssertTrue(element("trainer.share", in: app).waitForExistence(timeout: 5),
                      "the prepared summary exposes no 'trainer.share' control")
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    /// Inertia-free scroll until `target` is hittable and clear of the sheet's top/bottom chrome —
    /// the same press-drag-hold shape `SettingsAppearanceUITests` uses, because `swipeUp()`'s
    /// deceleration keeps moving rows after hittability is sampled.
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
