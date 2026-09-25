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

        // The section is the LAST thing in Move's scroll column (`MoveView.scrollContent`), so scroll
        // to the true bottom — until the strip's frame stops moving — rather than stopping the moment
        // the strip becomes hittable. `capture()` audits the whole visible screen, and what it reports
        // for the strip depends on where the scroll came to rest. Measured 2026-09-24 on a fresh
        // iPhone 17, same binary each time: started at the bottom, or 30 or 80pt above it, the audit
        // reported the first card's caption (and, under that day's seed, its date chip) clipped —
        // it pulls a page resting within 78pt of the bottom back to one fixed offset first; started
        // 150 or 230pt above, it reported neither. "Hittable" holds anywhere from the bottom to
        // ~175pt above it, so the old stop landed wherever the last fling happened to end: the shape
        // of both reds the 2026-09-24 integration run saw on main (the caption alone missing on one
        // build, chip and caption on the other). The bottom sits inside the band the audit pulls to
        // one viewport. Same scroll as `RecentBitesUITests`.
        let strip = app.descendants(matching: .any)["move.progressPhotos"]
        var previous = CGRect.zero
        var settled = false
        for _ in 0..<12 {
            app.swipeUp()
            let current = strip.exists ? strip.frame : .zero
            if strip.exists && current == previous {
                settled = true
                break
            }
            previous = current
        }
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "Progress photos strip not found under Move")
        XCTAssertTrue(settled, "Move never came to rest at the bottom, so the audit below would not be "
            + "measuring the viewport its baseline was recorded on")

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
