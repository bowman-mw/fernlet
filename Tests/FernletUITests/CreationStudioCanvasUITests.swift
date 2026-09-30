import XCTest

/// The Creation Studio's canvas owns its touches, and the drawing screen fits without scrolling.
///
/// Owner report 2026-09-29: "On the item designer, it still scrolls when you're drawing and makes
/// it hard to draw. The scrolling should be off for that screen." Until then a one-finger stroke
/// shared its touch with every recognizer above the canvas: an upward stroke scrolled the page
/// under the finger (a long stroke painted one dot), a downward stroke on a blank canvas dragged
/// the whole customization sheet, and a left-to-right first stroke on a blank canvas started the
/// iOS 26 swipe-back and popped the studio, dropping the stroke without the discard prompt.
///
/// These synthesize real strokes (press-and-drag on a coordinate) on the studio reached from the
/// customization sheet's Creation Studio row. "Painted" is read off the Next bar, which is enabled
/// only once the canvas holds paint; "in place" is the canvas card's frame, which moves if the page
/// scrolls or the sheet is dragged and vanishes if the studio is popped.
final class CreationStudioCanvasUITests: XCTestCase {

    /// Each stroke on a BLANK canvas — the state where the sheet drag and the swipe-back were still
    /// live — paints and leaves the page, the sheet and the navigation stack where they were.
    @MainActor
    func testStrokesOnABlankCanvasPaintWithoutMovingThePageTheSheetOrTheStack() {
        let app = launchToStudio()
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let home = canvas.frame
        attachScreenshot(of: app, named: "Studio · blank")

        let strokes: [(name: String, from: CGVector, to: CGVector)] = [
            ("rightward first stroke (was: popped the studio)", CGVector(dx: 0.12, dy: 0.5), CGVector(dx: 0.88, dy: 0.5)),
            ("downward stroke (was: dragged the sheet)", CGVector(dx: 0.5, dy: 0.12), CGVector(dx: 0.5, dy: 0.88)),
            ("upward stroke (was: scrolled the page)", CGVector(dx: 0.3, dy: 0.88), CGVector(dx: 0.3, dy: 0.12)),
        ]
        for (index, entry) in strokes.enumerated() {
            if index > 0 { clearCanvas(in: app) }
            stroke(canvas, from: entry.from, to: entry.to)
            assertPaintedInPlace(app, canvas: canvas, home: home, after: entry.name)
            attachScreenshot(of: app, named: "Studio · after \(entry.name)")
        }
    }

    /// Pinch-zoom still zooms (the canvas's own recognizers kept sharing with paint), and a stroke
    /// on the ZOOMED canvas — which scrolled the page by 80pt before the fix — stays put too.
    @MainActor
    func testPinchZoomStillZoomsAndAZoomedStrokeLeavesThePageInPlace() {
        let app = launchToStudio()
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let home = canvas.frame
        stroke(canvas, from: CGVector(dx: 0.1, dy: 0.5), to: CGVector(dx: 0.9, dy: 0.5))
        assertPaintedInPlace(app, canvas: canvas, home: home, after: "the line to zoom into")
        let before = canvas.screenshot().pngRepresentation
        attachScreenshot(of: app, named: "Studio · before pinch")

        canvas.pinch(withScale: 3, velocity: 3)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(of: app, named: "Studio · after pinch")
        XCTAssertNotEqual(canvas.screenshot().pngRepresentation, before,
                          "pinching the canvas should zoom it — its own recognizers must still work")
        assertInPlace(canvas: canvas, home: home, after: "the pinch")

        stroke(canvas, from: CGVector(dx: 0.4, dy: 0.85), to: CGVector(dx: 0.4, dy: 0.15))
        assertPaintedInPlace(app, canvas: canvas, home: home, after: "an upward stroke on the zoomed canvas")
        attachScreenshot(of: app, named: "Studio · zoomed stroke")
    }

    /// At the default text size every control is on screen at once — slot chips, Undo, Clear,
    /// Mirror, the whole canvas above the pinned palette, and Next — and the page does not scroll:
    /// a swipe up on the chips leaves the canvas where it was.
    @MainActor
    func testEveryStudioControlIsOnScreenAndThePageDoesNotScroll() {
        let app = launchToStudio()
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let eraser = app.buttons["Eraser"]
        let next = app.buttons["Next"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 10), "the pinned palette is missing")
        XCTAssertTrue(next.exists, "the Next bar is missing")
        let window = app.windows.firstMatch.frame
        let paletteTop = eraser.frame.minY

        let controls = ["Hat", "Face", "Outfit", "Held item", "studio.undo", "studio.clearCanvas", "studio.mirror"]
        for identifier in controls {
            let control = app.buttons[identifier]
            XCTAssertTrue(control.exists, "\(identifier) is missing")
            XCTAssertTrue(window.contains(control.frame), "\(identifier) is off screen: \(control.frame)")
            XCTAssertLessThanOrEqual(control.frame.maxY, paletteTop, "\(identifier) is behind the palette")
        }
        XCTAssertTrue(window.contains(canvas.frame), "the canvas is off screen: \(canvas.frame)")
        XCTAssertLessThanOrEqual(canvas.frame.maxY, paletteTop + 0.5, "the canvas runs under the palette")
        XCTAssertTrue(window.contains(next.frame), "Next is off screen: \(next.frame)")

        let home = canvas.frame
        app.buttons["Outfit"].swipeUp()
        assertInPlace(canvas: canvas, home: home, after: "a swipe up on the slot chips")
        attachScreenshot(of: app, named: "Studio · fitted")
    }

    /// At the largest accessibility text size the slot chips alone outgrow a small iPhone, so the
    /// page falls back to scrolling — but only from the controls around the canvas. A swipe on the
    /// chips brings the whole canvas on screen; strokes on it then leave the page where it is; and
    /// a swipe on the tool row still scrolls back. (On a phone tall enough to fit even at this size
    /// the first swipe moves nothing and the rest still holds.)
    @MainActor
    func testAtTheLargestTextSizeOnlyTheControlsScrollThePage() {
        let app = launchToStudio(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let eraser = app.buttons["Eraser"]
        XCTAssertTrue(eraser.waitForExistence(timeout: 10), "the pinned palette is missing")
        attachScreenshot(of: app, named: "Studio · AX5 · top")
        let unscrolled = canvas.frame.minY

        app.buttons["Hat"].swipeUp()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThanOrEqual(canvas.frame.maxY, eraser.frame.minY + 0.5,
                                 "scrolled to the bottom, the whole canvas should sit above the palette")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(canvas.frame), "the canvas is off screen")
        attachScreenshot(of: app, named: "Studio · AX5 · scrolled to the canvas")

        let home = canvas.frame
        stroke(canvas, from: CGVector(dx: 0.3, dy: 0.88), to: CGVector(dx: 0.3, dy: 0.12))
        assertPaintedInPlace(app, canvas: canvas, home: home, after: "an upward stroke at AX5")
        stroke(canvas, from: CGVector(dx: 0.6, dy: 0.12), to: CGVector(dx: 0.6, dy: 0.88))
        assertInPlace(canvas: canvas, home: home, after: "a downward stroke at AX5")
        attachScreenshot(of: app, named: "Studio · AX5 · after strokes")

        let scrolled = canvas.frame.minY
        guard scrolled < unscrolled - 1 else { return }   // this phone fits even at AX5: nothing to scroll back
        app.buttons["studio.mirror"].swipeDown()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertGreaterThan(canvas.frame.minY, scrolled + 1, "a swipe on the tool row should still scroll the page")
        attachScreenshot(of: app, named: "Studio · AX5 · scrolled back from the tool row")
    }

    // MARK: - Helpers

    /// Customization sheet (opened by the launch hook) → its Creation Studio row → the editor.
    ///
    /// Launched by hand rather than through `UXTestApp.launch`, whose handover check waits for the
    /// Home tab to be hittable — which the customization sheet, open from the first frame, covers.
    /// The handover wait itself is still needed (a tap before the launch overlay leaves is lost),
    /// in its presented-sheet form: the Home tab need only exist.
    ///
    /// `contentSize` forces a Dynamic Type size for this launch only (a `UIContentSizeCategory` raw
    /// value, read from the argument domain), so no simulator setting leaks into other suites.
    @MainActor
    private func launchToStudio(contentSize: String? = nil) -> XCUIApplication {
        UXTestApp.forcePortrait()
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        if let contentSize { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize] }
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_OPEN_CUSTOMIZE"] = "1"
        app.launch()
        UXTestApp.waitForLaunchHandover(app, openSheet: "companion.customize")
        let studioRow = app.buttons["companion.studio"]
        XCTAssertTrue(studioRow.waitForExistence(timeout: 30), "customization sheet did not open with a Creation Studio row")
        XCTAssertTrue(studioRow.isHittable || studioRow.wait(for: \.isHittable, toEqual: true, timeout: 10),
                      "the Creation Studio row never became tappable")
        studioRow.tap()
        XCTAssertTrue(app.descendants(matching: .any)["studio.canvas"].waitForExistence(timeout: 20),
                      "the studio did not open")
        XCTAssertFalse(app.buttons["Next"].isEnabled, "a fresh studio should open blank")
        return app
    }

    /// One real one-finger stroke across `element`, slow enough to sample several cells.
    @MainActor
    private func stroke(_ element: XCUIElement, from: CGVector, to: CGVector) {
        element.coordinate(withNormalizedOffset: from)
            .press(forDuration: 0.05,
                   thenDragTo: element.coordinate(withNormalizedOffset: to),
                   withVelocity: XCUIGestureVelocity(300),
                   thenHoldForDuration: 0.05)
    }

    @MainActor
    private func clearCanvas(in app: XCUIApplication) {
        app.buttons["studio.clearCanvas"].tap()
        XCTAssertFalse(app.buttons["Next"].isEnabled, "Clear canvas should leave the canvas blank")
    }

    @MainActor
    private func assertPaintedInPlace(_ app: XCUIApplication, canvas: XCUIElement, home: CGRect, after action: String) {
        assertInPlace(canvas: canvas, home: home, after: action)
        XCTAssertTrue(app.buttons["Next"].isEnabled, "\(action) did not paint")
    }

    @MainActor
    private func assertInPlace(canvas: XCUIElement, home: CGRect, after action: String) {
        XCTAssertTrue(canvas.exists, "\(action) left the studio")
        XCTAssertEqual(canvas.frame.minY, home.minY, accuracy: 1, "\(action) moved the page or the sheet")
        XCTAssertEqual(canvas.frame.minX, home.minX, accuracy: 1, "\(action) moved the page or the sheet")
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
