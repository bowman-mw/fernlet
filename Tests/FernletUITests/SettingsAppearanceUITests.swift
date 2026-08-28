import XCTest

// MARK: - Settings appearance
//
// Opens the Settings sheet and walks each settings sub-screen (NavigationLink → pushed
// destination), capturing a labeled screenshot and asserting the screen's nav bar renders
// on-screen. Privacy & Data is covered separately via its dedicated launch hooks (it is
// gated by a fresh biometric/passcode check). Connection History is skipped: its list is
// empty on a fresh simulator and its title is dynamic.

final class SettingsAppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// (row accessibility identifier used to tap, nav-bar title of the pushed screen).
    ///
    /// The 2026-08-21 hub restructure (artboard 5a): four groups, every row addressed by its
    /// `settings.row.*` identifier because rows now carry sub-label breadcrumbs (a combined
    /// accessibility label no longer equals the row name). The Reminders row deliberately lands on
    /// the Goal & nutrition page (its card lives there); Sleep and Move are deleted (SETT-26);
    /// Core memory / Signals moved inside AI & data sources (walked below); Debug + Connection
    /// Inspector folded into the DEBUG-only Connection log row (SETT-28 — this suite runs Debug,
    /// so the row is present).
    /// The third element is the probe name, written out as a LITERAL rather than built from
    /// `title`. It used to be interpolated (`"Settings · \(title)"`), and interpolated names are
    /// dropped by `AuditRatchetBoundaryTests.probedScreenNames()` — deliberately, since a literal
    /// containing `\(` is not a name any baseline could key on. The consequence was a hole rather
    /// than a saving: these eleven screens were AUDITED by `capture()` but could never be
    /// BASELINED, so every finding on any of them failed this suite permanently and there was no
    /// legal way to record it. Spelling the name out makes them ratchetable like every other screen.
    private let subscreens: [(tap: String, title: String, probe: String)] = [
        (tap: "settings.row.appearance", title: "Appearance", probe: "Settings · Appearance"),
        (tap: "settings.row.goalNutrition", title: "Goal & nutrition", probe: "Settings · Goal & nutrition"),
        (tap: "settings.row.reminders", title: "Goal & nutrition", probe: "Settings · Goal & nutrition"),
        (tap: "settings.row.personalCare", title: "Personal care tasks", probe: "Settings · Personal care tasks"),
        (tap: "settings.row.quickLog", title: "Quick-log shortcuts", probe: "Settings · Quick-log shortcuts"),
        (tap: "settings.row.aiDataSources", title: "AI & data sources", probe: "Settings · AI & data sources"),
        (tap: "settings.row.health", title: "Health", probe: "Settings · Health"),
        (tap: "settings.row.appLock", title: "App lock", probe: "Settings · App lock"),
        (tap: "settings.row.nearbyFriends", title: "Nearby friends", probe: "Settings · Nearby friends"),
        (tap: "settings.row.periodSensitive", title: "Period & sensitive content", probe: "Settings · Period & sensitive content"),
        (tap: "settings.row.connectionLog", title: "Connection log", probe: "Settings · Connection log"),
    ]

    @MainActor
    func testSettingsHubAndSubscreensAppearance() throws {
        let app = UXTestApp.launch(openSheet: "settings")

        // Settings hub itself.
        let settingsBar = app.navigationBars["Settings"]
        try UXScreenProbe(app, "Settings · Hub", in: self)
            .assertOnScreen("sheet.settings")
            .assertElementOnScreen(settingsBar, "Settings nav bar")
            .capture()

        for screen in subscreens {
            try openAndProbe(tap: screen.tap, title: screen.title, probe: screen.probe, app: app)
        }
    }

    /// The pages nested one level down since the restructure: Core memory and Signals live inside
    /// AI & data sources.
    @MainActor
    func testNestedMemoryAndSignalsAppearance() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "settings sheet did not open")

        let aiRow = scrollToRow("settings.row.aiDataSources", app: app)
        XCTAssertTrue(aiRow.isHittable, "AI & data sources row not reachable")
        aiRow.tap()
        XCTAssertTrue(app.navigationBars["AI & data sources"].waitForExistence(timeout: 4))

        // Probe names spelled out for the same reason as `subscreens` above.
        let nested = [(label: "Core memory", title: "Core memory", probe: "Settings · Core memory"),
                      (label: "Signals", title: "Signals", probe: "Settings · Signals")]
        for (label, title, probe) in nested {
            let link = scrollToRow(label, app: app)
            XCTAssertTrue(link.isHittable, "'\(label)' link not reachable inside AI & data sources")
            link.tap()
            let bar = app.navigationBars[title]
            try UXScreenProbe(app, probe, in: self)
                .assertElementOnScreen(bar, "\(title) nav bar")
                .capture()
            let back = bar.buttons.firstMatch
            if back.exists { back.tap() }
            XCTAssertTrue(app.navigationBars["AI & data sources"].waitForExistence(timeout: 4),
                          "did not return to AI & data sources after '\(title)'")
        }
    }

    @MainActor
    func testPrivacyDataAppearance() throws {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_OPEN_PRIVACY_DATA"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_PRIVACY_SERVICES"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_LOCK_CONFIGURED"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_PRIVACY_AUTH"] = "1"
        app.launch()

        let nav = app.navigationBars["Privacy & Data"]
        XCTAssertTrue(nav.waitForExistence(timeout: 8), "Privacy & Data did not open")
        let verify = app.descendants(matching: .any)["privacy.verify"]
        if verify.waitForExistence(timeout: 2) { verify.tap() }

        try UXScreenProbe(app, "Settings · Privacy & Data", in: self)
            .assertElementOnScreen(nav, "Privacy & Data nav bar")
            .capture()
    }

    // MARK: - Helpers

    @MainActor
    private func openAndProbe(tap label: String, title: String, probe: String, app: XCUIApplication) throws {
        let row = scrollToRow(label, app: app)
        XCTAssertTrue(row.isHittable, "settings row '\(label)' not reachable")
        row.tap()

        let bar = app.navigationBars[title]
        try UXScreenProbe(app, probe, in: self)
            .assertElementOnScreen(bar, "\(title) nav bar")
            .capture()

        // Pop back to the Settings list for the next row.
        let back = bar.buttons.firstMatch
        if back.exists { back.tap() }
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 4),
                      "did not return to Settings after '\(title)'")
    }

    /// Swipes the settings list up until the target row sits clearly above the sheet's floating
    /// bottom chrome (Done bar + scrim). Hittability alone is not enough: it can be sampled while
    /// the list is still decelerating, after which the row settles back under the bottom band and
    /// the tap lands on chrome instead of the row.
    @MainActor
    private func scrollToRow(_ label: String, app: XCUIApplication) -> XCUIElement {
        let row = app.buttons[label]
        let window = app.windows.firstMatch
        // Rows must sit fully inside this band before tapping: XCUITest taps the row's CENTER,
        // and a row half-clipped by the sheet's floating Done bar (or the nav/search chrome) is
        // "hittable" via its visible edge while the center tap lands on chrome.
        let topClear: CGFloat = 150
        let bottomClear: CGFloat = 170

        // Inertia-free scroll: press-drag-hold produces a deterministic end position, unlike
        // swipeUp() whose deceleration keeps moving rows after hittability is sampled.
        func drag(dy: CGFloat) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + dy))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }

        for _ in 0..<14 {
            guard row.exists else { drag(dy: -0.3); continue }
            let f = row.frame
            let w = window.frame
            if f.maxY > w.maxY - bottomClear {
                drag(dy: -0.18)
            } else if f.minY < w.minY + topClear {
                drag(dy: 0.18)
            } else if row.isHittable {
                return row
            } else {
                drag(dy: -0.3)
            }
        }
        return row
    }
}
