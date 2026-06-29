import XCTest

// MARK: - UX appearance test harness
//
// These helpers back the ScreenAppearance* suites, whose job is different from every
// other UI suite in the tree: instead of asserting behavior (does element X exist / is it
// enabled), they check that each screen *looks right* — rendered, not clipped off-screen,
// not blank, not riding under the status bar — and attach a labeled screenshot of every
// screen so the whole app can be reviewed as a gallery in one test run.
//
// What XCUITest can and can't see: it has no access to colors or fonts, so true visual
// fidelity (the warm parchment / serif "vibe") is verified by the attached screenshots.
// What it *can* check deterministically is geometry — element frames vs the screen and the
// tab bar — which is exactly the class of "this screen looks off" bug (clipped headers,
// content pushed off-screen, blank states) that motivated this suite.

/// Builds a `-completeOnboarding` app pre-seeded with representative demo content
/// (`FERNLET_UI_TEST_SEED_DEMO`) so screens render populated rather than empty.
@MainActor
enum UXTestApp {
    static func launch(
        openSheet sheetID: String? = nil,
        bypassPrivateLock: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        if let sheetID { app.launchEnvironment["FERNLET_UI_TEST_OPEN_SHEET"] = sheetID }
        if bypassPrivateLock { app.launchEnvironment["FERNLET_UI_TEST_BYPASS_PRIVATE_LOCK"] = "1" }
        for (key, value) in extraEnvironment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }
}

/// Layout-sanity + screenshot probe for a single screen or sheet. Chainable; every
/// assertion carries a `[screen]` prefixed message so a gallery run pinpoints which screen
/// is off.
@MainActor
struct UXScreenProbe {
    let app: XCUIApplication
    let name: String
    unowned let test: XCTestCase

    /// Frame-math slack (pt) to absorb rounding / antialiasing.
    private let tolerance: CGFloat = 1.0

    init(_ app: XCUIApplication, _ name: String, in test: XCTestCase) {
        self.app = app
        self.name = name
        self.test = test
    }

    private var window: XCUIElement { app.windows.firstMatch }

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    // MARK: Core assertions

    /// The anchor rendered, has a non-degenerate frame, and sits fully within the screen
    /// (not clipped off any edge). This is the workhorse "the screen looks structurally
    /// correct" check.
    @discardableResult
    func assertOnScreen(
        _ identifier: String,
        timeout: TimeInterval = 8,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        assertElementOnScreen(element(identifier), "anchor '\(identifier)'", timeout: timeout, file: file, line: line)
    }

    /// Same on-screen / not-clipped checks as `assertOnScreen` but against an element the
    /// caller already has (e.g. a title `staticText` or a `Continue` button) — used where a
    /// screen has no stable identifier to key on.
    @discardableResult
    func assertElementOnScreen(
        _ el: XCUIElement,
        _ describe: String,
        timeout: TimeInterval = 8,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        XCTAssertTrue(
            el.waitForExistence(timeout: timeout),
            "[\(name)] \(describe) never appeared — screen failed to render or wasn't reached",
            file: file, line: line
        )
        guard el.exists else { return self }

        let frame = el.frame
        XCTAssertTrue(
            frame.width >= 2 && frame.height >= 2,
            "[\(name)] \(describe) has a degenerate frame \(frame) — it didn't lay out",
            file: file, line: line
        )

        let bounds = window.frame
        XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - tolerance,
            "[\(name)] \(describe) is clipped past the LEFT edge (\(frame) vs \(bounds))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + tolerance,
            "[\(name)] \(describe) is clipped past the RIGHT edge (\(frame) vs \(bounds))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - tolerance,
            "[\(name)] \(describe) is clipped past the TOP edge (\(frame) vs \(bounds))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + tolerance,
            "[\(name)] \(describe) is clipped past the BOTTOM edge (\(frame) vs \(bounds))", file: file, line: line)
        return self
    }

    /// A header sits below the status bar / Dynamic Island rather than hidden under it.
    /// Skipped when the configuration exposes no status bar.
    @discardableResult
    func assertBelowStatusBar(
        _ identifier: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        assertBelowStatusBarElement(element(identifier), describe: "'\(identifier)'", file: file, line: line)
    }

    @discardableResult
    func assertBelowStatusBarElement(
        _ el: XCUIElement,
        describe: String = "element",
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        let statusBar = app.statusBars.firstMatch
        guard statusBar.exists, el.exists else { return self }
        XCTAssertGreaterThanOrEqual(
            el.frame.minY, statusBar.frame.maxY - tolerance,
            "[\(name)] \(describe) rides under the status bar (top \(el.frame.minY) < status-bar bottom \(statusBar.frame.maxY))",
            file: file, line: line
        )
        return self
    }

    /// The element does not overlap the floating bottom tab bar (content hidden behind it).
    /// Uses the Home tab button as the tab-bar reference; skipped when no tab bar is shown
    /// (e.g. inside a sheet).
    @discardableResult
    func assertAboveTabBar(
        _ identifier: String,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        let tabButton = app.buttons["Home"]
        let el = element(identifier)
        guard tabButton.exists, tabButton.isHittable, el.exists else { return self }
        XCTAssertLessThanOrEqual(
            el.frame.maxY, tabButton.frame.minY + tolerance,
            "[\(name)] '\(identifier)' overlaps / sits behind the tab bar (bottom \(el.frame.maxY) > tab-bar top \(tabButton.frame.minY))",
            file: file, line: line
        )
        return self
    }

    /// Proves the screen isn't blank by finding an expected/seeded piece of content.
    @discardableResult
    func assertNotEmpty(
        containing text: String,
        timeout: TimeInterval = 5,
        file: StaticString = #file,
        line: UInt = #line
    ) -> Self {
        let match = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text))
            .firstMatch
        XCTAssertTrue(
            match.waitForExistence(timeout: timeout),
            "[\(name)] expected content containing '\(text)' but found none — screen looks empty/unpopulated",
            file: file, line: line
        )
        return self
    }

    // MARK: Screenshot gallery

    /// Attaches a labeled, always-kept screenshot of the current screen for visual review.
    @discardableResult
    func capture(_ suffix: String = "") -> Self {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = suffix.isEmpty ? name : "\(name) – \(suffix)"
        attachment.lifetime = .keepAlways
        test.add(attachment)
        return self
    }
}
