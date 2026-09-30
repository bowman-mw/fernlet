import XCTest

/// Re-tapping the tab you are already on (owner request, 2026-09-29): with a page pushed inside the
/// tab it unwinds the tab's whole stack to its main page — "inside the recipe book, tapping the Food
/// icon brings you to the main Food page" — and at the main page it scrolls back to the top.
///
/// Each test pushes one or more pages, taps the active tab's own button in the floating bar, and
/// asserts that every pushed page's navigation bar is gone and the tab's main page is back.
/// ``testFoodTabPopsCreateFlowAndBookReopensAtItsRoot()`` also proves the pages pushed from INSIDE a
/// pushed page (the book's create chooser and editor, driven by the book's own state) came off with
/// it rather than waiting to reappear; ``testFoodTabAsksBeforeDiscardingATypedRecipe()`` proves the
/// same pop asks first when the editor holds a typed recipe.
final class TabReselectUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Food

    @MainActor
    func testFoodTabPopsRecipeBookToFoodRoot() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        openRecipeBook(in: app)

        tabItem("Food", in: app).tap()

        XCTAssertTrue(waitForGone(app.navigationBars["Recipe book"]), "re-tapping Food left the recipe book pushed")
        XCTAssertTrue(app.descendants(matching: .any)["screen.food"].waitForExistence(timeout: 6),
                      "re-tapping Food did not bring the Food page back")
    }

    /// Two levels: the book, and a recipe's detail pushed from one of its rows.
    @MainActor
    func testFoodTabPopsRecipeDetailInsideBook() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        openRecipeBook(in: app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found in the book")
        row.tap()
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 6), "recipe detail did not open")

        tabItem("Food", in: app).tap()

        XCTAssertTrue(waitForGone(app.navigationBars["Recipe"]), "re-tapping Food left the recipe detail pushed")
        XCTAssertTrue(waitForGone(app.navigationBars["Recipe book"]), "re-tapping Food stopped at the recipe book")
        XCTAssertTrue(app.descendants(matching: .any)["screen.food"].waitForExistence(timeout: 6),
                      "re-tapping Food did not bring the Food page back")
    }

    /// Three levels, the upper two driven by the book's own state (`isCreatingRecipe`, the chooser's
    /// `step`) rather than the Food path — then the book is opened again and must be at ITS root.
    @MainActor
    func testFoodTabPopsCreateFlowAndBookReopensAtItsRoot() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        openManualRecipeEditor(in: app)

        // Nothing typed, so nothing to lose: the pop goes straight through, no discard alert.
        tabItem("Food", in: app).tap()

        XCTAssertFalse(app.alerts["Discard your changes?"].exists, "a clean editor raised the discard alert")
        XCTAssertTrue(waitForGone(app.navigationBars["New recipe"]), "re-tapping Food left the editor pushed")
        XCTAssertTrue(waitForGone(app.navigationBars["Create recipe"]), "re-tapping Food left the chooser pushed")
        XCTAssertTrue(waitForGone(app.navigationBars["Recipe book"]), "re-tapping Food stopped at the recipe book")
        XCTAssertTrue(app.descendants(matching: .any)["screen.food"].waitForExistence(timeout: 6),
                      "re-tapping Food did not bring the Food page back")

        openRecipeBook(in: app)
        XCTAssertFalse(app.navigationBars["Create recipe"].exists, "the book reopened with the chooser still pushed")
        XCTAssertFalse(app.navigationBars["New recipe"].exists, "the book reopened with the editor still pushed")
    }

    /// A pushed editor holding typed input is not popped straight away: the re-tap raises the shared
    /// discard alert. "Keep editing" leaves the draft where it was; "Discard" pops the whole stack.
    /// (A CLEAN editor pops without asking — ``testFoodTabPopsCreateFlowAndBookReopensAtItsRoot()``.)
    @MainActor
    func testFoodTabAsksBeforeDiscardingATypedRecipe() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        openManualRecipeEditor(in: app)
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "black bean bowls")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 6), "the manual editor has no recipe name field")
        name.tapAndType("Tab test soup\n")
        XCTAssertTrue(waitForGone(app.keyboards.firstMatch), "the keyboard did not go away after Return")

        tabItem("Food", in: app).tap()

        let alert = app.alerts["Discard your changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 6), "re-tapping Food over a typed recipe did not ask first")
        XCTAssertTrue(app.navigationBars["New recipe"].exists, "the editor popped before the user answered")
        alert.buttons["Keep editing"].tap()
        XCTAssertTrue(waitForGone(alert), "Keep editing did not close the alert")
        XCTAssertTrue(app.navigationBars["New recipe"].exists, "Keep editing did not keep the editor")
        XCTAssertEqual(name.value as? String, "Tab test soup", "Keep editing lost the typed name")

        tabItem("Food", in: app).tap()

        XCTAssertTrue(alert.waitForExistence(timeout: 6), "the second re-tap did not ask again")
        alert.buttons["Discard"].tap()
        XCTAssertTrue(waitForGone(app.navigationBars["New recipe"]), "Discard left the editor pushed")
        XCTAssertTrue(waitForGone(app.navigationBars["Recipe book"]), "Discard stopped at the recipe book")
        XCTAssertTrue(app.descendants(matching: .any)["screen.food"].waitForExistence(timeout: 6),
                      "Discard did not bring the Food page back")
    }

    /// The Food page's own Recipes card pushes the same detail from the root, as a path value too.
    @MainActor
    func testFoodTabPopsRecentRecipeDetail() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Overnight oats")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 6), "seeded recipe row not found on the Food page")
        XCTAssertTrue(scrollClearOfTabBar(row, in: app), "seeded recipe row not reachable on Food")
        row.tap()
        XCTAssertTrue(app.navigationBars["Recipe"].waitForExistence(timeout: 6), "recipe detail did not open")

        tabItem("Food", in: app).tap()

        XCTAssertTrue(waitForGone(app.navigationBars["Recipe"]), "re-tapping Food left the recipe detail pushed")
        XCTAssertTrue(app.descendants(matching: .any)["screen.food"].waitForExistence(timeout: 6),
                      "re-tapping Food did not bring the Food page back")
    }

    /// At the main page a re-tap is still the scroll-to-top it always was.
    @MainActor
    func testSecondTapAtFoodRootScrollsBackToTop() {
        let app = UXTestApp.launch()
        openTab("Food", page: "screen.food", in: app)
        let header = app.descendants(matching: .any)["screen.food"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 6), "the Food page never came up")
        // Two long drags carry the header well above the top edge.
        dragFeed(by: 600, in: app)
        dragFeed(by: 600, in: app)
        XCTAssertFalse(header.isHittable, "the Food page did not scroll far enough to hide its header")

        tabItem("Food", in: app).tap()

        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: header)
        XCTAssertEqual(XCTWaiter().wait(for: [visible], timeout: 6), .completed,
                       "re-tapping Food at its main page did not scroll back to the top")
    }

    // MARK: - Friends

    @MainActor
    func testFriendsTabPopsFriendsAndBlocks() {
        let app = UXTestApp.launch()
        openTab("Friends", page: "screen.friends", in: app)
        let manage = app.buttons["friends.manageFriends"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 10), "the Friends header has no Friends & Blocks link")
        manage.tap()
        XCTAssertTrue(app.navigationBars["Friends & Blocks"].waitForExistence(timeout: 6), "Friends & Blocks did not open")

        // The pushed page has its own "Friends" filter segment; `tabItem` finds the bar's button.
        tabItem("Friends", in: app).tap()

        XCTAssertTrue(waitForGone(app.navigationBars["Friends & Blocks"]), "re-tapping Friends left Friends & Blocks pushed")
        XCTAssertTrue(app.descendants(matching: .any)["screen.friends"].waitForExistence(timeout: 6),
                      "re-tapping Friends did not bring the album back")
    }

    // MARK: - Move

    @MainActor
    func testMoveTabPopsExerciseHistory() {
        let app = UXTestApp.launch()
        openTab("Move", page: "screen.move", in: app)
        let history = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Exercise history")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 6), "Move has no Exercise history link")
        XCTAssertTrue(scrollClearOfTabBar(history, in: app), "Exercise history link not reachable on Move")
        history.tap()
        let historyScreen = app.descendants(matching: .any)["screen.exerciseHistory"].firstMatch
        XCTAssertTrue(historyScreen.waitForExistence(timeout: 6), "Exercise history did not open")

        tabItem("Move", in: app).tap()

        XCTAssertTrue(waitForGone(historyScreen), "re-tapping Move left Exercise history pushed")
        XCTAssertTrue(app.descendants(matching: .any)["screen.move"].waitForExistence(timeout: 6),
                      "re-tapping Move did not bring the Move page back")
    }

    // MARK: - Private

    /// The Private tab hands its token through the hub to the section on screen; here the Journal,
    /// whose calendar pushes the day detail.
    @MainActor
    func testPrivateTabPopsJournalDayDetail() {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        openTab("Private", page: "screen.journal", in: app)
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Today, day")).firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 6), "the Journal calendar has no cell for today")
        XCTAssertTrue(scrollClearOfTabBar(today, in: app), "today's calendar cell not reachable on the Journal")
        today.tap()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 6), "today's day detail did not open")

        tabItem("Private", in: app).tap()

        XCTAssertTrue(waitForGone(app.navigationBars["Today"]), "re-tapping Private left the day detail pushed")
        XCTAssertTrue(app.descendants(matching: .any)["screen.journal"].waitForExistence(timeout: 6),
                      "re-tapping Private did not bring the Journal back")
    }

    /// The Cycle section pops differently from the others — its day detail is an item destination
    /// (`navigationDestination(item:)`), cleared by setting the selected day to nil, not a path.
    @MainActor
    func testPrivateTabPopsCycleDayDetail() {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        openTab("Private", page: "screen.journal", in: app)
        let cycle = app.buttons["Cycle"].firstMatch
        XCTAssertTrue(cycle.waitForExistence(timeout: 6), "the Private hub has no Cycle section")
        cycle.tap()
        let cyclePage = app.descendants(matching: .any)["screen.cycle"].firstMatch
        XCTAssertTrue(cyclePage.waitForExistence(timeout: 8), "the Cycle section never came up")
        let today = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Today, day")).firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 6), "the Cycle calendar has no cell for today")
        XCTAssertTrue(scrollClearOfTabBar(today, in: app), "today's calendar cell not reachable on Cycle")
        today.tap()
        let dayDetail = app.staticTexts["Health samples"].firstMatch
        XCTAssertTrue(dayDetail.waitForExistence(timeout: 6), "today's cycle day detail did not open")

        tabItem("Private", in: app).tap()

        XCTAssertTrue(waitForGone(dayDetail), "re-tapping Private left the cycle day detail pushed")
        XCTAssertTrue(cyclePage.waitForExistence(timeout: 6), "re-tapping Private did not bring the Cycle page back")
    }

    // MARK: - Helpers

    /// Switches to tab `title` and waits for its main page, `identifier`. One retry: a tab tap in the
    /// first seconds after launch is still occasionally lost (the page never changes), and a second
    /// tap on a tab that did switch is only the harmless scroll-to-top. The re-taps under test are
    /// single taps on ``tabItem(_:in:)``, never this.
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

    /// Scrolls the Food page's "Recipe book" link clear of the tab bar, opens it, and waits for it.
    @MainActor
    private func openRecipeBook(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food", file: file, line: line)
        XCTAssertTrue(scrollClearOfTabBar(recipeBook, in: app), "Recipe book button not reachable on Food", file: file, line: line)
        recipeBook.tap()
        XCTAssertTrue(app.navigationBars["Recipe book"].waitForExistence(timeout: 6), "the recipe book did not open",
                      file: file, line: line)
    }

    /// Opens Food → Recipe book → Create → Manual entry and waits for the empty editor.
    @MainActor
    private func openManualRecipeEditor(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        openRecipeBook(in: app, file: file, line: line)
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 6), "the book has no Create button", file: file, line: line)
        create.tap()
        XCTAssertTrue(app.navigationBars["Create recipe"].waitForExistence(timeout: 6), "the create chooser did not open",
                      file: file, line: line)
        let manual = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Manual entry")).firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 6), "the chooser has no Manual entry option", file: file, line: line)
        manual.tap()
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 6), "the manual editor did not open",
                      file: file, line: line)
    }

    /// The floating tab bar's button for `title`.
    ///
    /// The bar is a custom SwiftUI view (`app.tabBars` finds nothing) and its buttons carry no
    /// identifier, while the same label can sit elsewhere: a Home card below the fold, or Friends &
    /// Blocks' "Friends" filter segment. Neither "first" nor "lowest" is safe — a card scrolled below
    /// the screen is lower than the bar — so find the bar's ROW instead: the one line on which the
    /// Home and Private tab buttons also sit, and take the `title` button on it.
    private func tabItem(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", title))
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 30), "the tab bar has no \(title) button")
        let homeRows = buttonMidYs(labelled: "Home", in: app)
        let privateRows = buttonMidYs(labelled: "Private", in: app)
        // Bounded: a handful of same-label buttons at most.
        for index in 0..<min(matches.count, 8) {
            let candidate = matches.element(boundBy: index)
            let midY = candidate.frame.midY
            let onHomeRow = homeRows.contains { abs($0 - midY) < 2 }
            let onPrivateRow = privateRows.contains { abs($0 - midY) < 2 }
            if onHomeRow && onPrivateRow { return candidate }
        }
        XCTFail("no \(title) button sits on the tab bar's row")
        return matches.firstMatch
    }

    /// The vertical centres of every button labelled `label` (at most eight).
    private func buttonMidYs(labelled label: String, in app: XCUIApplication) -> [CGFloat] {
        let matches = app.buttons.matching(NSPredicate(format: "label == %@", label))
        return (0..<min(matches.count, 8)).map { matches.element(boundBy: $0).frame.midY }
    }

    /// Waits for `element` to leave the tree; true once it has.
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Drags the page until the element sits wholly between the status bar and the floating tab bar.
    /// A copy of `RecipeDetailUITests.scrollClearOfTabBar` (each suite keeps its own): a tap whose
    /// point lands inside the bar's pill, even outside a tab button's frame, selects that tab.
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
