import XCTest

/// #11 piece 3 — the gym progress-photo timeline under the Move tab. Drives the real Move screen (demo
/// seed adds three dated progress photos through the sealed store) and screenshots the strip and the
/// photo detail, asserting the section + detail RENDER and are reachable. Note the card-existence checks
/// key on the dated a11y label, which comes from the (sealed) index — a card still exists even if its
/// photo bytes fail to load (it shows a placeholder), so decoded-byte coverage is the unit test's job:
/// `ProgressPhotoStoreTests.addSealsTheIndexButRecordsRoundTrip` asserts the image round-trips. The
/// attached screenshots are the visual proof the real photos rendered.
final class ProgressPhotoUITests: XCTestCase {
    @MainActor
    func testProgressPhotoTimelineAppearsUnderMoveWithDetail() throws {
        let app = UXTestApp.launch()  // Home, demo-seeded

        app.buttons["Move"].firstMatch.tap()

        // The section sits below the workouts; scroll it into view.
        let strip = app.descendants(matching: .any)["move.progressPhotos"]
        for _ in 0..<12 where !strip.isHittable { app.swipeUp() }
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "Progress photos strip not found under Move")

        // A seeded photo card rendered (its a11y label carries the capture date).
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Progress photo from"))
            .firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "no progress photo card rendered in the strip")

        try UXScreenProbe(app, "Move · Progress photos", in: self).capture()

        // Tap through to the detail view and confirm the editable note + delete affordance rendered.
        card.tap()
        let caption = app.textFields["progressPhoto.caption"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "progress photo detail did not open")
        XCTAssertTrue(app.buttons["progressPhoto.delete"].waitForExistence(timeout: 3),
                      "progress photo detail is missing its delete affordance")

        try UXScreenProbe(app, "Move · Progress photo detail", in: self).capture()
    }
}
