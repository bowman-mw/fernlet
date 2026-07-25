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

    /// (button label used to tap the row, nav-bar title of the pushed screen).
    private let subscreens: [(tap: String, title: String)] = [
        ("Appearance", "Appearance"),
        ("Goal & nutrition", "Goal & nutrition"),
        ("Layout & shortcuts", "Layout & shortcuts"),
        ("Health", "Health"),
        ("Sleep", "Sleep"),
        ("settings.move", "Move"),
        ("Core memory", "Core memory"),
        ("Signals", "Signals"),
        ("Debug", "Debug"),
        ("Connection Inspector", "Connection Inspector"),
        ("App lock", "App lock"),
    ]

    @MainActor
    func testSettingsHubAndSubscreensAppearance() {
        let app = UXTestApp.launch(openSheet: "settings")

        // Settings hub itself.
        let settingsBar = app.navigationBars["Settings"]
        UXScreenProbe(app, "Settings · Hub", in: self)
            .assertOnScreen("sheet.settings")
            .assertElementOnScreen(settingsBar, "Settings nav bar")
            .capture()

        for screen in subscreens {
            openAndProbe(tap: screen.tap, title: screen.title, app: app)
        }
    }

    @MainActor
    func testPrivacyDataAppearance() {
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

        UXScreenProbe(app, "Settings · Privacy & Data", in: self)
            .assertElementOnScreen(nav, "Privacy & Data nav bar")
            .capture()
    }

    // MARK: - Helpers

    @MainActor
    private func openAndProbe(tap label: String, title: String, app: XCUIApplication) {
        let row = scrollToRow(label, app: app)
        XCTAssertTrue(row.isHittable, "settings row '\(label)' not reachable")
        row.tap()

        let bar = app.navigationBars[title]
        UXScreenProbe(app, "Settings · \(title)", in: self)
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
