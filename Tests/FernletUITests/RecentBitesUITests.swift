import XCTest

/// #11 piece 2 — the "Recent bites" Home widget: today's photographed meals as classic polaroids.
/// Drives the real Today feed (demo seed attaches photos to two meals) and screenshots the strip, and
/// asserts it actually rendered (the migration put it on Home and the sealed photos loaded). In the
/// World look Home is the map and its cards live in the Today panel, which the status plate opens.
final class RecentBitesUITests: XCTestCase {
    @MainActor
    func testRecentBitesStripAppearsOnHomeWithPolaroids() throws {
        let app = UXTestApp.launch()  // Home, demo-seeded
        let plate = app.buttons["world.statusPlate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 10), "the map's status plate is missing")
        plate.tap()
        XCTAssertTrue(app.buttons["world.panel.close"].firstMatch.waitForExistence(timeout: 8),
                      "the status plate did not open Today")

        // The widget is appended last in the default layout, so it sits at the bottom of the feed.
        //
        // Scroll ALL the way to the bottom (Arrange Today follows the last card) rather than stopping the moment the strip becomes
        // hittable. `capture()` audits the whole visible screen, so where the scroll stops decides
        // which elements the audit sees — and "stop as soon as it is hittable" stops at a different
        // offset whenever Today's content height changes, which another suite adding a meal is
        // enough to do. That is how this probe picked up hygiene-card findings ("Brush teeth AM",
        // "Brush teeth PM") that its baseline had never described, on runs where nothing about the
        // screen itself had changed. The bottom of the feed is the same viewport every time.
        let strip = app.descendants(matching: .any)["home.recentBites"]
        var previous = CGRect.zero
        for _ in 0..<12 {
            app.swipeUp()
            let current = strip.exists ? strip.frame : .zero
            if strip.exists && current == previous { break }
            previous = current
        }
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "Recent bites strip not found in Today")

        // The demo seed photographs "Greek yogurt with berries" — its polaroid caption should be present.
        let caption = app.staticTexts["Greek yogurt with berries"]
        XCTAssertTrue(caption.waitForExistence(timeout: 5), "no meal polaroid rendered in the strip")

        try UXScreenProbe(app, "Home · Recent bites", in: self).capture()
    }
}
