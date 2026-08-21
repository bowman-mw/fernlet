import XCTest

/// Gym-location delete + rename, driven through the real sheet.
///
/// The bug worth catching is invisible at the moment of the tap: `removeLocation` used to mutate only the
/// view's `@State`, which is seeded from the store at init. The card disappeared, the user believed the
/// location was gone, and the removal was silently discarded unless they happened to tap a save bar —
/// both steps of this sheet can be swipe-dismissed. So the assertion that matters is made AFTER closing
/// and reopening the sheet, not after the tap.
@MainActor
final class WorkoutLocationUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDeletingALocationSticksAfterReopeningTheSheet() throws {
        let app = UXTestApp.launch()
        let sheet = try openLocationSheet(in: app)

        // Need a second location: the last one can't be deleted (nothing to fall back to).
        // Asserted, not skipped: a skip here would quietly pass while testing nothing, which is exactly
        // how the first version of this test "passed" against an unexercised delete.
        XCTAssertTrue(addTemplateLocation(in: app, sheet: sheet), "could not add a second location")

        // Count CARDS, not delete buttons: going 2 -> 1 locations hides every trash button (the last
        // location can't be deleted), so a delete-button count would drop to 0 whether the delete
        // worked or not.
        let cards = app.descendants(matching: .any).matching(identifier: "workout.location.card")
        let countBefore = cards.count
        XCTAssertEqual(countBefore, 2, "expected the built-in plus the one just added")

        let deleteButtons = app.descendants(matching: .any).matching(identifier: "workout.location.delete")
        XCTAssertEqual(deleteButtons.count, 2, "no visible delete affordance on the location cards")

        deleteButtons.element(boundBy: 1).tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "delete fired with no confirmation")
        XCTAssertTrue(alert.staticTexts.element(boundBy: 1).label.contains("equipment"),
                      "the confirm doesn't say the equipment goes with it")
        alert.buttons["Delete"].tap()

        XCTAssertTrue(waitForCount(cards, toReach: 1), "the card did not go away after confirming")

        // THE assertion: close WITHOUT tapping a save bar, reopen, and see if it stayed gone. This is the
        // bug — removeLocation only edited @State, so the card vanished and then came back.
        dismissSheet(app)
        _ = try openLocationSheet(in: app)
        let after = app.descendants(matching: .any).matching(identifier: "workout.location.card")
        XCTAssertTrue(waitForCount(after, toReach: 1),
                      "the deleted location came back after reopening — the delete never persisted")
    }

    func testRenamingALocationSticksAfterReopeningTheSheet() throws {
        let app = UXTestApp.launch()
        _ = try openLocationSheet(in: app)

        // Open the built-in for editing (the pencil), which lands on the equipment step where the name
        // field lives.
        let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no edit affordance")
        edit.tap()

        let nameField = app.textFields["workout.location.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "no rename field on the equipment step")

        // Screenshot the rename row for the UX gallery + so a reviewer can eyeball the chip layout.
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Location equipment step — rename chip"
        shot.lifetime = .keepAlways
        add(shot)

        nameField.tap()
        // Select-all + replace, so this doesn't depend on the starting text.
        nameField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        nameField.typeText("Garage")

        // Leave the equipment step via the BACK chevron (not the save bar), then swipe the whole sheet
        // away — the same "no explicit save" path that used to lose a delete. The rename must survive it.
        app.descendants(matching: .any)["workout.location.back"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Your spaces"].waitForExistence(timeout: 5),
                      "back chevron did not return to the location list")
        dismissSheet(app)
        _ = try openLocationSheet(in: app)

        XCTAssertTrue(app.staticTexts["Garage"].waitForExistence(timeout: 5),
                      "the rename did not persist across back + swipe + reopen")
    }

    /// The variant the older rename test does NOT cover. That one leaves the equipment step through the
    /// back chevron, which already calls `commitEdits()`, so it passed even before the swipe path was
    /// fixed. Here the user renames and swipe-dismisses the sheet STRAIGHT from the equipment step —
    /// touching neither the save bar nor the back chevron. That exit ran no commit path at all, so the
    /// rename evaporated on dismiss and the old name came back on the next open. The `.onDisappear`
    /// commit is what this asserts.
    func testRenamingThenSwipeDismissingStraightFromEquipmentStepSticks() throws {
        let app = UXTestApp.launch()
        _ = try openLocationSheet(in: app)

        // Pencil on the built-in → the equipment step, where the rename field lives.
        let edit = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no edit affordance")
        edit.tap()

        let nameField = app.textFields["workout.location.name"].firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "no rename field on the equipment step")

        nameField.tap()
        // Select-all + replace so this doesn't depend on the starting text; the trailing "\n" fires the
        // Done key to drop the keyboard while STAYING on the equipment step (no onSubmit is wired, so it
        // doesn't commit — the swipe is what must).
        nameField.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        nameField.typeText("Shed\n")

        // THE broken path: swipe the whole sheet away from the equipment step. No save bar, no back
        // chevron.
        swipeDismissFromEquipmentStep(app)
        XCTAssertTrue(app.staticTexts["What's available?"].waitForNonExistence(timeout: 5),
                      "the swipe-dismiss gesture did not close the equipment-step sheet")

        _ = try openLocationSheet(in: app)
        XCTAssertTrue(app.staticTexts["Shed"].waitForExistence(timeout: 5),
                      "the rename did not persist across a swipe-dismiss straight from the equipment step")
    }

    // MARK: - Helpers

    /// Walks Move → the location setup sheet. Driven by a11y id, never by tapping blind: the Space
    /// segment's LABEL is the location's name, which this suite renames.
    private func openLocationSheet(in app: XCUIApplication) throws -> XCUIElement {
        let move = app.buttons["Move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 15), "no Move tab")
        move.tap()

        let space = app.descendants(matching: .any)["move.space"].firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 10), "no Space entry point on Move")
        space.tap()

        let header = app.staticTexts["Your spaces"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 8), "the location sheet did not open")
        return header
    }

    /// Adds a second location from the "Home setup" template so there is something deletable (the last
    /// location can't be removed — there'd be nothing to fall back to). Presets live BEHIND the
    /// "Add a location" tile now (MOVE-34), so the walk is tile → preset → Save location.
    ///
    /// Matches the button's own label, not `.containing()`: that matcher tests DESCENDANTS, so it
    /// silently found nothing and turned this test into a skip that verified the delete never ran.
    private func addTemplateLocation(in app: XCUIApplication, sheet: XCUIElement) -> Bool {
        let addTile = app.descendants(matching: .any)["workout.location.add"].firstMatch
        guard addTile.waitForExistence(timeout: 5), addTile.isHittable else { return false }
        addTile.tap()
        let template = app.buttons["Home setup, Your own space"].firstMatch
        guard template.waitForExistence(timeout: 5), template.isHittable else { return false }
        template.tap()
        let save = app.buttons["Save location"].firstMatch
        guard save.waitForExistence(timeout: 8) else { return false }
        save.tap()
        // Saving dismisses the sheet; reopen for the delete.
        return (try? openLocationSheet(in: app)) != nil
    }

    /// Swipes the sheet away. Deliberately does NOT tap "Done".
    ///
    /// Done runs the save bar, which persists `locations` — so dismissing that way hides the bug
    /// completely: the first version of this test tapped Done and passed against the unfixed code.
    /// Swipe-dismiss is the path a user actually takes after a delete feels finished, and it was the
    /// path that silently discarded it.
    private func dismissSheet(_ app: XCUIApplication) {
        let sheet = app.descendants(matching: .any)["workout.location.card"].firstMatch
        let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.6))
        let end = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 12))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Swipes the sheet away while it's on the EQUIPMENT step — where there are no location cards to
    /// anchor on, so `dismissSheet` can't be reused. Anchors on the "What's available?" header (which
    /// lives above the equipment ScrollView, so a downward drag from it is caught by the sheet's
    /// pan-to-dismiss rather than scrolling the list) and drags far below the screen.
    private func swipeDismissFromEquipmentStep(_ app: XCUIApplication) {
        let anchor = app.staticTexts["What's available?"].firstMatch
        let start = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.0))
        let end = anchor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 24))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func waitForCount(_ query: XCUIElementQuery, toReach target: Int) -> Bool {
        for _ in 0..<20 {
            if query.count == target { return true }
            usleep(250_000)
        }
        return false
    }
}
