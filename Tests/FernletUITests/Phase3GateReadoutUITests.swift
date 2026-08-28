import XCTest

// MARK: - Phase 3 gate readout — navigation smoke test
//
// The one thing the unit suite structurally cannot do: RENDER the page.
//
// `Phase3GateReadoutView` shipped reading its store from `@Environment(FernletStore.self)`, which
// nothing in the app has ever populated — so the first body pass trapped and the app died on the
// push, every time, on every device. It compiled clean, no unit test instantiates a SwiftUI body,
// and the implementer's own top residual risk was "this view has NEVER been rendered". This test is
// the pin for that: it walks the real navigation path an owner walks and asserts the page rendered.
//
// It deliberately does NOT use `UXScreenProbe.capture()`. That runs the accessibility audit, whose
// per-screen baselines are environment-sensitive; a debug-only diagnostic page has no baseline and
// would fail on unrelated findings, swamping the one signal this test exists to carry. Structure,
// text, and a screenshot attachment — nothing more.

final class Phase3GateReadoutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings → Connection log → Developer tools → Phase 3 gate readout, and the page renders.
    @MainActor
    func testPhase3GateReadoutPushesAndRenders() throws {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "settings sheet did not open")

        let connectionLog = scrollToRow("settings.row.connectionLog", app: app)
        XCTAssertTrue(connectionLog.isHittable, "Connection log row not reachable")
        connectionLog.tap()
        XCTAssertTrue(app.navigationBars["Connection log"].waitForExistence(timeout: 6),
                      "Connection log did not open")

        // SETT-28 folded the old Debug hub row into the Connection log page.
        let developerTools = scrollToRow("Developer tools", app: app)
        XCTAssertTrue(developerTools.isHittable, "Developer tools row not reachable")
        developerTools.tap()
        XCTAssertTrue(app.navigationBars["Debug"].waitForExistence(timeout: 6),
                      "Developer tools did not open")

        let readoutRow = scrollToRow("settings.row.phase3GateReadout", app: app)
        XCTAssertTrue(readoutRow.isHittable, "Phase 3 gate readout row not reachable")
        readoutRow.tap()

        // The assertion the whole file exists for: the destination's body evaluated without trapping.
        let bar = app.navigationBars["Phase 3 gate readout"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10),
                      "the Phase 3 gate readout did not render — a missing store injection traps on the push")
        XCTAssertTrue(app.state == .runningForeground, "the app died on the push")

        // Structure, top of the page: the two sections that render before any reading is bought.
        XCTAssertTrue(app.staticTexts["What this costs"].waitForExistence(timeout: 6),
                      "the risk section did not render")
        XCTAssertTrue(app.staticTexts["Sitting checklist"].exists, "the checklist section did not render")
        let oneLaunch = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "lives in THIS app launch only")).firstMatch
        XCTAssertTrue(scrollTo(oneLaunch, app: app), "the one-launch warning did not render")

        // Structure, below the fold. The List is lazy, so each of these has to be scrolled to; a
        // bare `.exists` here would assert nothing about a page that failed to lay out.
        let checklistStep = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Turn Auto-Lock off")).firstMatch
        XCTAssertTrue(scrollTo(checklistStep, app: app), "the sitting checklist's steps did not render")

        let sealedColumnRow = app.staticTexts["Sealed columns (journal, cycle, intimacy, worry)"]
        XCTAssertTrue(scrollTo(sealedColumnRow, app: app), "no gate row rendered")

        let reScan = app.buttons["phase3Readout.reScan"]
        XCTAssertTrue(scrollTo(reScan, app: app), "the re-scan control did not render")
        let fetch = app.buttons["phase3Readout.fetchManifests"]
        XCTAssertTrue(fetch.exists, "the fetch-manifests control did not render")

        // The export pair is what closes a sitting, so it has to be reachable too.
        let copyReport = app.buttons["phase3Readout.copyReport"]
        XCTAssertTrue(scrollTo(copyReport, app: app), "the copy-report control did not render")

        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Phase 3 gate readout"
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Helpers

    /// Drags the list up until `element` exists and sits clear of the sheet's chrome. Returns
    /// whether it got there — the List is lazy, so an element below the fold does not exist yet and
    /// a bare `.exists` would pass on a page that never laid out.
    @MainActor
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        for _ in 0..<16 {
            if element.exists {
                let frame = element.frame
                let bounds = window.frame
                if frame.minY > bounds.minY + 120, frame.maxY < bounds.maxY - 140 { return true }
            }
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                        thenHoldForDuration: 0.25)
        }
        return element.exists
    }

    /// Drags the list until the target row sits clear of the sheet's floating chrome, then returns
    /// it. Copied in shape from `SettingsAppearanceUITests.scrollToRow`: hittability alone can be
    /// sampled while the list is still decelerating, after which the tap lands on chrome.
    @MainActor
    private func scrollToRow(_ identifier: String, app: XCUIApplication) -> XCUIElement {
        let row = app.buttons[identifier]
        let window = app.windows.firstMatch
        let topClear: CGFloat = 150
        let bottomClear: CGFloat = 170

        func drag(dy: CGFloat) {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + dy))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.25)
        }

        for _ in 0..<14 {
            guard row.exists else { drag(dy: -0.3); continue }
            let frame = row.frame
            let bounds = window.frame
            if frame.maxY > bounds.maxY - bottomClear {
                drag(dy: -0.18)
            } else if frame.minY < bounds.minY + topClear {
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
