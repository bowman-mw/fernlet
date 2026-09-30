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
/// customization sheet's Creation Studio row, and real multi-finger timelines through
/// ``MultiTouchSynthesizer`` where one finger is not enough. "Painted" is read off the Next bar,
/// which is enabled only once the canvas holds paint (or off the canvas's own pixels, where Next is
/// already on); "in place" is the canvas card's frame, which moves if the page scrolls or the sheet
/// is dragged and vanishes if the studio is popped.
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
    /// on the ZOOMED canvas — which scrolled the page by 80pt and painted one dot before the fix —
    /// stays put and paints the whole line. "Whole line" is read off the canvas's own pixels: the
    /// Next bar was already enabled by the first stroke, so it cannot tell a line from a dot.
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
        let zoomedShot = canvas.screenshot()
        let zoomed = zoomedShot.image
        XCTAssertNotEqual(zoomedShot.pngRepresentation, before,
                          "pinching the canvas should zoom it — its own recognizers must still work")
        assertInPlace(canvas: canvas, home: home, after: "the pinch")

        stroke(canvas, from: CGVector(dx: 0.4, dy: 0.85), to: CGVector(dx: 0.4, dy: 0.15))
        assertInPlace(canvas: canvas, home: home, after: "an upward stroke on the zoomed canvas")
        let painted = CanvasPixels.changedExtent(from: zoomed, to: canvas.screenshot().image)
        XCTAssertNotNil(painted, "an upward stroke on the zoomed canvas painted nothing")
        XCTAssertGreaterThan(painted?.height ?? 0, 0.5,
                             "an upward stroke across 70% of the zoomed canvas should paint a line, not a dot: \(String(describing: painted))")
        attachScreenshot(of: app, named: "Studio · zoomed stroke")
    }

    /// A second finger may pick a colour while the first is still painting. The canvas makes the
    /// recognizers that could carry a stroke away (the page's scroll, the sheet's drag, the
    /// swipe-back) wait for it; a palette swatch is none of those, so its tap must not wait for a
    /// stroke that never fails (review C-F1, 2026-09-30).
    @MainActor
    func testASecondFingerTapOnASwatchMidStrokeStillPicksTheColour() throws {
        let app = launchToStudio()
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let swatch = app.buttons["Bark"]
        XCTAssertTrue(swatch.waitForExistence(timeout: 10), "the Bark swatch is missing")
        XCTAssertFalse(swatch.isSelected, "the studio should open on the first colour")
        let home = canvas.frame

        try MultiTouchSynthesizer.perform([
            .drag(from: point(canvas, 0.12, 0.5), to: point(canvas, 0.88, 0.5), start: 0, duration: 1.4, steps: 35),
            .tap(at: point(swatch, 0.5, 0.5), at: 0.6),
        ], name: "stroke with a swatch tap")
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(of: app, named: "Studio · swatch tapped mid-stroke")
        assertPaintedInPlace(app, canvas: canvas, home: home, after: "a stroke with a second-finger swatch tap")
        XCTAssertTrue(swatch.isSelected, "a second finger's tap on a swatch mid-stroke was dropped")
    }

    /// A two-finger drag on the UN-zoomed canvas — where the canvas's own two-finger pan has
    /// nothing to scroll and fails — still belongs to the canvas: it neither drags the sheet,
    /// swipes the studio away, nor scrolls the page. (The canvas's touch-owner recognizer.)
    @MainActor
    func testATwoFingerDragOnTheUnzoomedCanvasMovesNothing() throws {
        let app = launchToStudio()
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let home = canvas.frame
        let drags: [(name: String, from: CGVector, to: CGVector, spread: CGVector)] = [
            ("downward (the sheet's drag)", CGVector(dx: 0.5, dy: 0.15), CGVector(dx: 0.5, dy: 0.85), CGVector(dx: 0.15, dy: 0)),
            ("rightward (the swipe-back)", CGVector(dx: 0.15, dy: 0.5), CGVector(dx: 0.85, dy: 0.5), CGVector(dx: 0, dy: 0.15)),
            ("upward (the page's scroll)", CGVector(dx: 0.5, dy: 0.85), CGVector(dx: 0.5, dy: 0.15), CGVector(dx: 0.15, dy: 0)),
        ]
        for drag in drags {
            let fingers = [-1.0, 1.0].map { sign -> MultiTouchSynthesizer.Finger in
                let offset = CGVector(dx: drag.spread.dx * sign, dy: drag.spread.dy * sign)
                return .drag(from: point(canvas, drag.from.dx + offset.dx, drag.from.dy + offset.dy),
                             to: point(canvas, drag.to.dx + offset.dx, drag.to.dy + offset.dy),
                             start: 0, duration: 0.6, steps: 20)
            }
            try MultiTouchSynthesizer.perform(fingers, name: "two-finger \(drag.name) drag")
            Thread.sleep(forTimeInterval: 0.8)
            assertInPlace(canvas: canvas, home: home, after: "a two-finger \(drag.name) drag")
            attachScreenshot(of: app, named: "Studio · after a two-finger \(drag.name) drag")
        }
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

    /// Landscape (the app allows it on iPhone) leaves the page too little height for the fitted
    /// layout (about 160pt on an iPhone 17), so it falls back to scrolling there even at the
    /// default text size — from the controls and margins only. Scrolled to the canvas, the whole
    /// canvas is on screen (it is capped to what the page shows at once), and strokes on it still
    /// never move the page.
    @MainActor
    func testInLandscapeStrokesOnTheCanvasStillLeaveThePageInPlace() {
        let app = launchToStudio()
        defer { UXTestApp.forcePortrait() }
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1.5)
        let canvas = app.descendants(matching: .any)["studio.canvas"]
        let eraser = app.buttons["Eraser"]
        attachScreenshot(of: app, named: "Studio · landscape · top")
        app.buttons["Hat"].swipeUp()
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(of: app, named: "Studio · landscape · scrolled to the canvas")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(canvas.frame),
                      "scrolled to the canvas, the whole canvas should be on screen: \(canvas.frame)")
        XCTAssertLessThanOrEqual(canvas.frame.maxY, eraser.frame.minY + 0.5,
                                 "scrolled to the canvas, none of it should sit under the palette")

        let home = canvas.frame
        stroke(canvas, from: CGVector(dx: 0.3, dy: 0.8), to: CGVector(dx: 0.3, dy: 0.2))
        assertPaintedInPlace(app, canvas: canvas, home: home, after: "an upward stroke in landscape")
        stroke(canvas, from: CGVector(dx: 0.6, dy: 0.2), to: CGVector(dx: 0.6, dy: 0.8))
        assertInPlace(canvas: canvas, home: home, after: "a downward stroke in landscape")
        attachScreenshot(of: app, named: "Studio · landscape · after strokes")
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

    /// The screen point at a normalized offset inside `element`.
    @MainActor
    private func point(_ element: XCUIElement, _ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
        element.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy)).screenPoint
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
        // The screen, not `app.screenshot()`: in landscape the app capture comes back half black.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Reads what a gesture painted off two screenshots of the canvas.
private enum CanvasPixels {
    /// The bounding box of every pixel that differs between `before` and `after`, as fractions of
    /// the image (0…1 on each axis), or nil when nothing changed. Both images come from the same
    /// element, so they share a size; a size mismatch reads as "cannot compare" (nil).
    static func changedExtent(from before: UIImage, to after: UIImage) -> CGRect? {
        guard let old = rgba(before), let new = rgba(after),
              old.width == new.width, old.height == new.height, old.width > 0, old.height > 0 else { return nil }
        var minX = old.width, minY = old.height, maxX = -1, maxY = -1
        for y in 0..<old.height {
            for x in 0..<old.width {
                let index = (y * old.width + x) * 4
                let difference = (0..<3).reduce(0) { $0 + abs(Int(old.bytes[index + $1]) - Int(new.bytes[index + $1])) }
                guard difference > 48 else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let width = CGFloat(old.width), height = CGFloat(old.height)
        return CGRect(x: CGFloat(minX) / width, y: CGFloat(minY) / height,
                      width: CGFloat(maxX - minX + 1) / width, height: CGFloat(maxY - minY + 1) / height)
    }

    /// The image redrawn as tightly packed 8-bit RGBA.
    private static func rgba(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? (bytes, width, height) : nil
    }
}
