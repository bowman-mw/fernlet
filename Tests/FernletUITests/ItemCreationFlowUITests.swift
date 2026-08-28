import XCTest

/// Item creation now splits in two: the editor is just the drawing (with a "Next" bar), and NAMING +
/// shop-listing move to a follow-up confirmation screen. This drives the path to the editor (the
/// customization sheet is opened via a launch hook — its real entry is a long-press XCUITest can't send)
/// and asserts the name/shop controls are NO LONGER on the editor and that it leads to a Next step.
///
/// XCUITest can't drive the custom UIScrollView canvas's paint gesture, so reaching the confirmation
/// screen (Next is disabled while the canvas is blank) uses the `FERNLET_UI_TEST_SEED_STUDIO_CANVAS`
/// DEBUG hook, which opens the editor pre-painted.
final class ItemCreationFlowUITests: XCTestCase {
    @MainActor
    func testNameAndShopAreOffTheEditorAndLeadToNext() throws {
        let app = launchToStudioEditor(seedCanvas: false)

        // Editor: the canvas is here, but the name + shop controls are NOT — they moved to the
        // confirmation step. Instead the editor leads onward with a "Next" bar.
        XCTAssertTrue(app.descendants(matching: .any)["studio.canvas"].waitForExistence(timeout: 20),
                      "editor canvas did not render")
        XCTAssertFalse(app.textFields["studio.confirm.name"].exists, "name field must NOT be on the editor screen")
        XCTAssertFalse(app.descendants(matching: .any)["studio.confirm.listToggle"].exists,
                       "shop listing must NOT be on the editor screen")
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 10),
                      "editor should lead to a Next step, not save directly")

        try UXScreenProbe(app, "Studio · Editor (name/shop moved off)", in: self).capture()
    }

    /// A listing refused by the name gate must TELL the user, from the screen they are actually looking at.
    /// The alert used to hang off the editor — by then the covered middle of the nav stack — so "Save to
    /// closet" read as inert while the item was quietly saved-but-unlisted.
    @MainActor
    func testFlaggedNameShowsAlertOnTheConfirmationScreen() throws {
        let app = launchToStudioEditor(seedCanvas: true)

        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "Next bar not found")
        XCTAssertTrue(next.isEnabled, "seeded canvas should enable Next")
        next.tap()

        // Confirmation step: name it something the shop gate blocks, then ask to list it.
        let nameField = app.textFields["studio.confirm.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 6), "confirmation screen did not push")
        nameField.tap()
        // Resign the keyboard and let it finish leaving, so the following taps are aimed at the settled
        // layout rather than the keyboard-compressed one.
        nameField.typeText("shitty hat\n")
        waitForKeyboardToDismiss(in: app)

        let listToggle = app.switches["studio.confirm.listToggle"].firstMatch
        XCTAssertTrue(listToggle.waitForExistence(timeout: 10), "shop listing toggle not found")
        if listToggle.value as? String != "1" { listToggle.tap() }

        let save = app.buttons["Save to closet"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "save bar not found")
        save.tap()

        // The refusal must surface here, on the topmost screen — not be swallowed by the covered editor.
        let alert = app.alerts["Pick a friendlier name"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6),
                      "flagged-name alert must present on the confirmation screen")

        try UXScreenProbe(app, "Studio · Confirmation (flagged name)", in: self).capture()

        alert.buttons["OK"].tap()

        // Dismissing leaves the user on the confirmation screen so they can rename and retry.
        XCTAssertTrue(nameField.waitForExistence(timeout: 4),
                      "should stay on the confirmation screen to rename and retry")
    }

    /// Saving must leave the user in the CLOSET, looking at the thing they just made — not on Home
    /// with the whole customization sheet gone.
    ///
    /// The studio is pushed inside that sheet and "Save to closet" is tapped from the confirmation
    /// step, one push above the studio. From there the studio's environment `dismiss` no longer
    /// pops: it degrades to dismissing the nearest presentation — the sheet — so a save dropped the
    /// user on Home and the new item was never seen. Both entry points are covered here (the
    /// "Design a new item" row and, on the way back out, an existing item's row), because both were
    /// broken and the push mechanism was never the cause.
    @MainActor
    func testSavingPopsBackToTheWardrobeAndKeepsTheSheetUp() {
        let app = launchToStudioEditor(seedCanvas: true)

        saveFromTheEditor(in: app)

        // Back in the closet — the sheet is still up (the Wardrobe only exists inside it) and the
        // studio is gone. (The coin balance moved to the customize sheet's header in the
        // 2026-08-21 redesign, so the Wardrobe's own chrome is its navigation bar now.)
        let designNew = waitForButton(in: app, labelContaining: "Design a new item", timeout: 10)
        XCTAssertNotNil(designNew, "saving should pop back to the Wardrobe, not dismiss the sheet")
        XCTAssertTrue(app.navigationBars["Wardrobe"].exists,
                      "the Wardrobe's own chrome should be on screen after saving")
        XCTAssertFalse(app.descendants(matching: .any)["studio.canvas"].exists,
                       "the studio should have been popped off the stack")

        // The saved item is in the closet, which is the whole point of landing here.
        guard let saved = waitForButton(in: app, labelContaining: "designed by you", timeout: 10) else {
            XCTFail("the item just saved is not in the closet")
            return
        }

        // The edit entry point exits through the same seam: open the saved item and save again.
        saved.tap()
        XCTAssertTrue(app.descendants(matching: .any)["studio.canvas"].waitForExistence(timeout: 20),
                      "tapping a closet item should push its editor")
        saveFromTheEditor(in: app)

        XCTAssertNotNil(waitForButton(in: app, labelContaining: "Design a new item", timeout: 10),
                        "saving an EDITED item should pop back to the Wardrobe too")
    }

    // MARK: - Helpers

    /// Editor → "Next" → "Save to closet", with no name and no listing: the shortest path through the
    /// two-step save.
    @MainActor
    private func saveFromTheEditor(in app: XCUIApplication) {
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), "Next bar not found")
        next.tap()

        let save = app.buttons["Save to closet"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "confirmation screen did not push")
        save.tap()
    }

    /// Drives customization sheet → Wardrobe row (at the sheet root since the 2026-08-21
    /// redesign, HOME-30) → "Design a new item".
    @MainActor
    private func launchToStudioEditor(seedCanvas: Bool) -> XCUIApplication {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_OPEN_CUSTOMIZE"] = "1"
        if seedCanvas { app.launchEnvironment["FERNLET_UI_TEST_SEED_STUDIO_CANVAS"] = "1" }
        app.launch()
        expandSheetToFullHeight(in: app)

        // The Wardrobe is a named row at the sheet root now (it used to be reachable only from
        // inside a slot picker's custom-items section).
        let wardrobe = app.buttons["companion.wardrobe"]
        XCTAssertTrue(wardrobe.waitForExistence(timeout: 30), "customization sheet did not open with a Wardrobe row")
        for _ in 0..<6 where !wardrobe.isHittable { app.swipeUp() }
        wardrobe.tap()

        guard let design = waitForButton(in: app, labelContaining: "Design a new item", timeout: 10) else {
            XCTFail("Design a new item not found")
            return app
        }
        design.tap()

        // Don't hand back an app that hasn't arrived yet: every caller's first assertion is about the
        // editor, and without this a slow push reads as a content failure rather than a slow push.
        _ = app.descendants(matching: .any)["studio.canvas"].waitForExistence(timeout: 20)

        return app
    }

    /// Drags the customization sheet up to its large detent.
    ///
    /// The sheet is `[.medium, .large]` and opens at medium about half the time. At medium its lower
    /// content sits over the presentation's dismiss region, so a tap aimed at a control near the bottom
    /// of the sheet — the shop toggle, in particular — falls through and dismisses the whole sheet
    /// instead of hitting the control. Interacting only at the large detent removes that entire class of
    /// flake (and matches how the screen is actually used).
    @MainActor
    private func expandSheetToFullHeight(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            let grabber = app.buttons["Sheet Grabber"].firstMatch
            if grabber.exists {
                if (grabber.value as? String)?.localizedCaseInsensitiveContains("half") != true { return }
                grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.05,
                           thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)))
                return
            }
            usleep(200_000)
        } while Date() < deadline
    }

    /// Blocks until the software keyboard is gone, plus a beat for the layout to settle behind it.
    @MainActor
    private func waitForKeyboardToDismiss(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(5)
        while app.keyboards.count > 0, Date() < deadline {
            usleep(200_000)
        }
        usleep(700_000)
    }

    /// Waits for a button whose label contains `text`, re-resolving the query on every poll and scrolling
    /// while it looks. Two distinct flakes made the naive wait unreliable here:
    ///
    ///  * `waitForExistence` on a cached `.firstMatch` of a predicate query does NOT re-resolve once it
    ///    has missed, so it reported "not found" for an element plainly present a moment later.
    ///  * The customization sheet opens at either the half or the full detent. At half, its lower rows
    ///    are off-screen and absent from the accessibility hierarchy, so no amount of *waiting* finds
    ///    them — the sheet has to be scrolled/expanded first.
    ///
    /// The initial settle window keeps the first swipe from landing before the sheet is up.
    @MainActor
    private func waitForButton(in app: XCUIApplication,
                               labelContaining text: String,
                               timeout: TimeInterval) -> XCUIElement? {
        let predicate = NSPredicate(format: "label CONTAINS[c] %@", text)
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var swipes = 0
        repeat {
            let element = app.buttons.matching(predicate).firstMatch
            if element.exists { return element }
            if Date().timeIntervalSince(start) > 3, swipes < 8 {
                app.swipeUp()
                swipes += 1
            } else {
                usleep(200_000)
            }
        } while Date() < deadline
        return nil
    }
}
