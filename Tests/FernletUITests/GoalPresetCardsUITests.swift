import XCTest

/// Feature A — goal preset cards in Settings › Goal & nutrition. Opens the subscreen, screenshots the
/// cards, and verifies selecting a different goal actually moves the selection (the cards drive
/// `settings.selectedGoal`, replacing the old Picker).
final class GoalPresetCardsUITests: XCTestCase {
    @MainActor
    func testGoalPresetCardsRenderAndSelect() throws {
        let app = UXTestApp.launch(openSheet: "settings")

        // Open Goal & nutrition.
        let row = app.buttons["Goal & nutrition"]
        for _ in 0..<8 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 8), "Goal & nutrition row not found")
        row.tap()

        XCTAssertTrue(app.navigationBars["Goal & nutrition"].waitForExistence(timeout: 8),
                      "Goal & nutrition subscreen did not open")

        // Each card is a Button carrying its own `goalPreset.<goal>` identifier (its title/summary text
        // is combined into the button label). Assert one rendered.
        let strengthCard = app.buttons["goalPreset.strength"]
        XCTAssertTrue(strengthCard.waitForExistence(timeout: 5), "goal preset cards did not render")

        try UXScreenProbe(app, "Settings · Goal preset cards", in: self).capture()

        // Wellness is the seeded default; pick Strength and confirm the selection moves.
        XCTAssertFalse(strengthCard.isSelected, "Strength should not start selected (Wellness is default)")
        for _ in 0..<6 where !strengthCard.isHittable { app.swipeUp() }
        strengthCard.tap()
        XCTAssertTrue(strengthCard.isSelected, "tapping the Strength card did not select it")

        try UXScreenProbe(app, "Settings · Goal preset selected", in: self).capture()
    }
}
