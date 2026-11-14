import XCTest

/// Guards the #7 redesigned home cards: First Aid previews its tools as chips, and Milestones shows the
/// kept kinds of care as a keepsake shelf. Both must render and stay tappable to their destinations.
/// In the World look Home is the map and these cards live in the Today panel, which the map's status
/// plate opens.
@MainActor
final class HomeCardsRedesignUITests: XCTestCase {

    func testFirstAidAndMilestonesCardsRenderAndOpen() {
        let app = UXTestApp.launch()
        openToday(in: app)

        let firstAid = app.descendants(matching: .any)["home.firstAid"].firstMatch
        XCTAssertTrue(scrollClearOfTabBar(firstAid, in: app), "First Aid card not reachable")

        // The card is one tap target (chips are decorative) and opens the First Aid sheet.
        firstAid.tap()
        let firstAidSheet = app.staticTexts["Slow breathing"].firstMatch
        XCTAssertTrue(firstAidSheet.waitForExistence(timeout: 5), "First Aid card did not open the tools sheet")
        // Dismiss the sheet: the framed sheet's Done.
        let done = app.buttons["sheet.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the First Aid sheet has no Done")
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["sheet.firstAid"].firstMatch.waitForNonExistence(timeout: 5),
                      "the First Aid sheet did not close")

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

    /// A5·Q2 — every personal-care toggle on the Personal care card (in the Today panel) must be its own focusable element, must
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
    /// one of `HomeWidget.defaultWidgets`), so the card has to be switched on in Arrange Today first.
    func testPersonalCareTogglesAreIndividuallyReachableAndOperable() {
        let app = addPersonalCareCardToHome()

        // Label-based, so the walk finds the card in both the flattened and the restructured tree.
        let anchor = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Personal care")).firstMatch
        XCTAssertTrue(scrollClearOfTabBar(anchor, in: app), "Personal care card not reachable in Today")
        // Then the card's last toggle, so the whole grid is on screen: it is lazy, and lays out only
        // the rows near the screen (two of eight with the card's header at y≈820), while the walk
        // below counts all eight.
        let lastTask = app.buttons[Self.lastTaskLabel].firstMatch
        XCTAssertTrue(scrollClearOfTabBar(lastTask, in: app), "'\(Self.lastTaskLabel)' toggle not reachable in Today")

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
        // Clear of the panel's edges, not merely hittable: see `scrollClearOfTabBar`.
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

        setPersonalCareCard(shown: false, in: app)
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
    ///
    /// Read from ONE snapshot of the tree, not element by element: ticking a task can raise a
    /// transient banner (a silly-stat stamp) over Today, and a tree that changes between the listing
    /// and the per-element reads fails the read with "No matches found for Identity Binding".
    @discardableResult
    private func dumpPersonalCareElements(in app: XCUIApplication) -> Int {
        let wanted = Set(Self.personalCareTaskLabels)
        var found = 0
        print("AX-WALK ── personal-care card ──")
        for element in snapshotElements(of: app) {
            let label = element.label
            guard label.lowercased().hasPrefix("personal care") || wanted.contains(label) else { continue }
            if wanted.contains(label) && element.elementType == .button { found += 1 }
            print("AX-WALK type=\(element.elementType.rawValue) label=\"\(label)\" "
                  + "value=\(String(describing: element.value)) enabled=\(element.isEnabled) "
                  + "selected=\(element.isSelected)")
        }
        print("AX-WALK ── task toggle BUTTONS reachable: \(found) of \(Self.personalCareTaskLabels.count) ──")
        return found
    }

    /// The card's own open-the-sheet control(s): everything labelled "Personal care…" that is not the
    /// `SectionLabel` static text inside it. More than one row here means one action is being offered
    /// as two things to focus.
    private func openCardControls(in app: XCUIApplication) -> [(type: UInt, label: String)] {
        snapshotElements(of: app)
            .filter { $0.label.lowercased().hasPrefix("personal care") && $0.elementType != .staticText }
            .map { (type: $0.elementType.rawValue, label: $0.label) }
    }

    /// Every element of one snapshot of the app's tree, in document order.
    private func snapshotElements(of app: XCUIApplication) -> [XCUIElementSnapshot] {
        guard let root = try? app.snapshot() else { return [] }
        var all: [XCUIElementSnapshot] = []
        var pending: [XCUIElementSnapshot] = [root]
        while let node = pending.popLast() {
            all.append(node)
            pending.append(contentsOf: node.children.reversed())
        }
        return all
    }

    /// Opens the Today panel from the map's status plate and waits for its first card.
    private func openToday(in app: XCUIApplication) {
        let plate = app.buttons["world.statusPlate"].firstMatch
        XCTAssertTrue(plate.waitForExistence(timeout: 10), "the map's status plate is missing")
        plate.tap()
        XCTAssertTrue(app.buttons["world.panel.close"].firstMatch.waitForExistence(timeout: 8),
                      "the status plate did not open Today")
    }

    /// Switches the opt-in Personal care card on in the Today panel (Arrange Today) and hands back the
    /// app sitting on Today with the card rendered.
    private func addPersonalCareCardToHome() -> XCUIApplication {
        let app = UXTestApp.launch()
        openToday(in: app)
        setPersonalCareCard(shown: true, in: app)
        return app
    }

    /// Shows or hides the Personal care card through Arrange Today, at the bottom of the Today panel
    /// (the Home widget list lives in the app's container, which survives between runs, so the test
    /// switches it off again at the end rather than leave every later suite a rearranged Today).
    /// Runs at the end of the test body rather than in a teardown block: XCTest assertions do not
    /// throw, so a failing assertion above still reaches it.
    private func setPersonalCareCard(shown: Bool, in app: XCUIApplication) {
        let arrange = app.buttons["world.today.arrange"].firstMatch
        XCTAssertTrue(dragUntilHittable(arrange, in: app), "'Arrange Today' not reachable")
        arrange.tap()
        // By identifier on any type: the row's framed switch is a List row whose element type
        // XCUITest reports inconsistently (not always a Switch).
        let toggle = app.descendants(matching: .any)["world.todayEditor.hygiene"].firstMatch
        XCTAssertTrue(dragUntilHittable(toggle, in: app), "the Personal care switch is not in Arrange Today")
        // Flipping the switch moves the row between the shown and hidden halves of the list, so the
        // row can leave the (lazy) list's materialised rows: wait for it either to read the value asked
        // for or to be gone, and tap again only while it still sits there unflipped. Whether the card
        // really followed is checked on Today itself, below.
        let wanted = shown ? "1" : "0"
        let unflipped = NSPredicate(format: "exists == true AND value != %@", wanted)
        func stillUnflipped() -> Bool {
            let moved = XCTNSPredicateExpectation(predicate: NSCompoundPredicate(notPredicateWithSubpredicate: unflipped),
                                                  object: toggle)
            return XCTWaiter().wait(for: [moved], timeout: 3) != .completed
        }
        if stillUnflipped() {
            toggle.tap()
            if stillUnflipped() { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        }
        let done = app.buttons["world.panel.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Arrange Today has no Done")
        done.tap()
        XCTAssertTrue(app.descendants(matching: .any)["world.todayEditor"].firstMatch.waitForNonExistence(timeout: 5),
                      "Arrange Today did not close")
        let card = app.descendants(matching: .any)["home.hygiene"].firstMatch
        if shown {
            XCTAssertTrue(card.waitForExistence(timeout: 5), "Arrange Today did not add the Personal care card")
        } else {
            XCTAssertTrue(card.waitForNonExistence(timeout: 5), "Arrange Today did not remove the Personal care card")
        }
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

    /// Drags the Today feed until the element sits wholly between the panel's title plate and the
    /// bottom of the screen, and reports whether it got there.
    ///
    /// Hittable is not enough: it can be sampled while the feed is still moving, or with the element
    /// half under the plate, and the tap then lands on whatever is drawn there. With the whole frame
    /// clear and two reads that agree, the tap lands on the element's centre. (The name is from the
    /// tab-bar era, when the floating bar was what covered the feed's bottom.)
    private func scrollClearOfTabBar(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        // The feed scrolls up under the panel's title plate; the home indicator sits at the bottom.
        let topClear: CGFloat = 130
        let tabBarClear: CGFloat = 40
        for _ in 0..<14 {
            guard element.exists else { dragFeed(by: 300, in: app); continue }
            let frame = element.frame
            let bottom = window.frame.maxY - tabBarClear
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
