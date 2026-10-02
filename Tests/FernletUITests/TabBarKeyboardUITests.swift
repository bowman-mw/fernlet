import XCTest

/// The floating tab bar stays pinned to the physical bottom, behind the keyboard, while a field
/// inside a tab is being typed into — and the pages above it still avoid the keyboard.
///
/// Three surfaces, because the bar's host and the focused field's host differ: a tab root with no
/// stack of its own (Private → Worry box), a page pushed one level inside the Food tab's stack (the
/// Recipe book's search), and the editor pushed three levels down (Recipe book → Create → Manual
/// entry), whose save bar is lifted over the tab bar by `fernletTabBarSafeAreaClearance()`. A
/// fourth test covers the meal-logged toast, which the bar's inset used to carry.
///
/// Measured on main before the fix (iPhone 17, iOS 26.5): on all three surfaces the Home tab went
/// from y 759.7 to 458.7, the bar resting on the keyboard's top (y 539), and the editor's Save sat
/// 128.7pt above the keyboard instead of 36 — `ContentView` kept the bar's keyboard ignore inside the
/// inset's closure, where an inset's content has no bottom safe area to ignore.
///
/// The bar is read off `app.buttons["Home"]`: `app.tabBars` finds nothing on this custom bar.
final class TabBarKeyboardUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - The bar stays behind the keyboard

    /// A tab root: the Worry box page has no NavigationStack and an inline composer.
    @MainActor
    func testTabBarStaysBehindTheKeyboardOnATabRoot() {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        tabItem("Private", in: app).tap()
        let section = app.buttons["Worry box"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 8), "the Private hub has no Worry box section")
        section.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.worryBox"].waitForExistence(timeout: 6),
                      "the Worry box page did not open")
        let composer = field(placeholder: "Something circling around?", in: app)
        assertBarStaysBehindKeyboard(focusing: composer, surface: "Worry box (tab root)", in: app)
    }

    /// One push: the Recipe book's search field, pushed inside the Food tab's stack.
    @MainActor
    func testTabBarStaysBehindTheKeyboardOnAPushedPage() {
        let app = UXTestApp.launch()
        openRecipeBookFromFood(in: app)
        let search = field(placeholder: "Search recipes and products", in: app)
        assertBarStaysBehindKeyboard(focusing: search, surface: "Recipe book search (pushed)", in: app)
    }

    /// Three pushes, with a pinned save bar: the bar stays behind the keyboard, and the save bar —
    /// lifted over the tab bar while the keyboard is down — rests right on the keyboard, with no
    /// tab-bar reservation left stacked between them.
    @MainActor
    func testPushedEditorSaveBarSitsOnTheKeyboardWithTheTabBarBehindIt() {
        let app = UXTestApp.launch()
        openRecipeBookFromFood(in: app)
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 6), "the book has no Create button")
        create.tap()
        let manual = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Manual entry")).firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 6), "the chooser has no Manual entry option")
        manual.tap()
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 6), "the manual editor did not open")

        let name = field(placeholder: "black bean bowls", in: app)
        let keyboardTop = assertBarStaysBehindKeyboard(focusing: name, surface: "Manual editor (pushed)", in: app)

        let save = app.buttons["Save recipe"]
        XCTAssertTrue(save.exists, "the editor has no Save recipe button")
        // A bar resting on the keyboard puts Save's label 36pt above the keyboard's top. The tab-bar
        // reservation stacked on the keyboard added the bar's whole height to that: 128.7pt on main.
        // The editor's keyboard "Done" accessory floats over the page's bottom, and the page avoids
        // part of it (iPhone 17, iOS 26.5: its bottom moved 14pt up, Save's gap 36 → 50), so the
        // allowance grows by that band's height; the stacked reservation would still add ~92pt.
        let gap = keyboardTop - save.frame.maxY
        XCTAssertGreaterThanOrEqual(gap, 0, "Save recipe (\(save.frame)) is under the keyboard (top \(keyboardTop))")
        XCTAssertLessThanOrEqual(
            gap, Self.saveLabelInset + keyboardAccessoryHeight(above: keyboardTop, in: app) + 4,
            "Save recipe (\(save.frame)) floats \(gap)pt above the keyboard (top \(keyboardTop)): the tab-bar reservation is still stacked on it"
        )
        XCTAssertTrue(save.isHittable, "Save recipe is not hittable with the keyboard up")
    }

    /// The meal-logged toast used to ride the bar's inset; with the bar behind the keyboard it rests
    /// on the keyboard instead of hiding behind it. Logged from the Recipe book's search results
    /// with the search field still focused, then undone, so no meal outlives the test.
    @MainActor
    func testMealLoggedToastRestsOnTheKeyboard() {
        let app = UXTestApp.launch()
        openRecipeBookFromFood(in: app)
        let search = field(placeholder: "Search recipes and products", in: app)
        let keyboardTop = assertBarStaysBehindKeyboard(focusing: search, surface: "Recipe book search, logging", in: app)
        search.typeText("oats")
        let log = app.buttons["Log recipe as meal"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 6), "the search found no recipe to log")
        // The search field's keyboard "Done" accessory is a full-width band over the page's bottom
        // that takes every touch in it, and the row's Log pill reaches into it (iPhone 17: pill
        // y 478–522, band 491–539, page edge 525): a tap at the pill's centre landed on the band.
        let bandTop = keyboardTop - keyboardAccessoryHeight(above: keyboardTop, in: app)
        tap(log, above: bandTop)
        let snack = app.buttons["Snack"].firstMatch
        XCTAssertTrue(snack.waitForExistence(timeout: 4), "Log did not offer the meal slots")
        // The slots open under the row, wholly behind the band (y 530–574): scroll them up first.
        if snack.frame.maxY > bandTop - 8 {
            dragContent(up: snack.frame.maxY - bandTop + 24, from: bandTop - 12, in: app)
        }
        tap(snack, above: bandTop)

        let undo = app.buttons["mealToast.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "no meal-logged toast appeared")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard went away, so this proves nothing about it")
        // The toast stays up for five seconds: measure, Undo, and only then assert, so a failed
        // check does not skip the Undo and leave the meal on the next suite's Food page.
        let toast = settledFrame(of: undo)
        let isHittable = undo.isHittable
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Meal-logged toast – keyboard up (Undo \(toast), keyboard top \(keyboardTop))"
        shot.lifetime = .keepAlways
        add(shot)
        // A covered Undo would take the tap on a key: put the keyboard away first, so even a red
        // run takes its meal back (a leftover "Overnight oats" meal row shadows the recipe row the
        // RecipeDetail and TabReselect suites tap).
        if !isHittable { search.typeText("\n") }
        undo.tap()
        XCTAssertLessThanOrEqual(toast.maxY, keyboardTop, "the toast's Undo (\(toast)) is behind the keyboard (top \(keyboardTop))")
        XCTAssertTrue(isHittable, "the toast's Undo is not hittable with the keyboard up")
        XCTAssertTrue(waitForGone(undo), "the toast stayed up after Undo")
    }

    // MARK: - Assertion

    /// How far "Save recipe"'s frame — its label only — sits above the bottom of the new-recipe
    /// editor's bar: the button's 16pt vertical padding plus the bar's own 20pt (`RecipeSheet`).
    private static let saveLabelInset: CGFloat = 36

    /// Focuses `field`, waits for the keyboard to settle, and asserts the tab bar did not move: it
    /// still rests where it did with the keyboard down, at or below the keyboard's top, and cannot be
    /// hit. Returns the keyboard's top as drawn (its predictions bar included).
    @MainActor
    @discardableResult
    private func assertBarStaysBehindKeyboard(
        focusing field: XCUIElement,
        surface: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> CGFloat {
        XCTAssertTrue(field.waitForExistence(timeout: 6), "\(surface): no field to focus", file: file, line: line)
        let home = app.buttons["Home"].firstMatch
        XCTAssertTrue(home.exists, "\(surface): the tab bar is not in the tree", file: file, line: line)
        let resting = settledFrame(of: home)

        field.tap()
        if !field.waitForKeyboardFocus(timeout: 2) { field.tap() }
        XCTAssertTrue(field.waitForKeyboardFocus(timeout: 4), "\(surface): the field never took focus", file: file, line: line)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6), "\(surface): no keyboard came up", file: file, line: line)
        _ = settledFrame(of: keyboard)
        let raised = settledFrame(of: home)
        let keyboardTop = self.keyboardTop(in: app)
        attachFrames(surface: surface, resting: resting, raised: raised, keyboardTop: keyboardTop, in: app)

        XCTAssertEqual(
            raised.minY, resting.minY, accuracy: 1,
            "\(surface): the tab bar moved with the keyboard (Home tab \(resting) → \(raised), keyboard top \(keyboardTop))",
            file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            raised.minY, keyboardTop,
            "\(surface): the tab bar (Home tab \(raised)) shows above the keyboard (top \(keyboardTop))",
            file: file, line: line
        )
        XCTAssertFalse(home.isHittable, "\(surface): the Home tab is still hittable over the keyboard", file: file, line: line)
        return keyboardTop
    }

    // MARK: - Geometry

    /// The top of the keyboard as drawn. `app.keyboards` frames only the keys: the "Typing
    /// Predictions" bar sits on top of them (iPhone 17, iOS 26.5: keys from y 583, predictions
    /// y 539–583), and that bar's top is the edge the pages avoid.
    private func keyboardTop(in app: XCUIApplication) -> CGFloat {
        let keys = app.keyboards.firstMatch.frame
        let predictions = app.otherElements.matching(NSPredicate(format: "label == %@", "Typing Predictions")).firstMatch
        guard predictions.exists else { return keys.minY }
        let bar = predictions.frame
        return abs(bar.maxY - keys.minY) < 2 ? min(bar.minY, keys.minY) : keys.minY
    }

    /// The height of the keyboard accessory toolbar (the "Done" bar) resting on the keyboard's
    /// drawn top, or 0 when the focused field's page declares none.
    private func keyboardAccessoryHeight(above keyboardTop: CGFloat, in app: XCUIApplication) -> CGFloat {
        let bars = app.toolbars.matching(identifier: "Toolbar")
        // Bounded: one accessory bar, plus any toolbar a page draws itself.
        for index in 0..<min(bars.count, 4) {
            let bar = bars.element(boundBy: index).frame
            if abs(bar.maxY - keyboardTop) < 2 { return bar.height }
        }
        return 0
    }

    /// Taps `element` midway between its top and `bandTop` when its centre lies at or below that
    /// line (a band that takes touches covers its lower part), else at its centre.
    private func tap(_ element: XCUIElement, above bandTop: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let frame = element.frame
        guard frame.midY >= bandTop else { return element.tap() }
        XCTAssertGreaterThan(bandTop - frame.minY, 8, "\(element) (\(frame)) is wholly behind the band from y \(bandTop)",
                             file: file, line: line)
        let dy = ((frame.minY + bandTop) / 2 - frame.minY) / max(frame.height, 1)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
    }

    /// Drags the page's content up by about `distance` points from a press at height `y`, above the
    /// keyboard, with a slow press-drag-hold that ends where it is told to.
    private func dragContent(up distance: CGFloat, from y: CGFloat, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y / window.height))
        let end = start.withOffset(CGVector(dx: 0, dy: -distance))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    /// Waits for `element` to leave the tree; true once it has.
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// The element's frame once two reads a beat apart agree — the keyboard and anything riding it
    /// animate for about a third of a second.
    private func settledFrame(of element: XCUIElement) -> CGRect {
        var previous = element.frame
        // Bounded: about three seconds of 0.15s beats.
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.15)
            let current = element.frame
            if current == previous { return current }
            previous = current
        }
        return previous
    }

    /// Records the measured frames on the test, kept on success too, beside a screenshot.
    private func attachFrames(
        surface: String,
        resting: CGRect,
        raised: CGRect,
        keyboardTop: CGFloat,
        in app: XCUIApplication
    ) {
        let save = app.buttons["Save recipe"]
        let lines = [
            "surface: \(surface)",
            "Home tab, keyboard down: \(resting)",
            "Home tab, keyboard up: \(raised)",
            "keyboard keys: \(app.keyboards.firstMatch.frame)",
            "keyboard top (predictions bar included): \(keyboardTop)",
            "Save recipe: \(save.exists ? String(describing: save.frame) : "absent")",
            "window: \(app.windows.firstMatch.frame)",
        ]
        let text = XCTAttachment(string: lines.joined(separator: "\n"))
        text.name = "\(surface) – frames"
        text.lifetime = .keepAlways
        add(text)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(surface) – keyboard up"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Navigation

    /// A text field (or a vertical-axis one, which is a text view) found by its placeholder.
    private func field(placeholder: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
                                  XCUIElement.ElementType.textField.rawValue,
                                  XCUIElement.ElementType.textView.rawValue,
                                  placeholder))
            .firstMatch
    }

    /// Opens Food, then the Recipe book pushed inside the Food tab, and waits for it.
    @MainActor
    private func openRecipeBookFromFood(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let page = app.descendants(matching: .any)["screen.food"].firstMatch
        // One retry: a tab tap in the first seconds after launch is still occasionally lost.
        for _ in 0..<2 where !page.exists {
            tabItem("Food", in: app).tap()
            _ = page.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(page.exists, "the Food tab never showed screen.food", file: file, line: line)
        let recipeBook = app.buttons["Recipe book"]
        XCTAssertTrue(recipeBook.waitForExistence(timeout: 6), "Recipe book button not found on Food", file: file, line: line)
        XCTAssertTrue(scrollClearOfTabBar(recipeBook, in: app), "Recipe book button not reachable on Food", file: file, line: line)
        recipeBook.tap()
        XCTAssertTrue(app.navigationBars["Recipe book"].waitForExistence(timeout: 6), "the recipe book did not open",
                      file: file, line: line)
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
            let homeTab = app.buttons["Home"].firstMatch
            let bottom = (homeTab.exists ? homeTab.frame.minY : window.frame.maxY) - tabBarClear
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
}
