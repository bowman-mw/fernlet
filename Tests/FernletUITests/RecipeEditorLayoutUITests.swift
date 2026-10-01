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
/// rested under the floating tab bar — "Save recipe" at y 785.7–804 inside a tab row spanning
/// y 759.7–820.4, `isHittable` false — so a tap on Save selected the Food tab, and over a typed
/// recipe that re-tap raised "Discard your changes?". The tests assert every bottom-bar button sits
/// wholly above the tab bar (with the keyboard down and up), is hittable, and that a tap on Save
/// stays on the editor — and that the same editor pushed inside the Recipe book SHEET, which covers
/// the tab bar, is not lifted at all.
///
/// The same two failures reproduced unchanged on iPhone SE (3rd generation), iPhone 17e and iPhone 17
/// Pro Max: both are structural, not a matter of screen size.
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

    // MARK: - Pushed: the bottom bar sits above the floating tab bar

    @MainActor
    func testPushedManualEditorSaveBarSitsAboveTheTabBar() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        openRecipeBookFromFood(in: app)
        openManualEditorFromBook(in: app)
        attachScreenshot(of: app, named: "Pushed manual editor")

        assertClearOfTabBar(app.buttons["Save recipe"], named: "Save recipe", in: app)
        assertClearOfTabBar(app.buttons["Log & save"], named: "Log & save", in: app)

        // While the name is typed: the tab bar stays behind the keyboard (TabBarKeyboardUITests
        // pins that, and that Save then rests on the keyboard), and Save must still sit clear of it.
        let name = nameField(in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 6), "the manual editor has no recipe name field")
        name.tapAndType("Layout soup")
        attachScreenshot(of: app, named: "Pushed manual editor, keyboard up")
        assertClearOfTabBar(app.buttons["Save recipe"], named: "Save recipe (keyboard up)", in: app)
        name.typeText("\n")
        XCTAssertTrue(waitForGone(app.keyboards.firstMatch), "the keyboard did not go away after Return")

        // The typed name makes the draft dirty, so a tap that reached the Food tab would raise the
        // discard prompt. Save is still disabled (no ingredient yet): landing on it does nothing.
        app.buttons["Save recipe"].tap()
        XCTAssertFalse(app.alerts["Discard your changes?"].waitForExistence(timeout: 2),
                       "a tap on Save recipe reached the Food tab and raised the discard prompt")
        XCTAssertTrue(app.navigationBars["New recipe"].exists, "a tap on Save recipe left the editor")
    }

    /// The manual editor's sibling on the same chooser carries the same bottom bar.
    @MainActor
    func testPushedImportScreenBarSitsAboveTheTabBar() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        openRecipeBookFromFood(in: app)
        tapCreate(in: app)
        let importRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Import recipe")).firstMatch
        XCTAssertTrue(importRow.waitForExistence(timeout: 6), "the chooser has no Import recipe option")
        importRow.tap()
        let importButton = app.buttons["Import"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 6), "the import screen did not open")
        attachScreenshot(of: app, named: "Pushed import screen")

        assertClearOfTabBar(importButton, named: "Import", in: app)
    }

    /// The same create flow inside the root Recipe book SHEET, which covers the tab bar: nothing may
    /// lift the save bar there. It rests on the sheet's bottom edge, lower than the top of the tab
    /// bar hidden under the sheet — a leaked reservation would float it ~94pt up over empty space.
    @MainActor
    func testManualEditorInsideTheRecipeBookSheetIsNotLifted() {
        let app = UXTestApp.launch(openSheet: "recipeBook")
        let sheet = app.descendants(matching: .any)["sheet.recipeBook"]
        XCTAssertTrue(sheet.exists || sheet.waitForExistence(timeout: 10), "sheet.recipeBook never appeared")
        openManualEditorFromBook(in: app)
        attachScreenshot(of: app, named: "Manual editor in the recipe book sheet")

        let save = app.buttons["Save recipe"]
        XCTAssertTrue(save.exists || save.waitForExistence(timeout: 6), "no Save recipe button")
        let homeTab = app.buttons["Home"].firstMatch
        XCTAssertTrue(homeTab.exists, "the tab bar is not in the tree under the sheet")
        XCTAssertGreaterThan(
            save.frame.maxY, homeTab.frame.minY,
            "Save recipe (\(save.frame)) is lifted above a tab bar the sheet covers (bar top \(homeTab.frame.minY))"
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

    /// `button` exists, its whole frame sits above the floating tab bar's pill, and it is hittable.
    @MainActor
    private func assertClearOfTabBar(
        _ button: XCUIElement,
        named label: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(button.exists || button.waitForExistence(timeout: 6), "no \(label) button",
                      file: file, line: line)
        let pillTop = tabBarTop(in: app) - Self.tabPillPadding
        XCTAssertLessThanOrEqual(
            button.frame.maxY, pillTop,
            "\(label) (\(button.frame)) reaches under the floating tab bar (pill top \(pillTop))",
            file: file, line: line
        )
        XCTAssertTrue(button.isHittable, "\(label) is not hittable", file: file, line: line)
    }

    // MARK: - Navigation

    /// The pill's padding around the tab buttons when expanded — the bar's drawn top sits this far
    /// above the Home tab's frame (see `ContentView`'s custom tab bar).
    private static let tabPillPadding: CGFloat = 6

    /// Switches to tab `title` and waits for its main page, `identifier`. One retry: a tab tap in the
    /// first seconds after launch is still occasionally lost (the page never changes).
    @MainActor
    private func openTab(
        _ title: String,
        page identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let page = app.descendants(matching: .any)[identifier].firstMatch
        for _ in 0..<2 {
            tabItem(title, in: app).tap()
            if page.waitForExistence(timeout: 8) { return }
        }
        XCTFail("the \(title) tab never showed \(identifier)", file: file, line: line)
    }

    /// Opens Food → Recipe book (pushed inside the Food tab) and waits for it.
    @MainActor
    private func openRecipeBookFromFood(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food", file: file, line: line)
        XCTAssertTrue(scrollClearOfTabBar(recipeBook, in: app), "Recipe book button not reachable on Food", file: file, line: line)
        recipeBook.tap()
        XCTAssertTrue(app.navigationBars["Recipe book"].waitForExistence(timeout: 6), "the recipe book did not open",
                      file: file, line: line)
    }

    /// Taps the open recipe book's Create and waits for the chooser.
    @MainActor
    private func tapCreate(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 6), "the book has no Create button", file: file, line: line)
        create.tap()
        XCTAssertTrue(app.navigationBars["Create recipe"].waitForExistence(timeout: 6), "the create chooser did not open",
                      file: file, line: line)
    }

    /// From the open recipe book: Create → Manual entry, and waits for the empty editor.
    @MainActor
    private func openManualEditorFromBook(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        tapCreate(in: app, file: file, line: line)
        let manual = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Manual entry")).firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 6), "the chooser has no Manual entry option", file: file, line: line)
        manual.tap()
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 6), "the manual editor did not open",
                      file: file, line: line)
    }

    /// The editor's recipe name field, found by its placeholder.
    private func nameField(in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "black bean bowls")).firstMatch
    }

    /// The floating tab bar's button for `title`: the one on the row where the Home and Private tab
    /// buttons also sit (a copy of `TabReselectUITests.tabItem`; each suite keeps its own).
    private func tabItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 30), "the tab bar has no \(title) button")
        let homeRows = buttonMidYs(labelled: "Home", in: app)
        let privateRows = buttonMidYs(labelled: "Private", in: app)
        // Bounded: a handful of same-label buttons at most.
        for index in 0..<min(matches.count, 8) {
            let candidate = matches.element(boundBy: index)
            let midY = candidate.frame.midY
            if homeRows.contains(where: { abs($0 - midY) < 2 }) && privateRows.contains(where: { abs($0 - midY) < 2 }) {
                return candidate
            }
        }
        XCTFail("no \(title) button sits on the tab bar's row")
        return matches.firstMatch
    }

    /// The vertical centres of every button labelled `label` (at most eight).
    private func buttonMidYs(labelled label: String, in app: XCUIApplication) -> [CGFloat] {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        return (0..<min(matches.count, 8)).map { matches.element(boundBy: $0).frame.midY }
    }

    /// The top of the floating tab bar's buttons, read off its Home tab.
    private func tabBarTop(in app: XCUIApplication) -> CGFloat {
        let homeTab = app.buttons["Home"].firstMatch
        return homeTab.exists ? homeTab.frame.minY : app.windows.firstMatch.frame.maxY
    }

    /// Waits for `element` to leave the tree; true once it has.
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Drags the page until the element sits wholly between the status bar and the floating tab bar
    /// (a copy of `TabReselectUITests.scrollClearOfTabBar`): a tap whose point lands inside the bar's
    /// pill, even outside a tab button's frame, selects that tab.
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
