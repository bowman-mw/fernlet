import XCTest

/// Every text field reached inside a `NavigationStack` gets exactly one keyboard "Done" accessory
/// (2026-10-01, iPhone 17 simulator, iOS 26.5).
///
/// `keyboardDoneToolbar()` (a `ToolbarItemGroup(placement: .keyboard)`) only reaches fields hosted
/// in the same UIKit hosting controller as the view it is attached to. Each page of a
/// `NavigationStack` — its root page too — is hosted in its own controller, so the one declared
/// OUTSIDE the Food tab's stack, and the one `fernletSheetChrome` declares around a sheet that
/// wraps its own stack, reached no page at all: with the keyboard up on Food → Recipe book, the
/// pushed manual editor, the recipe sheet or the recipe book sheet, the tree had no accessory
/// toolbar, and a number pad (the editor's "Qty") had no way to put itself away. A stack-less sheet
/// (Sleep) did get one — but its button was labelled "selected" (the checkmark symbol's own
/// label), so VoiceOver and these queries never heard "Done".
///
/// Each test focuses a field, waits for the keyboard, asserts exactly one button labelled "Done"
/// in the accessory band just above the keys (two declarations in one page stack two buttons),
/// then taps it and asserts the keyboard went away. The tap, not `isEnabled`, is the proof that
/// it works: XCUITest reports the bar's native item as disabled even though it responds.
final class KeyboardDoneAccessoryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Food tab stack

    @MainActor
    func testPushedRecipeBookSearchFieldHasOneKeyboardDone() {
        let app = UXTestApp.launch()
        openRecipeBookFromFood(in: app)
        assertOneKeyboardDone(dismissing: searchField(in: app), named: "pushed recipe book search", in: app)
    }

    @MainActor
    func testPushedManualEditorNameFieldHasOneKeyboardDone() {
        let app = UXTestApp.launch()
        openRecipeBookFromFood(in: app)
        openManualEditorFromBook(in: app)
        assertOneKeyboardDone(dismissing: nameField(in: app), named: "pushed editor name", in: app)
    }

    /// The decimal pad has no return key: the accessory is the only way to put it away.
    @MainActor
    func testPushedManualEditorQuantityPadHasOneKeyboardDone() {
        let app = UXTestApp.launch()
        openRecipeBookFromFood(in: app)
        openManualEditorFromBook(in: app)
        let add = app.buttons["Add ingredient"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 6), "the manual editor has no Add ingredient button")
        add.tap()
        assertOneKeyboardDone(dismissing: quantityField(in: app), named: "pushed editor Qty", in: app)
    }

    // MARK: - Routed sheets that wrap their own stack

    @MainActor
    func testRecipeSheetNameFieldHasOneKeyboardDone() {
        let app = UXTestApp.launch(openSheet: "recipe")
        assertOneKeyboardDone(dismissing: nameField(in: app), named: "recipe sheet name", in: app)
    }

    @MainActor
    func testRecipeBookSheetSearchFieldHasOneKeyboardDone() {
        let app = UXTestApp.launch(openSheet: "recipeBook")
        assertOneKeyboardDone(dismissing: searchField(in: app), named: "recipe book sheet search", in: app)
    }

    /// Settings → Goal & nutrition: a pushed page's number pad (the calorie target).
    @MainActor
    func testSettingsPushedCaloriePadHasOneKeyboardDone() {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "Settings did not open")
        let row = app.buttons["Goal & nutrition"]
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable, "'Goal & nutrition' row not reachable")
        row.tap()
        XCTAssertTrue(app.navigationBars["Goal & nutrition"].waitForExistence(timeout: 6), "did not push Goal & nutrition")
        let calories = app.textFields["nutritionTargets.calories"]
        for _ in 0..<10 where !(calories.exists && calories.isHittable) { app.swipeUp() }
        assertOneKeyboardDone(dismissing: calories, named: "settings calorie target", in: app)
    }

    /// First aid → Worry box: the pushed editor focuses itself, and Return only adds a line.
    @MainActor
    func testFirstAidWorryEditorHasOneKeyboardDone() {
        let app = UXTestApp.launch(openSheet: "firstAid")
        let card = app.buttons["firstAid.tool.worryBox"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "First aid has no Worry box card")
        card.tap()
        assertOneKeyboardDone(dismissing: app.textViews.firstMatch, named: "worry box editor", in: app)
    }

    // MARK: - A stack-less sheet (the chrome's own Done)

    @MainActor
    func testSleepSheetHoursPadHasOneKeyboardDone() {
        let app = UXTestApp.launch(openSheet: "sleep")
        let hours = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "7.5")).firstMatch
        assertOneKeyboardDone(dismissing: hours, named: "sleep sheet hours", in: app)
    }

    // MARK: - Hosts no routed sheet chrome reaches (their own Done, 2026-10-01)

    /// The day edit sheet's sleep hours: a decimal pad in a sheet the day detail page (and this
    /// DEBUG hook, from the Private hub's Journal page) presents bare, outside `fernletSheetChrome`.
    @MainActor
    func testDayEditSheetSleepHoursPadHasOneKeyboardDone() {
        let app = UXTestApp.launch(bypassPrivateLock: true, extraEnvironment: ["FERNLET_UI_TEST_OPEN_DAY_EDIT": "1"])
        // The sheet's pinned header reads "Edit <weekday, month day>".
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Edit ")).firstMatch
        openPrivateTab(until: header, in: app)
        let hours = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Hours (e.g. 7.5)")).firstMatch
        scrollUntilHittable(hours, in: app)
        assertOneKeyboardDone(dismissing: hours, named: "day edit sleep hours", in: app)
    }

    /// The pre-log review: a meal that matched only in part ("2 eggs" and a word that finds nothing)
    /// pauses at the review sheet, presented by the meal sheet's root page as a sheet of its own.
    /// Its matched items' Qty boxes are decimal pads.
    @MainActor
    func testMealReviewSheetQuantityPadHasOneKeyboardDone() {
        let app = UXTestApp.launch(openSheet: "meal")
        let search = app.descendants(matching: .any)["mealComposer.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), "the meal composer has no search field")
        search.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { search.tap() }
        search.typeText("2 eggs and zzqqxx")
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 4), "the meal composer has no Save button")
        save.tap()
        XCTAssertTrue(app.staticTexts["Check this meal"].waitForExistence(timeout: 20),
                      "a partly matched meal did not pause at the review sheet")
        let quantity = quantityField(in: app)
        scrollUntilHittable(quantity, in: app)
        assertOneKeyboardDone(dismissing: quantity, named: "meal review Qty", in: app)
    }

    /// Onboarding's age: a number pad on the window's root view, which no sheet chrome wraps.
    @MainActor
    func testOnboardingAgePadHasOneKeyboardDone() {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] = "1"
        app.launch()
        continueOnboarding(in: app, waitingFor: "Welcome to Fernlet")
        tapOnboardingChoice("onboarding.lock.biometrics", in: app)
        tapOnboardingChoice("onboarding.storage.local", in: app)
        continueOnboarding(in: app, waitingFor: "Choose where logs live")
        continueOnboarding(in: app, waitingFor: "Plan your goals")
        continueOnboarding(in: app, waitingFor: "Make Fernlet yours")
        XCTAssertTrue(app.staticTexts["Add personal details"].waitForExistence(timeout: 6),
                      "onboarding did not reach its personal details")
        // By label as well as id: the screen's container id can stand in for its children's.
        let age = app.textFields.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "onboarding.profile.age", "Age")
        ).firstMatch
        assertOneKeyboardDone(dismissing: age, named: "onboarding age", in: app)
    }

    /// Private → Worry box: a tab page with no stack, whose composer grows a line on Return.
    @MainActor
    func testWorryBoxComposerHasOneKeyboardDone() {
        let app = UXTestApp.launch(bypassPrivateLock: true)
        // The hub opens on its Journal page; Home has a "Worry box" chip of its own.
        openPrivateTab(until: app.descendants(matching: .any)["screen.journal"].firstMatch, in: app)
        let section = app.buttons["Worry box"].firstMatch
        XCTAssertTrue(section.waitForExistence(timeout: 8), "the Private hub has no Worry box section")
        section.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.worryBox"].waitForExistence(timeout: 6),
                      "the Worry box page did not open")
        let composer = app.descendants(matching: .any).matching(
            NSPredicate(format: "(elementType == %d OR elementType == %d) AND placeholderValue == %@",
                        XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.textView.rawValue,
                        "Something circling around?")
        ).firstMatch
        assertOneKeyboardDone(dismissing: composer, named: "worry box composer", in: app)
    }

    // MARK: - Assertion

    /// How far above the keys the accessory band reaches: the predictions bar (44pt) plus the
    /// accessory toolbar (48pt) with room to spare, and well below any sheet header's Done.
    private static let accessoryBandHeight: CGFloat = 140

    /// Focuses `field`, waits for the keyboard, asserts exactly one button labelled "Done" sits in
    /// the band just above the keys, taps it, and asserts the keyboard goes away.
    @MainActor
    private func assertOneKeyboardDone(
        dismissing field: XCUIElement,
        named name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(field.waitForExistence(timeout: 8), "\(name): field not found", file: file, line: line)
        field.tap()
        if !field.waitForKeyboardFocus(timeout: 2) { field.tap() }
        XCTAssertTrue(field.waitForKeyboardFocus(timeout: 4), "\(name): field never took focus", file: file, line: line)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 6), "\(name): no keyboard", file: file, line: line)

        let dones = waitForAccessoryDones(above: keyboard, in: app)
        attachScreenshot(of: app, named: "\(name), keyboard up")
        if dones.count != 1 {
            // The tree says what the accessory band actually held (a toolbar, its button's label).
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name), hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertEqual(
            dones.count, 1,
            "\(name): expected one keyboard Done above the keys (top \(keyboard.frame.minY)), found "
                + "\(dones.map(\.frame))",
            file: file, line: line
        )
        guard let done = dones.first else { return }
        done.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: keyboard)
        XCTAssertEqual(XCTWaiter().wait(for: [gone], timeout: 6), .completed,
                       "\(name): the keyboard stayed up after its Done was tapped", file: file, line: line)
    }

    /// The buttons labelled exactly "Done" (case-sensitive: the return key reads "done") lying
    /// wholly in the accessory band above `keyboard`. Polls briefly — the accessory lands a beat
    /// after the keys.
    @MainActor
    private func waitForAccessoryDones(above keyboard: XCUIElement, in app: XCUIApplication) -> [XCUIElement] {
        let deadline = Date().addingTimeInterval(3)
        var found: [XCUIElement] = []
        // Bounded by the deadline; each pass re-queries the live tree.
        for _ in 0..<30 {
            let top = keyboard.frame.minY
            found = app.buttons.matching(NSPredicate(format: "label == %@", "Done")).allElementsBoundByIndex
                .filter { $0.frame.maxY <= top + 1 && $0.frame.minY >= top - Self.accessoryBandHeight }
            if !found.isEmpty || Date() > deadline { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return found
    }

    // MARK: - Navigation

    /// Food tab → Recipe book (pushed inside the Food stack).
    @MainActor
    private func openRecipeBookFromFood(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let page = app.descendants(matching: .any)["screen.food"].firstMatch
        let tabs = app.buttons.matching(NSPredicate(format: "label == %@", "Food"))
        // Bounded: one or two "Food"-labelled buttons; a tap in the first seconds can be lost.
        for index in 0..<min(max(tabs.count, 1), 4) where !page.exists {
            tabs.element(boundBy: index).tap()
            _ = page.waitForExistence(timeout: 6)
        }
        XCTAssertTrue(page.exists, "the Food tab never showed", file: file, line: line)
        let book = app.buttons["Recipe book"]
        XCTAssertTrue(book.waitForExistence(timeout: 6), "Recipe book button not found on Food", file: file, line: line)
        book.tap()
        XCTAssertTrue(app.navigationBars["Recipe book"].waitForExistence(timeout: 6), "the recipe book did not open",
                      file: file, line: line)
    }

    /// From the open recipe book: Create → Manual entry.
    @MainActor
    private func openManualEditorFromBook(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let create = app.buttons["Create"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 6), "the book has no Create button", file: file, line: line)
        create.tap()
        let manual = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Manual entry")).firstMatch
        XCTAssertTrue(manual.waitForExistence(timeout: 6), "the chooser has no Manual entry option", file: file, line: line)
        manual.tap()
        XCTAssertTrue(app.navigationBars["New recipe"].waitForExistence(timeout: 6), "the manual editor did not open",
                      file: file, line: line)
    }

    /// Taps the Private tab until `target` shows. Bounded: one or two "Private"-labelled buttons,
    /// and a tap in the first seconds can be lost.
    @MainActor
    private func openPrivateTab(until target: XCUIElement, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) {
        let tabs = app.buttons.matching(NSPredicate(format: "label == %@", "Private"))
        for index in 0..<min(max(tabs.count, 1), 4) where !target.exists {
            tabs.element(boundBy: index).tap()
            _ = target.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(target.exists, "the Private tab never showed \(target)", file: file, line: line)
    }

    /// Swipes the page up until `element` can be tapped. Bounded: a sheet's form is a few screens.
    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        _ = element.waitForExistence(timeout: 4)
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) never scrolled into reach", file: file, line: line)
    }

    /// Waits for an onboarding step's title, then taps its Continue once it is enabled.
    @MainActor
    private func continueOnboarding(in app: XCUIApplication, waitingFor title: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        // Long: the first step waits out the launch overlay too.
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 30), "onboarding never showed \(title)",
                      file: file, line: line)
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "\(title) has no Continue", file: file, line: line)
        XCTAssertTrue(next.isEnabled || next.wait(for: \.isEnabled, toEqual: true, timeout: 5),
                      "\(title)'s Continue never enabled", file: file, line: line)
        next.tap()
    }

    @MainActor
    private func tapOnboardingChoice(_ identifier: String, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let choice = app.buttons[identifier]
        XCTAssertTrue(choice.waitForExistence(timeout: 6), "onboarding has no \(identifier)", file: file, line: line)
        choice.tap()
    }

    private func nameField(in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "black bean bowls")).firstMatch
    }

    private func quantityField(in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Qty")).firstMatch
    }

    private func searchField(in app: XCUIApplication) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "Search recipes and products")).firstMatch
    }

    /// Attaches a screenshot kept on success too, so the accessory can be eyeballed.
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
