import XCTest

/// Guards the #7 redesigned home cards: First Aid previews its tools as chips, and Milestones shows the
/// kept kinds of care as a keepsake shelf. Both must render and stay tappable to their destinations.
@MainActor
final class HomeCardsRedesignUITests: XCTestCase {

    func testFirstAidAndMilestonesCardsRenderAndOpen() {
        let app = UXTestApp.launch()

        let firstAid = app.descendants(matching: .any)["home.firstAid"].firstMatch
        XCTAssertTrue(scrollUntilHittable(firstAid, in: app), "First Aid card not reachable")

        // The card is one tap target (chips are decorative) and opens the First Aid sheet.
        firstAid.tap()
        let firstAidSheet = app.staticTexts["Slow breathing"].firstMatch
        XCTAssertTrue(firstAidSheet.waitForExistence(timeout: 5), "First Aid card did not open the tools sheet")
        // Dismiss the sheet.
        app.swipeDown(velocity: .fast)

        let milestones = app.descendants(matching: .any)["home.milestones"].firstMatch
        XCTAssertTrue(scrollUntilHittable(milestones, in: app), "Milestones card not reachable")
        milestones.tap()
        // MilestonesView presents as a large sheet (HOME-13, 2026-08-21 redesign); assert its
        // stable screen anchor, which survived the push → sheet conversion (a bare
        // navigationBars.firstMatch check matched ANY nav bar, so it passed without opening
        // anything at all).
        XCTAssertTrue(app.descendants(matching: .any)["screen.milestones"].firstMatch.waitForExistence(timeout: 5),
                      "Milestones card did not present the Milestones sheet")
    }

    /// Scrolls the home feed until the element is hittable — both cards sit near the bottom, behind the
    /// floating tab bar, so "exists" isn't enough to tap.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
