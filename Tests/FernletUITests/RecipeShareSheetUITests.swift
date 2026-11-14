import XCTest

/// The recipe Share screen's "Share outside Fernlet" card (2026-09-30, the owner's report that sharing
/// a recipe outside Fernlet "pastes the raw json data").
///
/// On a simulator Messages is never set up — `MFMessageComposeViewController.canSendText()` is false
/// on every one (measured on iOS 26.5), and presenting the composer anyway throws — so what can be
/// driven here is the fallback: the note that stands in for "Send in Messages", and "Share as text"
/// opening the system share sheet. The card itself, sent to another iPhone, is a device check; the
/// text's content is pinned by `RecipeShareTextTests`. Screenshots are attached for review.
final class RecipeShareSheetUITests: XCTestCase {
    @MainActor
    func testTheShareScreenExplainsMessagesAndSharesText() throws {
        let app = UXTestApp.launch()  // demo-seeded: "Overnight oats" has notes and steps
        openFoodPanel(in: app)

        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food")
        XCTAssertTrue(scrollIntoClearView(recipeBook, in: app), "Recipe book button not reachable on Food")
        recipeBook.tap()

        let share = app.buttons["Share recipe"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 6), "no recipe row offers Share in the book")
        share.tap()

        // World (`b3-recipe-share` draft 2): the Include notes switch moved to Settings › Sharing,
        // and the screen says so in a line under the cards.
        let notesLine = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Notes and the picture go along as set in Settings")).firstMatch
        XCTAssertTrue(notesLine.waitForExistence(timeout: 6), "the screen does not say where the notes choice lives")
        let note = app.descendants(matching: .any)["recipeShare.messagesNote"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 4), "the Messages row's note is missing")
        XCTAssertTrue(note.label.contains("Messages isn't set up"), "unexpected note: \(note.label)")
        XCTAssertFalse(app.buttons["recipeShare.sendInMessages"].exists,
                       "Send in Messages is offered where Messages cannot send (the composer would throw)")

        let text = app.buttons["recipeShare.shareAsText"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 4), "Share as text is missing")
        bringIntoView(text, in: app)
        attachScreenshot(of: app, named: "Recipe Share screen · Share outside Fernlet")
        XCTAssertGreaterThanOrEqual(text.frame.height, 44, "the row is under the 44pt target")

        text.tap()
        let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Copy'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 8), "the system share sheet did not open")
        // Let the sheet finish rising before the picture: Copy exists mid-animation.
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: copy)
        _ = XCTWaiter().wait(for: [settled], timeout: 4)
        attachScreenshot(of: app, named: "Recipe Share screen · system share sheet")
        copy.tap()
    }

    // MARK: - Helpers

    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Drags the Share screen up until `element` is hittable: the sheet opens at its medium detent,
    /// with the second card below the fold.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<6 where !(element.isHittable && element.frame.maxY < window.frame.maxY - 20) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }
    }

    /// Opens the Food panel from the map's item bar (`world.item.food`) and waits for its page. One
    /// retry: a tap in the first seconds after launch is occasionally lost.
    @MainActor
    private func openFoodPanel(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let page = app.descendants(matching: .any)["screen.food"].firstMatch
        let slot = app.buttons["world.item.food"].firstMatch
        for _ in 0..<2 where !page.exists {
            XCTAssertTrue(slot.waitForExistence(timeout: 30), "the item bar has no Food slot", file: file, line: line)
            slot.tap()
            _ = page.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(page.exists, "the Food panel never showed screen.food", file: file, line: line)
    }

    /// Drags the Food panel's page until the element sits wholly between the panel's plate and the
    /// bottom of the screen, and has stopped moving (a second read agrees), so the tap lands on its
    /// centre. Each suite keeps its own copy.
    private func scrollIntoClearView(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let topClear: CGFloat = 130
        let bottomClear: CGFloat = 40
        for _ in 0..<14 {
            guard element.exists else { dragFeed(by: 300, in: app); continue }
            let frame = element.frame
            let bottom = window.frame.maxY - bottomClear
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

    /// A press-drag-hold of about `distance` points that ends where it is told to (no fling).
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
