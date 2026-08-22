import XCTest

// MARK: - Move tab header actions and the relocated Suggest entry
//
// The Move header was Log + Suggest; on 2026-08-12 Suggest moved into the plan sheet and Share (the
// trainer / coach handoff) took its slot. This suite pins BOTH ends of that move, because either
// half silently regressing leaves a working-looking app with a feature nobody can reach: Suggest
// gone from the header AND absent from the plan sheet would strand the whole suggestion engine.
//
// NOTE ON SKIPS: there are none, deliberately. An earlier draft guarded its navigation with
// `XCTSkip` when an element wasn't found, and both plan-sheet tests then SKIPPED on a bad
// week-strip matcher while the suite still reported success — verifying nothing. Every step here
// asserts instead, so a matcher that stops matching fails loudly.

final class MoveHeaderActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The header offers Log and Share, and no longer offers Suggest.
    @MainActor
    func testMoveHeaderOffersLogAndShareAndNoLongerSuggest() {
        let app = openMove()

        XCTAssertTrue(app.buttons["Log"].firstMatch.waitForExistence(timeout: 8),
                      "the Log pill must stay in the Move header")
        XCTAssertTrue(element("move.trainerShare", in: app).isHittable,
                      "the Share pill must be in the Move header and tappable")
        XCTAssertFalse(app.buttons["Suggest"].firstMatch.exists,
                       "Suggest moved into the plan sheet; it must not still be in the header")
    }

    /// FLOW-03: the Move root's always-rendered "Today's workout" card offers Suggest in its empty
    /// state, and tapping it opens the suggestion flow directly — one sheet, straight from the
    /// root. Asserted (never skipped) like everything else here: a fresh launch has no approved
    /// plan, so the empty state MUST be showing.
    @MainActor
    func testMoveRootCardOffersSuggestWhenNothingPlanned() {
        let app = openMove()

        let suggest = element("workout.suggestToday", in: app)
        XCTAssertTrue(suggest.waitForExistence(timeout: 8),
                      "the Today's-workout card must render its empty-state Suggest primary on a fresh launch")
        XCTAssertTrue(suggest.isHittable, "the root Suggest entry is not tappable")

        suggest.tap()
        XCTAssertTrue(app.staticTexts["Suggest workout"].waitForExistence(timeout: 10),
                      "tapping the root Suggest entry did not present the suggestion flow")
    }

    /// Suggest is reachable from the plan sheet for TODAY — the other half of the move.
    @MainActor
    func testPlanSheetForTodayOffersSuggest() {
        let app = openMove()
        openPlanSheet(in: app, forToday: true)

        let suggest = element("plan.suggest", in: app)
        XCTAssertTrue(suggest.waitForExistence(timeout: 6),
                      "the plan sheet must offer Suggest now that the header doesn't")
        XCTAssertTrue(suggest.isHittable, "the Suggest entry is not tappable")

        suggest.tap()
        XCTAssertTrue(app.staticTexts["Suggest workout"].waitForExistence(timeout: 10),
                      "tapping Suggest did not present the suggestion flow")
        // The plan sheet must still be mounted underneath — the whole reason this is presented from
        // the plan sheet rather than routed through the tab's sheet slot is that a part-filled plan
        // survives the detour.
        XCTAssertTrue(app.staticTexts["Plan workout"].exists,
                      "the plan sheet was dismissed to show the suggestion flow; it must stay behind it")
    }

    /// Planning a day that ISN'T today must not offer Suggest: the suggestion flow reads today's
    /// committed plan, today's readiness, and today's logged sessions, so offering it elsewhere would
    /// generate and commit a plan for the wrong day — silently.
    @MainActor
    func testPlanSheetForAnotherDayDoesNotOfferSuggest() {
        let app = openMove()
        openPlanSheet(in: app, forToday: false)

        XCTAssertFalse(element("plan.suggest", in: app).exists,
                       "Suggest must be hidden when planning a day other than today")
    }

    // MARK: - Helpers

    @MainActor
    private func openMove() -> XCUIApplication {
        let app = UXTestApp.launch()
        let move = app.buttons["Move"].firstMatch
        XCTAssertTrue(move.waitForExistence(timeout: 15), "no Move tab")
        move.tap()
        return app
    }

    /// Drills into a week-strip day, then opens its plan sheet from the day detail's Plan button.
    ///
    /// Matches on the cell's real accessibility label (`"Today, day 12, Upper"` /
    /// `"Friday, day 14, planned Lower"`), and for the not-today case takes any cell that isn't
    /// today's — there are always six, which sidesteps month-boundary and weekday edge cases that a
    /// date-arithmetic matcher would trip over.
    @MainActor
    private func openPlanSheet(in app: XCUIApplication, forToday: Bool) {
        let predicate = forToday
            ? NSPredicate(format: "label BEGINSWITH %@", "Today, day ")
            : NSPredicate(format: "label CONTAINS %@ AND NOT (label BEGINSWITH %@)", ", day ", "Today, day ")
        let cell = app.buttons.matching(predicate).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10),
                      "no \(forToday ? "today" : "other-day") cell in the Move week strip")
        cell.tap()

        let plan = app.buttons["Plan"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 8), "the day detail's Plan button never appeared")
        plan.tap()

        XCTAssertTrue(app.staticTexts["Plan workout"].waitForExistence(timeout: 8),
                      "the plan sheet did not open")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
