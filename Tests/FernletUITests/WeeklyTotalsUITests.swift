import XCTest

/// The Move tab's Weekly totals screen (comparison report idea 18), driven on the demo-seeded app:
/// the link under Exercise history opens it, it audits clean under the shared probe (geometry plus
/// the accessibility audit, whose Dynamic Type pass re-lays it out at the other text sizes), and it
/// steps back a week and forward again but never past the current week.
///
/// The screen's numbers move with the seed's dates, so nothing here asserts a count; the unit suite
/// `WeeklyTrainingSummaryTests` owns the arithmetic.
final class WeeklyTotalsUITests: XCTestCase {
    @MainActor
    func testWeeklyTotalsOpensFromMoveStepsByWeekAndAuditsClean() throws {
        let app = UXTestApp.launch()
        app.buttons["Move"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.move"].waitForExistence(timeout: 8), "Move did not open")

        let link = app.buttons["move.weeklyTotals"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 6), "Move has no Weekly totals link")
        XCTAssertTrue(scrollClearOfTabBar(link, in: app), "Weekly totals link not reachable on Move")
        XCTAssertEqual(link.label, "Weekly totals", "the link's spoken and Voice Control name")
        link.tap()

        let screen = app.descendants(matching: .any)["screen.weeklyTotals"].firstMatch
        XCTAssertTrue(screen.waitForExistence(timeout: 6), "Weekly totals did not open")
        let previous = app.buttons["weeklyTotals.previousWeek"].firstMatch
        let next = app.buttons["weeklyTotals.nextWeek"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 4), "the current week offers no step back")
        XCTAssertFalse(next.exists, "the current week offers a step into the future")
        // The week header reads as one element ("Oct 19 – 25, This week"), so match within its label.
        let thisWeek = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "This week")).firstMatch
        XCTAssertTrue(thisWeek.exists, "the current week is not labelled as such")

        try UXScreenProbe(app, "Move · Weekly totals", in: self)
            .assertOnScreen("screen.weeklyTotals")
            .assertBelowStatusBar("screen.weeklyTotals")
            .capture()

        previous.tap()
        XCTAssertTrue(next.waitForExistence(timeout: 4), "a past week offers no step forward")
        XCTAssertTrue(thisWeek.waitForNonExistence(timeout: 4), "a past week is labelled as this week")
        next.tap()
        XCTAssertTrue(thisWeek.waitForExistence(timeout: 4), "stepping forward did not return to this week")
        XCTAssertTrue(next.waitForNonExistence(timeout: 4), "back on the current week, a step into the future appeared")
    }

    // MARK: - Helpers (each suite keeps its own copy, as `TabReselectUITests` does)

    /// Drags the page until the element sits wholly between the status bar and the floating tab bar:
    /// a tap whose point lands inside the bar's pill selects a tab instead.
    private func scrollClearOfTabBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let topClear: CGFloat = 100
        let tabBarClear: CGFloat = 16
        for _ in 0..<14 {
            guard element.exists else { dragFeed(by: 300, in: app); continue }
            let frame = element.frame
            let bottom = tabBarTop(in: app) - tabBarClear
            let top = window.frame.minY + topClear
            if frame.maxY > bottom {
                dragFeed(by: frame.maxY - bottom + 40, in: app)
            } else if frame.minY < top {
                dragFeed(by: frame.minY - top - 40, in: app)
            } else if element.isHittable, element.frame == frame {
                return true
            }
        }
        return false
    }

    /// The top of the floating tab bar, read off its Home tab.
    private func tabBarTop(in app: XCUIApplication) -> CGFloat {
        let homeTab = app.buttons["Home"].firstMatch
        return homeTab.exists ? homeTab.frame.minY : app.windows.firstMatch.frame.maxY
    }

    /// Moves the page's content up by about `distance` points (down when negative) with a
    /// press-drag-hold, which ends where it is told to — unlike `swipeUp()`'s fling.
    private func dragFeed(by distance: CGFloat, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let height = window.frame.height
        let travel = min(max(abs(distance) + 10, 60), height * 0.45) / height
        let startY: CGFloat = distance > 0 ? 0.70 : 0.30
        let endY = distance > 0 ? startY - travel : startY + travel
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
    }
}
