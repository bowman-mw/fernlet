import XCTest

// MARK: - The VoiceOver dry-run harness
//
// The simulator half of the evidence the VoiceOver row of `Docs/Accessibility-Nutrition-Labels.md`
// is waiting on (§3). Apple's criterion is that every common task can be completed using ONLY
// VoiceOver, and the only proof Apple accepts is a person doing it on a device. What a UI test can
// do first is rule out the failures that would stop that person before they start, by walking each
// task the way VoiceOver reaches it:
//
// - every step FINDS its control through the accessibility tree — an identifier or the label
//   VoiceOver speaks — and never through a coordinate;
// - every control it activates must be the KIND of element VoiceOver announces as actionable (a
//   button, a text field, a switch) and must speak WORDS, not an SF Symbol name;
// - every screen it passes through is audited with `performAccessibilityAudit`, restricted to the
//   types that decide whether VoiceOver can describe and operate an element, at zero tolerance;
// - every screen's linear reading order — what swiping right from the top would speak — is
//   attached to the run, so the device pass knows what it should hear.
//
// What this cannot see, and the device checklist therefore owns: what VoiceOver actually SPEAKS
// (announcements never report back — see `FernletAnnouncer`), where the cursor lands when a sheet
// opens or closes, whether a modal traps the cursor (XCUITest ignores `accessibilityHidden`, §5),
// and custom actions (no XCUITest API exposes them).

/// Drives one common task through the accessibility tree only, auditing every screen it visits.
///
/// Chainable like ``UXScreenProbe``, and every failure is prefixed with the task's name so a run of
/// all four tasks says which one broke and at which step.
@MainActor
struct VoiceOverWalk {
    let app: XCUIApplication
    /// The task under test ("Log water"), prefixed to every failure and attachment.
    let task: String
    unowned let test: XCTestCase

    init(_ app: XCUIApplication, task: String, in test: XCTestCase) {
        self.app = app
        self.task = task
        self.test = test
    }

    // MARK: Audit

    /// The audit types that decide whether VoiceOver can describe and operate an element.
    ///
    /// `.sufficientElementDescription` is the label check, including "Label not human-readable"
    /// (an SF Symbol name spoken aloud); `.trait` is a control that does not say what it is;
    /// `.hitRegion` is an element smaller than a touch-exploring finger can find.
    ///
    /// Left out on purpose: `.contrast`, `.dynamicType` and `.textClipped` belong to the Sufficient
    /// Contrast and Larger Text rows, and the gallery (`UXScreenProbe`) already freezes those.
    /// `.elementDetection` was in the first version and came out on measurement (2026-10-18): over
    /// the Move tab's half-height Suggest sheet it reported four element-less "Potentially
    /// inaccessible text" issues, and the run's screen recording shows why — the auditor reads the
    /// dimmed Move tab BEHIND the sheet, text a modal sheet correctly hides from VoiceOver. Its
    /// findings carry no element, so a real one could not be told from that, and an unattributable
    /// failure is one nobody can act on. Text VoiceOver cannot reach is covered instead by the
    /// attached reading order, which is what the device pass is checked against.
    static let auditTypes: XCUIAccessibilityAuditType = [
        .sufficientElementDescription, .trait, .hitRegion
    ]

    /// Audits the current screen and attaches what VoiceOver would read on it.
    ///
    /// Zero tolerance: unlike the gallery's ratchet there is no baseline, because a VoiceOver
    /// finding on a common task's path is exactly the kind of defect the declaration is waiting on.
    /// A finding that is not one goes in ``knownNonBlockers`` with its reason.
    @discardableResult
    func audit(_ screen: String, file: StaticString = #file, line: UInt = #line) throws -> Self {
        try attachReadingOrder(screen, file: file, line: line)
        var findings: [String] = []
        try app.performAccessibilityAudit(for: Self.auditTypes) { issue in
            let described = UXScreenProbe.describe(issue)
            let excused = Self.knownNonBlockers.contains { described.contains($0.descriptionContains) }
            if !excused { findings.append(described) }
            // Always handled here, so the failure below carries the task and screen names.
            return true
        }
        XCTAssertTrue(
            findings.isEmpty,
            "[\(task) · \(screen)] VoiceOver-relevant audit findings:\n" + findings.joined(separator: "\n"),
            file: file, line: line
        )
        return self
    }

    /// One audit finding on a task's path that is provably not a VoiceOver blocker.
    struct NonBlocker: Sendable {
        /// A substring of ``UXScreenProbe/describe(_:)``'s rendering of the issue.
        let descriptionContains: String
        /// Why a VoiceOver user is not stopped by it.
        let reason: String
    }

    /// Findings excused from ``audit(_:file:line:)``, each with its reason. Same bar as every other
    /// allowlist in the repo: state the invariant, not the inconvenience.
    ///
    /// Empty since the 2026-10-18 rebase: the two entries it held — Home's 8pt care-score readout and
    /// the journal's "Start from this" prompt, both the gallery's frozen hit-region findings — were
    /// fixed to 44pt by the Larger Text round (#38), and an excuse that matches nothing is a hole.
    static let knownNonBlockers: [NonBlocker] = []

    // MARK: Reaching and activating controls

    /// The button VoiceOver would land on for `key` (an identifier or the spoken label), asserted
    /// reachable, actionable and speaking words.
    @discardableResult
    func button(_ key: String, timeout: TimeInterval = 8, file: StaticString = #file, line: UInt = #line) -> XCUIElement {
        let element = app.buttons[key].firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "[\(task)] no button '\(key)' in the accessibility tree — VoiceOver cannot reach it as a control",
            file: file, line: line
        )
        assertSpeaksWords(element, describe: "button '\(key)'", file: file, line: line)
        return element
    }

    /// Activates a control the way VoiceOver's double-tap does: through the ELEMENT, which XCUITest
    /// resolves in the accessibility tree and scrolls into view first, as VoiceOver's cursor does —
    /// never through a coordinate.
    func activate(_ element: XCUIElement, file: StaticString = #file, line: UInt = #line) {
        XCTAssertTrue(element.isEnabled, "[\(task)] '\(element.label)' is disabled", file: file, line: line)
        scrollClearOfTabBar(element)
        element.tap()
    }

    /// Most drags spent bringing one element out from under the tab bar.
    static let maxTabBarClearingDrags = 4
    /// The floating tab bar's buttons, by their spoken labels (``FernletTab`` titles; the buttons
    /// carry no identifier).
    static let tabBarLabels = ["Home", "Food", "Move", "Friends", "Private"]
    /// The bar's own padding and material above its buttons' frames, in points.
    static let tabBarTopInset: CGFloat = 12

    /// Fernlet's custom floating tab bar draws over the bottom of a scrolling screen, and XCUITest
    /// counts an element under it as visible, so `tap()` lands on the bar instead (Home's first Quick
    /// log row at launch, once the seeded sick-day card pushes it down). VoiceOver's cursor would bring
    /// the element fully into view, so drag the content up until the element clears the bar. Only
    /// while a tab button is hittable: a sheet over the bar means the element is in the sheet, which
    /// is never dragged. A tab button itself is never moved.
    private func scrollClearOfTabBar(_ element: XCUIElement) {
        guard !Self.tabBarLabels.contains(element.label), let barTop = tabBarTop() else { return }
        for _ in 0..<Self.maxTabBarClearingDrags {
            let covered = element.frame.maxY - barTop
            guard covered > 0 else { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = start.withOffset(CGVector(dx: 0, dy: -min(300, covered + 60)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    /// The top edge of the floating tab bar on screen, or nil when no tab button is hittable (a sheet
    /// or a full-screen flow covers it).
    private func tabBarTop() -> CGFloat? {
        let tops = Self.tabBarLabels.compactMap { label -> CGFloat? in
            let button = app.buttons[label].firstMatch
            guard button.exists, button.isHittable else { return nil }
            return button.frame.minY
        }
        return tops.min().map { $0 - Self.tabBarTopInset }
    }

    /// Finds and activates the button for `key`.
    func press(_ key: String, timeout: TimeInterval = 8, file: StaticString = #file, line: UInt = #line) {
        activate(button(key, timeout: timeout, file: file, line: line), file: file, line: line)
    }

    /// The button whose spoken label begins with `prefix` — for controls whose label carries live
    /// state ("Water, 3 bottles"), which is exactly what VoiceOver hears and so what to match on.
    @discardableResult
    func button(labelStartingWith prefix: String, timeout: TimeInterval = 8,
                file: StaticString = #file, line: UInt = #line) -> XCUIElement {
        let element = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "[\(task)] no button whose label starts '\(prefix)' — VoiceOver cannot reach it as a control",
            file: file, line: line
        )
        assertSpeaksWords(element, describe: "button '\(prefix)…'", file: file, line: line)
        return element
    }

    /// Any element by identifier, asserted present — for fields, adjustables and containers.
    @discardableResult
    func element(_ identifier: String, timeout: TimeInterval = 8,
                 file: StaticString = #file, line: UInt = #line) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(
            element.waitForExistence(timeout: timeout),
            "[\(task)] '\(identifier)' never appeared in the accessibility tree",
            file: file, line: line
        )
        return element
    }

    /// Types into a text field or view the way a VoiceOver user does: activate it (double-tap
    /// focuses it and raises the keyboard), then type.
    func type(_ text: String, into field: XCUIElement, file: StaticString = #file, line: UInt = #line) {
        activate(field, file: file, line: line)
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) {
            activate(field, file: file, line: line)
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2),
                      "[\(task)] activating the field raised no keyboard", file: file, line: line)
        field.typeText(text)
    }

    /// Waits for `element`'s spoken value to differ from `old` — how a test hears a counter move.
    func waitForValue(of element: XCUIElement, toChangeFrom old: String, timeout: TimeInterval = 4) -> Bool {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", old), object: element)
        return XCTWaiter().wait(for: [changed], timeout: timeout) == .completed
    }

    /// Answers Apple's Health permission sheet if it appears. The first logged workout offers it
    /// (`FernletStore.offerWorkoutHealthAccessOnFirstUse`). It is Apple's own sheet, not Fernlet's,
    /// so the walk only needs to get past it; "Don't Allow" leaves the simulator's Health untouched.
    func dismissHealthAccessIfShown(timeout: TimeInterval = 3) {
        let decline = app.buttons["Don't Allow"].firstMatch
        guard decline.waitForExistence(timeout: timeout) else { return }
        decline.tap()
    }

    /// The element's spoken label is present and reads as words rather than a glyph name.
    func assertSpeaksWords(_ element: XCUIElement, describe: String, file: StaticString = #file, line: UInt = #line) {
        guard element.exists else { return }
        let label = element.label
        XCTAssertFalse(label.isEmpty, "[\(task)] \(describe) has no spoken label", file: file, line: line)
        XCTAssertFalse(
            Self.readsAsGlyphName(label),
            "[\(task)] \(describe) speaks the glyph name '\(label)'",
            file: file, line: line
        )
    }

    /// An SF Symbol name or a raw dotted token: lower-case letters and digits in two or more
    /// dot-separated runs and nothing else ("figure.strengthtraining.traditional",
    /// "plus.circle.fill"). A sentence has a space, an abbreviation a capital, and an email address
    /// an "@" — the first run of this check flagged the developer's address on Safety & reporting.
    static func readsAsGlyphName(_ label: String) -> Bool {
        label.wholeMatch(of: /[a-z][a-z0-9]*(\.[a-z0-9]+)+/) != nil
    }

    // MARK: Reading order

    /// The element kinds VoiceOver stops on when swiping through a screen.
    static let spokenTypes: Set<XCUIElement.ElementType> = [
        .button, .staticText, .textField, .secureTextField, .textView, .searchField, .image,
        .switch, .toggle, .slider, .stepper, .link, .segmentedControl, .picker, .pickerWheel
    ]

    /// Kinds VoiceOver reads as ONE element, under their own label, never visiting the children
    /// XCUITest lists beneath them. Measured on the first run (2026-10-18): XCUITest reports a
    /// SwiftUI button's icon and text as descendants — the Friends tab's `person.2.fill`, the
    /// Journal tile's `book.closed`, the Exercise history row's `clock.arrow.circlepath` — while
    /// the button itself reads "Friends", "Journal, 3 entries", "Exercise history". Walking into
    /// them would report glyphs VoiceOver never speaks; the button's OWN label is still checked.
    static let atomicTypes: Set<XCUIElement.ElementType> = [
        .button, .link, .textField, .secureTextField, .textView, .searchField,
        .switch, .toggle, .slider, .stepper, .image, .staticText
    ]

    /// Upper bound on the elements walked per screen. A dense screen has a few hundred; the bound
    /// exists so the walk is finite, not to trim it.
    static let maximumWalkedElements = 2_000

    /// One stop in the reading order: the rendered line, plus the nearest identified container it
    /// sits in, which is what ``hiddenGlyphs`` keys on.
    struct Stop {
        let line: String
        let label: String
        let container: String?
    }

    /// What swiping right from the top of the current screen would visit, in accessibility order:
    /// one stop per spoken element with its kind, label, identifier and state.
    func readingOrder() throws -> [Stop] {
        var stops: [Stop] = []
        var pending: [(node: XCUIElementSnapshot, container: String?)] = [(try app.snapshot(), nil)]
        for _ in 0..<Self.maximumWalkedElements {
            guard let entry = pending.popLast() else { break }
            let (node, container) = entry
            // Children reversed onto the stack so they pop in document order — unless VoiceOver
            // reads this element as one, in which case its children are never visited.
            if !Self.atomicTypes.contains(node.elementType) {
                let inner = node.identifier.isEmpty ? container : node.identifier
                pending.append(contentsOf: node.children.reversed().map { ($0, inner) })
            }
            guard Self.spokenTypes.contains(node.elementType) else { continue }
            guard !node.label.isEmpty || node.elementType != .staticText else { continue }
            stops.append(Stop(line: Self.line(for: node), label: node.label, container: container))
        }
        return stops
    }

    /// A symbol image that IS hidden from VoiceOver in source but that XCUITest still lists.
    struct HiddenGlyph: Sendable {
        /// The symbol name XCUITest reports as the image's label.
        let glyph: String
        /// The identifier of the container it sits in — the excuse holds there and nowhere else.
        let container: String
        /// Where the source hides it.
        let hiddenAt: String
    }

    /// Glyphs the reading order may list that VoiceOver never reaches. **Measured, not assumed:**
    /// XCUITest ignores `.accessibilityHidden(true)` on a child of an `.accessibilityElement(children:
    /// .contain)` container (§5 of the declaration doc found the same for the lock gate), so each
    /// entry names the source line that hides it. Keyed on symbol AND container, so the same symbol
    /// left unhidden on another screen still fails.
    static let hiddenGlyphs: [HiddenGlyph] = [
        HiddenGlyph(glyph: "lock.shield", container: "move.progressPhotos.lockNudge",
                    hiddenAt: "ProgressPhotoTimeline.swift, the lock nudge's heading icon")
    ]

    /// One reading-order line: `Button · Add a bottle of water · id=home.water.quickAdd · selected`.
    static func line(for node: XCUIElementSnapshot) -> String {
        var parts = [kindName(node.elementType), node.label.isEmpty ? "<no label>" : node.label]
        if let value = node.value as? String, !value.isEmpty { parts.append("value=\(value)") }
        if !node.identifier.isEmpty { parts.append("id=\(node.identifier)") }
        if node.isSelected { parts.append("selected") }
        if !node.isEnabled { parts.append("dimmed") }
        return parts.joined(separator: " · ")
    }

    /// A readable name for the element kinds in ``spokenTypes``.
    static func kindName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: "Button"
        case .staticText: "Text"
        case .textField, .secureTextField, .searchField: "Text field"
        case .textView: "Text view"
        case .image: "Image"
        case .switch, .toggle: "Switch"
        case .slider: "Adjustable"
        case .stepper: "Stepper"
        case .link: "Link"
        case .segmentedControl: "Segmented"
        case .picker, .pickerWheel: "Picker"
        default: "Element(\(type.rawValue))"
        }
    }

    /// Attaches the reading order and fails on any spoken element whose label is a glyph name —
    /// the same defect as the audit's "Label not human-readable", checked independently of the
    /// audit so a screen the auditor under-reports is still covered.
    private func attachReadingOrder(_ screen: String, file: StaticString, line: UInt) throws {
        let stops = try readingOrder()
        let attachment = XCTAttachment(string: stops.map(\.line).joined(separator: "\n"))
        attachment.name = "VoiceOver reading order — \(task) · \(screen)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        let glyphs = stops.filter { stop in
            Self.readsAsGlyphName(stop.label) && !Self.hiddenGlyphs.contains {
                $0.glyph == stop.label && $0.container == stop.container
            }
        }.map(\.line)
        XCTAssertTrue(
            glyphs.isEmpty,
            "[\(task) · \(screen)] VoiceOver would speak glyph names:\n" + glyphs.joined(separator: "\n"),
            file: file, line: line
        )
    }
}
