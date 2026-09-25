import XCTest

/// Guards the #7 redesigned home cards: First Aid previews its tools as chips, and Milestones shows the
/// kept kinds of care as a keepsake shelf. Both must render and stay tappable to their destinations.
@MainActor
final class HomeCardsRedesignUITests: XCTestCase {

    func testFirstAidAndMilestonesCardsRenderAndOpen() {
        let app = UXTestApp.launch()

        let firstAid = app.descendants(matching: .any)["home.firstAid"].firstMatch
        XCTAssertTrue(scrollClearOfTabBar(firstAid, in: app), "First Aid card not reachable")

        // The card is one tap target (chips are decorative) and opens the First Aid sheet.
        firstAid.tap()
        let firstAidSheet = app.staticTexts["Slow breathing"].firstMatch
        XCTAssertTrue(firstAidSheet.waitForExistence(timeout: 5), "First Aid card did not open the tools sheet")
        // Dismiss the sheet.
        app.swipeDown(velocity: .fast)

        let milestones = app.descendants(matching: .any)["home.milestones"].firstMatch
        XCTAssertTrue(scrollClearOfTabBar(milestones, in: app), "Milestones card not reachable")
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
        XCTAssertTrue(scrollClearOfTabBar(anchor, in: app), "Personal care card not reachable on Home")
        // Then the card's last toggle, so the whole grid is on screen: it is lazy, and lays out only
        // the rows near the screen (two of eight with the card's header at y≈820), while the walk
        // below counts all eight.
        let lastTask = app.buttons[Self.lastTaskLabel].firstMatch
        XCTAssertTrue(scrollClearOfTabBar(lastTask, in: app), "'\(Self.lastTaskLabel)' toggle not reachable on Home")

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
        // Clear of the tab bar, not merely hittable: see `scrollClearOfTabBar`.
        let floss = app.buttons[Self.flossTaskLabel].firstMatch
        XCTAssertTrue(scrollClearOfTabBar(floss, in: app), "'\(Self.flossTaskLabel)' toggle is present but not hittable")
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

    /// The grid's last toggle — the last of ``personalCareTaskLabels``.
    private static let lastTaskLabel = "Sunscreen"

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

    /// Drags the home feed until the element sits wholly between the status bar and the floating tab
    /// bar, and reports whether it got there.
    ///
    /// Hittable is not enough. The tab bar is the app's own view drawn over the feed, and XCUITest
    /// steers its tap point off the tab BUTTONS' accessibility frames only — not off the pill drawn
    /// around them. Measured 2026-09-24 with the First Aid header's top at y=810 under the compact
    /// bar: `isHittable` was true, the tap point was (201, 835) — a point below Move's frame, inside
    /// the pill — and `tap()` selected the Move tab, which is the full-suite flake. With the whole
    /// frame above the bar there is nothing to steer around, and the tap lands on the element's centre.
    private func scrollClearOfTabBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        // The feed scrolls up under the status bar. The pill reaches 6pt past the tab buttons, and a
        // tap just outside a tab can still select it.
        let topClear: CGFloat = 100
        let tabBarClear: CGFloat = 16
        for _ in 0..<14 {
            guard element.exists else { dragFeed(by: 300, in: app); continue }
            let frame = element.frame
            // Re-read every pass: the bar compacts, and drops 30pt, once the feed has scrolled.
            let bottom = tabBarTop(in: app) - tabBarClear
            let top = window.frame.minY + topClear
            if frame.maxY > bottom {
                dragFeed(by: frame.maxY - bottom + 40, in: app)
            } else if frame.minY < top {
                dragFeed(by: frame.minY - top - 40, in: app)
            } else if element.isHittable, element.frame == frame {
                // A second read that agrees: the feed has stopped moving.
                return true
            }
        }
        return false
    }

    /// The top of the floating tab bar, read off its Home tab as `UXScreenProbe.assertAboveTabBar`
    /// does. `app.tabBars` is no use here: the bar is a custom SwiftUI view, and on a tab root the
    /// query finds nothing.
    private func tabBarTop(in app: XCUIApplication) -> CGFloat {
        let homeTab = app.buttons["Home"].firstMatch
        return homeTab.exists ? homeTab.frame.minY : app.windows.firstMatch.frame.maxY
    }

    /// Moves the feed's content up by about `distance` points (down when negative) with a
    /// press-drag-hold, which ends where it is told to — unlike `swipeUp()`, whose fling keeps the
    /// feed moving after the frame is read. Never under 60pt of travel: a press that moves less than
    /// the scroll view's ~10pt slop is a tap on whatever sits under it, and that slop is added back.
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
