import XCTest

/// Guards the #7 redesigned home cards: First Aid previews its tools as chips, and Milestones shows the
/// kept kinds of care as a keepsake shelf. Both must render and stay tappable to their destinations.
@MainActor
final class HomeCardsRedesignUITests: XCTestCase {

    func testFirstAidAndMilestonesCardsRenderAndOpen() {
        let app = UXTestApp.launch()

        let firstAid = app.descendants(matching: .any)["home.firstAid"].firstMatch
        XCTAssertTrue(scrollUntilHittable(firstAid, in: app), "First Aid card not reachable")

        // The card is one tap target (chips are decorative) and opens the First Aid sheet.
        firstAid.tap()
        let firstAidSheet = app.staticTexts["Slow breathing"].firstMatch
        XCTAssertTrue(firstAidSheet.waitForExistence(timeout: 5), "First Aid card did not open the tools sheet")
        // Dismiss the sheet.
        app.swipeDown(velocity: .fast)

        let milestones = app.descendants(matching: .any)["home.milestones"].firstMatch
        XCTAssertTrue(scrollUntilHittable(milestones, in: app), "Milestones card not reachable")
        milestones.tap()
        // MilestonesView presents as a large sheet (HOME-13, 2026-08-21 redesign); assert its
        // stable screen anchor, which survived the push → sheet conversion (a bare
        // navigationBars.firstMatch check matched ANY nav bar, so it passed without opening
        // anything at all).
        XCTAssertTrue(app.descendants(matching: .any)["screen.milestones"].firstMatch.waitForExistence(timeout: 5),
                      "Milestones card did not present the Milestones sheet")
    }

    /// A5·Q2 — every personal-care toggle on the Home card must be its own focusable element, must
    /// activate the task it names (not the card's open-the-sheet button underneath it), and must say
    /// whether the task is done.
    ///
    /// The eight toggles sit in a `LazyVGrid`. They used to sit in that grid **inside** the card's
    /// outer `Button`, which is the shape that makes SwiftUI flatten a subtree into one element and
    /// promote nested controls to custom actions — and a lazy container materialises no children
    /// while that tree is built. The measured tree (see the AX-WALK dump this test prints) showed the
    /// eight buttons surviving as elements, so what was actually missing was *state*: no toggle
    /// carried `.isSelected`, so a screen reader announced "Floss, button" whether or not the task was
    /// already done. The grid is now a sibling of the open-the-sheet button rather than its child, so
    /// there is no flattening question left to be at the mercy of. `HomeWidget.hygiene` is opt-in (not
    /// one of `HomeWidget.defaultWidgets`), so the card has to be added through Settings first.
    func testPersonalCareTogglesAreIndividuallyReachableAndOperable() {
        let app = addPersonalCareCardToHome()

        // Label-based, so the walk finds the card in both the flattened and the restructured tree.
        let anchor = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Personal care")).firstMatch
        XCTAssertTrue(scrollUntilHittable(anchor, in: app), "Personal care card not reachable on Home")

        let reachable = dumpPersonalCareElements(in: app)
        XCTAssertEqual(reachable, Self.personalCareTaskLabels.count,
                       "personal-care toggles reachable as their own accessibility elements")

        // One control, one element. `.accessibilityElement(children: .ignore)` stacked on a `Button`
        // mints a second, traitless element beside it, and a card that offers two things to focus for
        // one action is worse than the derived label it was trying to improve.
        let cardControls = openCardControls(in: app)
        XCTAssertEqual(cardControls.count, 1,
                       "the card's open control should be exactly one element: \(cardControls)")
        XCTAssertEqual(cardControls.first?.type, XCUIElement.ElementType.button.rawValue,
                       "the card's open control should keep its button trait: \(cardControls)")

        // Operable, not merely present: activating one has to flip that task's own selected state,
        // and must not activate the card's open-the-sheet button underneath it.
        let floss = app.buttons[Self.flossTaskLabel].firstMatch
        XCTAssertTrue(floss.isHittable, "'\(Self.flossTaskLabel)' toggle is present but not hittable")
        let wasSelected = floss.isSelected
        floss.tap()
        let flipped = expectation(for: NSPredicate(format: "isSelected == %@", NSNumber(value: !wasSelected)),
                                  evaluatedWith: floss)
        wait(for: [flipped], timeout: 8)

        print("AX-WALK after activating '\(Self.flossTaskLabel)': "
              + "hygiene sheet open = \(app.descendants(matching: .any)["sheet.hygiene"].firstMatch.exists)")
        dumpPersonalCareElements(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["sheet.hygiene"].firstMatch.exists,
                       "activating a task toggle fell through to the card's open-the-sheet button")

        restoreDefaultHomeWidgets(in: app)
    }

    /// The eight built-in `HygieneItem` labels, in `allCases` order. English on purpose: the
    /// simulator runs the base localization, and these are the strings an assistive technology
    /// speaks there.
    private static let personalCareTaskLabels = [
        "Brush teeth AM", "Brush teeth PM", "Floss", "Shower",
        "Deodorant", "Skincare AM", "Skincare PM", "Sunscreen",
    ]

    private static let flossTaskLabel = "Floss"

    /// Prints the AX-walk — element type, label, value, enabled/selected/hittable for everything the
    /// card contributes to the accessibility tree — and returns how many of the eight toggles are
    /// there as their own *button*. The dump is what makes a regression quotable rather than a bare
    /// boolean; the count deliberately ignores the `StaticText` each button wraps, which is a second
    /// element carrying the same label and would double every total.
    @discardableResult
    private func dumpPersonalCareElements(in app: XCUIApplication) -> Int {
        let wanted = Set(Self.personalCareTaskLabels)
        let elements = app.descendants(matching: .any).allElementsBoundByAccessibilityElement
        var found = 0
        print("AX-WALK ── personal-care card ──")
        for element in elements {
            let label = element.label
            guard label.lowercased().hasPrefix("personal care") || wanted.contains(label) else { continue }
            if wanted.contains(label) && element.elementType == .button { found += 1 }
            print("AX-WALK type=\(element.elementType.rawValue) label=\"\(label)\" "
                  + "value=\(String(describing: element.value)) enabled=\(element.isEnabled) "
                  + "selected=\(element.isSelected) hittable=\(element.isHittable)")
        }
        print("AX-WALK ── task toggle BUTTONS reachable: \(found) of \(Self.personalCareTaskLabels.count) ──")
        return found
    }

    /// The card's own open-the-sheet control(s): everything labelled "Personal care…" that is not the
    /// `SectionLabel` static text inside it. More than one row here means one action is being offered
    /// as two things to focus.
    private func openCardControls(in app: XCUIApplication) -> [(type: UInt, label: String)] {
        app.descendants(matching: .any).allElementsBoundByAccessibilityElement
            .filter { $0.label.lowercased().hasPrefix("personal care") && $0.elementType != .staticText }
            .map { (type: $0.elementType.rawValue, label: $0.label) }
    }

    /// Adds the opt-in Personal care widget via Settings → Appearance → Home widgets, dismisses
    /// Settings, and hands back the app sitting on Home with the card rendered.
    private func addPersonalCareCardToHome() -> XCUIApplication {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 20), "Settings sheet did not open")

        let appearanceRow = app.descendants(matching: .any)["settings.row.appearance"].firstMatch
        XCTAssertTrue(appearanceRow.waitForExistence(timeout: 8), "Appearance settings row missing")
        appearanceRow.tap()
        let appearanceBar = app.navigationBars["Appearance"]
        XCTAssertTrue(appearanceBar.waitForExistence(timeout: 8), "Appearance page did not open")

        // The widget list lives in the app's container, which survives between runs, so start from a
        // known state: reset to the defaults (which do not include Personal care), then add it.
        let reset = app.buttons["Reset home widgets"].firstMatch
        XCTAssertTrue(dragUntilHittable(reset, in: app), "'Reset home widgets' not reachable")
        reset.tap()

        let chip = app.buttons["Personal care"].firstMatch
        XCTAssertTrue(dragUntilHittable(chip, in: app), "'Personal care' Home-widget chip not reachable")
        chip.tap()

        appearanceBar.buttons.firstMatch.tap()
        let done = app.navigationBars["Settings"].buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 8), "Settings Done button missing")
        done.tap()
        return app
    }

    /// Puts the Home layout back to `HomeWidget.defaultWidgets`. The widget list is persisted in the
    /// app's container, which outlives the test process, so leaving Personal care on Home would hand
    /// every later suite in the run a Home tab this one rearranged. Runs at the end of the test body
    /// rather than in a teardown block: XCTest assertions do not throw, so a failing assertion above
    /// still reaches this line.
    private func restoreDefaultHomeWidgets(in app: XCUIApplication) {
        // Relaunched rather than driven from where the test left off: the Home header (and its gear)
        // has been scrolled past by then, and `openSheet:` lands on the Settings root directly.
        _ = UXTestApp.launch(openSheet: "settings")
        let appearanceRow = app.descendants(matching: .any)["settings.row.appearance"].firstMatch
        guard appearanceRow.waitForExistence(timeout: 15) else { return }
        appearanceRow.tap()
        let reset = app.buttons["Reset home widgets"].firstMatch
        guard dragUntilHittable(reset, in: app) else { return }
        reset.tap()
    }

    /// Drags the page up in inertia-free steps until the element can be tapped.
    private func dragUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return true }
            dragPageUp(in: app)
        }
        return element.exists && element.isHittable
    }

    /// Inertia-free page scroll: `swipeUp()`'s fling keeps the list moving after hittability is
    /// sampled, and on the Appearance page (which hosts two `ColorPicker`s) the repeated flings were
    /// enough to lose the automation session. A press-drag-hold ends where it is told to.
    private func dragPageUp(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.80))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
    }

    /// Scrolls the home feed until the element is hittable — both cards sit near the bottom, behind the
    /// floating tab bar, so "exists" isn't enough to tap.
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<14 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }
}
