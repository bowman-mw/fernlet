// SessionPhotoReviewFirstUITests.swift
// FernletUITests
//
// Session photos U3 (2026-09-30), the owner's words: "the pop up screen for selecting photos should
// be the first thing shown. None of the photos should be saved to the camera roll until this
// selection has been made."
//
// One launch, end to end: `-uitestSeedHeldSessionPhotos 3` holds three generated photos as an
// ENDED session's awaiting review before the review's first evaluation (the same sealed pending
// corpus and capture door a real session uses — never the wall), and then:
//   1. the review's overlay is the first thing on screen, before any tab is touched;
//   2. "Not now" hides it, answering nothing, and the Friends tab says photos are waiting;
//   3. a background/foreground cycle brings it back;
//   4. "Keep selected" puts the photos in the Friends album.
//
// Deliberately NOT `UXTestApp.launch`: that helper waits for the Home tab to be hittable, and the
// overlay — which hides the main window from accessibility while it shows — is exactly what this
// suite expects to be up first. Run it on a fresh simulator, serially (a run that dies between the
// seed and the Keep leaves photos waiting for the next launch of the app on that simulator).

import XCTest

/// The session-end photo review is the first thing shown, and Not now / relaunch / Keep behave.
final class SessionPhotoReviewFirstUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The whole road, on one launch.
    @MainActor
    func testTheReviewIsTheFirstThingShownAndKeepPutsThePhotosInTheAlbum() {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding", "-uitestSeedHeldSessionPhotos", "3"]
        app.launch()

        let overlay = app.descendants(matching: .any)["friends.review.overlay"].firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 60), "the review was not the first thing shown")
        XCTAssertTrue(app.buttons["friends.review.notNow"].exists, "the overlay offers Not now")
        XCTAssertTrue(app.switches["friends.review.alsoSaveToPhotosToggle"].exists
                      || app.descendants(matching: .any)["friends.review.alsoSaveToPhotosToggle"].exists,
                      "and the opt-in camera-roll toggle")

        app.buttons["friends.review.notNow"].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 10), "Not now hides the review")
        let friendsTab = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friendsTab.waitForExistence(timeout: 10), "the tab bar is back")
        friendsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["friends.pendingReview.card"].waitForExistence(timeout: 10),
                      "the Friends tab says photos are waiting")

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(overlay.waitForExistence(timeout: 20), "a background/foreground cycle brings the review back")

        app.buttons["friends.review.saveSelected"].tap()
        XCTAssertTrue(overlay.waitForNonExistence(timeout: 15), "Keep selected answers and hides the review")
        XCTAssertTrue(friendsTab.waitForExistence(timeout: 10))
        friendsTab.tap()
        let kept = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo from"))
        XCTAssertTrue(kept.firstMatch.waitForExistence(timeout: 10), "the kept photos are in the Friends album")
        XCTAssertFalse(app.descendants(matching: .any)["friends.pendingReview.card"].exists,
                       "and nothing is waiting any more")
    }
}
