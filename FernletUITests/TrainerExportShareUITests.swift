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
// The dedicated `FERNLET_UI_TEST_OPEN_PRIVACY_DATA` hook can't be used here — it renders Privacy &
// Data with NO store (deliberately, to skip the launch pipeline), and the trainer card only renders
// when a store is present. So this drives the real route: Settings sheet → Privacy & Data.

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

    /// Settings sheet → Privacy & Data → trainer sheet → "Prepare summary", leaving the screen on the
    /// prepared state with `trainer.share` on-screen.
    @MainActor
    private func launchToPreparedTrainerSummary() -> XCUIApplication {
        // `FERNLET_UI_TEST_PRIVACY_SERVICES` gates the lock-configured override, so both are needed to
        // land on the privacy controls rather than the app-lock interstitial.
        let app = UXTestApp.launch(openSheet: "settings", extraEnvironment: [
            "FERNLET_UI_TEST_PRIVACY_SERVICES": "1",
            "FERNLET_UI_TEST_LOCK_CONFIGURED": "1",
            "FERNLET_UI_TEST_PRIVACY_AUTH": "1",
        ])

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 12), "Settings sheet did not open")
        let privacyRow = scrollTo(app.buttons["Privacy & Data"], in: app)
        XCTAssertTrue(privacyRow.isHittable, "the Privacy & Data row is not reachable")
        privacyRow.tap()

        XCTAssertTrue(app.navigationBars["Privacy & Data"].waitForExistence(timeout: 8), "Privacy & Data did not open")
        let verify = element("privacy.verify", in: app)
        if verify.waitForExistence(timeout: 2) { verify.tap() }

        // By LABEL, not by `privacy.trainerShare`: the privacy-controls container carries its own
        // `.accessibilityIdentifier`, which overrides every child's — the same reason this screen's
        // existing suite reaches its toggles by label.
        let openTrainer = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Share with a trainer"))
            .firstMatch
        XCTAssertTrue(openTrainer.waitForExistence(timeout: 5), "the trainer-share card never rendered")
        XCTAssertTrue(scrollTo(openTrainer, in: app).isHittable, "the trainer-share card is not reachable")
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
