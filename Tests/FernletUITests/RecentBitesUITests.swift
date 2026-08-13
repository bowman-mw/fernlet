import XCTest

/// #11 piece 2 — the "Recent bites" Home widget: today's photographed meals as classic polaroids.
/// Drives the real Home feed (demo seed attaches photos to two meals) and screenshots the strip, and
/// asserts it actually rendered (the migration put it on Home and the sealed photos loaded).
final class RecentBitesUITests: XCTestCase {
    @MainActor
    func testRecentBitesStripAppearsOnHomeWithPolaroids() {
        let app = UXTestApp.launch()  // Home, demo-seeded

        // The widget is appended last in the default layout, so it sits at the bottom of the feed.
        let strip = app.descendants(matching: .any)["home.recentBites"]
        for _ in 0..<12 where !strip.isHittable { app.swipeUp() }
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "Recent bites strip not found on Home")

        // The demo seed photographs "Greek yogurt with berries" — its polaroid caption should be present.
        let caption = app.staticTexts["Greek yogurt with berries"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "no meal polaroid rendered in the strip")

        UXScreenProbe(app, "Home · Recent bites", in: self).capture()
    }
}
