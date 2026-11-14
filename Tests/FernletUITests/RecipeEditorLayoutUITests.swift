import XCTest

/// The recipe editor (`RecipeSheet`) kept clear of the chrome pinned over it, in both of the ways it
/// is shown (2026-10-01, iPhone 17 simulator, iOS 26.5).
///
/// **As a sheet** (the routed `recipe` / `editRecipe` sheets): the draft guard's pinned header
/// (Cancel + "New recipe") was drawn over the first rows. The name field sat at y 117.7–140.7 under a
/// title spanning y 122–157, so NOTES was the first field you could see, a tap on the name hit the
/// header and the field never took focus, and Save stayed disabled for want of a name. The tests
/// below assert the name field starts below the header's title and takes keyboard focus.
///
/// **Pushed** (Food → Recipe book → Create → Manual entry, and its Import sibling): the bottom bar
/// used to rest under the floating tab bar — "Save recipe" at y 785.7–804 inside a tab row spanning
/// y 759.7–820.4, `isHittable` false — so a tap on Save selected the Food tab, and over a typed
/// recipe that re-tap raised "Discard your changes?". The World look has no tab bar: these pages
/// are pushed inside the full-screen Food panel, and what stands at the bottom is the screen's own
/// edge (the home indicator) or, while typing, the keyboard. The tests assert every bottom-bar
/// button sits wholly on screen clear of that edge with the keyboard down, wholly above the keyboard
/// with it up, is hittable, and that a tap on Save stays on the editor — and that the same editor
/// pushed inside the Recipe book SHEET rests on the sheet's bottom edge, lifted by no reservation.
///
/// The original failures reproduced unchanged on iPhone SE (3rd generation), iPhone 17e and iPhone
/// 17 Pro Max: both were structural, not a matter of screen size.
final class RecipeEditorLayoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Sheet: content starts below the pinned header

    @MainActor
    func testNewRecipeSheetNameFieldSitsBelowItsHeaderAndTakesFocus() {
        let app = UXTestApp.launch(openSheet: "recipe")
        assertNameFieldClearsHeader(sheet: "sheet.recipe", title: "New recipe", in: app)
    }

    /// The same body behind the edit route (the recipe detail's Edit, the dismiss-then-represent chain).
    @MainActor
    func testEditRecipeSheetNameFieldSitsBelowItsHeaderAndTakesFocus() {
        let app = UXTestApp.launch(openSheet: "editRecipe")
        assertNameFieldClearsHeader(sheet: "sheet.editRecipe", title: "Edit recipe", in: app)
    }

    // MARK: - Pushed: the bottom bar sits clear of the screen's bottom edge and of the keyboard

    @MainActor
    func testPushedManualEditorSaveBarSitsClearOfTheBottomEdge() {
        let app = UXTestApp.launch()
        openPanel("food", page: "screen.food", in: app)
        openRecipeBookFromFood(in: app)
        openManualEditorFromBook(in: app)
        attachScreenshot(of: app, named: "Pushed manual editor")

        assertClearOfBottom(app.buttons["Save recipe"], named: "Save recipe", in: app)
        assertClearOfBottom(app.buttons["Log & save"], named: "Log & save", in: app)

        // While the name is typed: Save must sit wholly above the keyboard (TabBarKeyboardUITests
        // pins that it then rests right on it).
        let name = nameField(in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 6), "the manual editor has no recipe name field")
        name.tapAndType("Layout soup")
        attachScreenshot(of: app, named: "Pushed manual editor, keyboard up")
        assertClearOfBottom(app.buttons["Save recipe"], named: "Save recipe (keyboard up)", in: app)
        name.typeText("\n")
        XCTAssertTrue(waitForGone(app.keyboards.firstMatch), "the keyboard did not go away after Return")

        // The typed name makes the draft dirty, so a tap that reached anything but Save could raise
        // the discard prompt. Save is still disabled (no ingredient yet): landing on it does nothing.
        app.buttons["Save recipe"].tap()
        XCTAssertFalse(app.alerts["Discard your changes?"].waitForExistence(timeout: 2),
                       "a tap on Save recipe raised the discard prompt")
        XCTAssertTrue(waitForPushedPage("New recipe", in: app, timeout: 2), "a tap on Save recipe left the editor")
    }

    /// The manual editor's sibling on the same chooser carries the same bottom bar.
    @MainActor
    func testPushedImportScreenBarSitsClearOfTheBottomEdge() {
        let app = UXTestApp.launch()
        openPanel("food", page: "screen.food", in: app)
        openRecipeBookFromFood(in: app)
        tapCreate(in: app)
        let importRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Import recipe")).firstMatch
        XCTAssertTrue(importRow.waitForExistence(timeout: 6), "the chooser has no Import recipe option")
        importRow.tap()
        let importButton = app.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 6), "the import screen did not open")
        attachScreenshot(of: app, named: "Pushed import screen")

        assertClearOfBottom(importButton, named: "Import", in: app)
    }

    /// The same create flow inside the root Recipe book SHEET: nothing may lift the save bar there.
    /// It rests on the sheet's bottom edge, within its own padding and the home-indicator inset — a
    /// leaked bottom reservation (the old tab bar's was ~94pt) would float it up over empty space.
    @MainActor
    func testManualEditorInsideTheRecipeBookSheetIsNotLifted() {
        let app = UXTestApp.launch(openSheet: "recipeBook")
        let sheet = app.descendants(matching: .any)["sheet.recipeBook"]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 10), "sheet.recipeBook never appeared")
        openManualEditorFromBook(in: app)
        attachScreenshot(of: app, named: "Manual editor in the recipe book sheet")

        let save = app.buttons["Save recipe"]
        XCTAssertTrue(save.exists || save.waitForExistence(timeout: 6), "no Save recipe button")
        let bottomEdge = min(sheet.frame.maxY, app.windows.firstMatch.frame.maxY)
        XCTAssertLessThanOrEqual(
            bottomEdge - save.frame.maxY, Self.restingBottomAllowance,
            "Save recipe (\(save.frame)) is lifted off the sheet's bottom edge (y \(bottomEdge))"
        )
        XCTAssertTrue(save.isHittable, "Save recipe is not hittable in the sheet")
    }

    // MARK: - Assertions

    /// The sheet's name field starts below its pinned header's title, and a tap on it takes focus.
    @MainActor
    private func assertNameFieldClearsHeader(
        sheet anchor: String,
        title: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let sheet = app.descendants(matching: .any)[anchor]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 10), "\(anchor) never appeared",
                      file: file, line: line)
        let header = app.staticTexts[title].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 6), "the sheet has no \"\(title)\" header", file: file, line: line)
        let name = nameField(in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 6), "the sheet has no recipe name field", file: file, line: line)
        attachScreenshot(of: app, named: "\(anchor) at launch")

        XCTAssertGreaterThanOrEqual(
            name.frame.minY, header.frame.maxY,
            "the name field (\(name.frame)) starts under the pinned \"\(title)\" header (\(header.frame))",
            file: file, line: line
        )
        name.tapAndType("Layout soup")
        XCTAssertTrue((name.value as? String)?.hasSuffix("Layout soup") == true,
                      "typing into the name field did not land in it (value \(String(describing: name.value)))",
                      file: file, line: line)
    }

    /// `button` exists, its whole frame sits above what stands at the bottom of the screen — the
    /// keyboard's drawn top while one is up, else the home-indicator band — and it is hittable.
    @MainActor
    private func assertClearOfBottom(
        _ button: XCUIElement,
        named label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(button.exists || button.waitForExistence(timeout: 6), "no \(label) button",
                      file: file, line: line)
        let keyboard = app.keyboards.firstMatch
        let limit = keyboard.exists
            ? keyboardTop(in: app)
            : app.windows.firstMatch.frame.maxY - Self.homeIndicatorClearance
        XCTAssertLessThanOrEqual(
            button.frame.maxY, limit,
            "\(label) (\(button.frame)) reaches under the \(keyboard.exists ? "keyboard" : "home indicator") (from y \(limit))",
            file: file, line: line
        )
        XCTAssertTrue(button.isHittable, "\(label) is not hittable", file: file, line: line)
    }

    // MARK: - Navigation

    /// The band at the bottom of the screen a bottom bar must stay out of with the keyboard down:
    /// the home indicator's (34pt on iPhone 17), kept lenient for devices with a smaller inset.
    private static let homeIndicatorClearance: CGFloat = 20

    /// How far above the sheet's bottom edge a resting save bar may end: the 36pt between Save's
    /// label and the bar's bottom (`RecipeSheet`), the 34pt home-indicator inset and some slack.
    private static let restingBottomAllowance: CGFloat = 90

    /// The top of the keyboard as drawn: the "Typing Predictions" bar sits on the keys, and its top
    /// is the edge the pages avoid (a copy of `TabBarKeyboardUITests.keyboardTop`).
    private func keyboardTop(in app: XCUIApplication) -> CGFloat {
        let keys = app.keyboards.firstMatch.frame
        let predictions = app.otherElements.matching(NSPredicate(format: "label == %@", "Typing Predictions")).firstMatch
        guard predictions.exists else { return keys.minY }
        let bar = predictions.frame
        return abs(bar.maxY - keys.minY) < 2 ? min(bar.minY, keys.minY) : keys.minY
    }

    /// Opens the World panel `panel` from the map's item bar (`world.item.<panel>`) and waits for its
    /// main page, `identifier`. One retry: a tap in the first seconds after launch is occasionally lost.
    @MainActor
    private func openPanel(
        _ panel: String,
        page identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let page = app.descendants(matching: .any)[identifier].firstMatch
        let slot = app.buttons["world.item.\(panel)"].firstMatch
        for _ in 0..<2 where !page.exists {
            XCTAssertTrue(slot.waitForExistence(timeout: 30), "the item bar has no \(panel) slot", file: file, line: line)
            slot.tap()
            _ = page.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(page.exists, "the \(panel) panel never showed \(identifier)", file: file, line: line)
    }

    /// Waits for a page titled `title` pushed inside a panel or a framed sheet: the World look draws
    /// its title on the plate beside `plate.back` (whose own label names the page it returns to).
    /// A classic navigation bar of that title counts too.
    @MainActor
    private func waitForPushedPage(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 6) -> Bool {
        let bar = app.navigationBars[title]
        let back = app.buttons["plate.back"].firstMatch
        let plateTitle = app.staticTexts[title].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if bar.exists || (back.exists && plateTitle.exists && back.label != "Back to \(title)") { return true }
            _ = back.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        return false
    }

    /// Opens Food → Recipe book (pushed inside the Food panel) and waits for it.
    @MainActor
    private func openRecipeBookFromFood(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food", file: file, line: line)
        XCTAssertTrue(scrollIntoClearView(recipeBook, in: app), "Recipe book button not reachable on Food", file: file, line: line)
        recipeBook.tap()
        XCTAssertTrue(waitForPushedPage("Recipe book", in: app), "the recipe book did not open", file: file, line: line)
    }

    /// Taps the open recipe book's Create and waits for the chooser.
    @MainActor
    private func tapCreate(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 6), "the book has no Create button", file: file, line: line)
        create.tap()
        XCTAssertTrue(waitForPushedPage("Create recipe", in: app), "the create chooser did not open", file: file, line: line)
    }

    /// From the open recipe book: Create → Manual entry, and waits for the empty editor.
    @MainActor
    private func openManualEditorFromBook(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tapCreate(in: app, file: file, line: line)
        let manual = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Manual entry")).firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 6), "the chooser has no Manual entry option", file: file, line: line)
        manual.tap()
        XCTAssertTrue(waitForPushedPage("New recipe", in: app), "the manual editor did not open", file: file, line: line)
    }

    /// The editor's recipe name field, found by its placeholder.
    private func nameField(in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "black bean bowls")).firstMatch
    }

    /// Waits for `element` to leave the tree; true once it has.
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Drags the page until the element sits wholly between the panel's plate and the bottom of the
    /// screen, and has stopped moving.
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

    /// Attaches a screenshot kept on success too, so each presentation can be eyeballed per device.
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
