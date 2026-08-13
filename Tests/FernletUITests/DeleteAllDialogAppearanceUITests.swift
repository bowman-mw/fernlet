import XCTest

/// Screenshot the delete-everything confirm dialog into the UX gallery.
///
/// The copy IS the feature here — the bug being fixed was a label that promised more than the code
/// delivered — so the dialog needs to be reviewable as rendered text, not just read in source. Alert
/// bodies are also where wording problems hide: what reads fine in a Swift multi-line literal can arrive
/// as a wall of text on a 375pt screen.
@MainActor
final class DeleteAllDialogAppearanceUITests: XCTestCase {

    func testDeleteEverythingDialogAppearance() {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "settings sheet did not open")

        let deleteButton = app.descendants(matching: .any)["settings.deleteAll"]
        for _ in 0..<12 where !(deleteButton.exists && deleteButton.isHittable) { app.swipeUp() }
        XCTAssertTrue(deleteButton.isHittable, "delete-everything button not reachable")
        deleteButton.tap()

        let alert = app.alerts["Delete everything?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "no confirm dialog")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Delete everything — confirm dialog"
        shot.lifetime = .keepAlways
        add(shot)

        // Read the rendered copy back into the log so a reviewer can diff the wording without opening
        // the screenshot.
        let labels = alert.staticTexts.allElementsBoundByIndex.map(\.label)
        print("DIALOG_COPY_BEGIN\n\(labels.joined(separator: "\n---\n"))\nDIALOG_COPY_END")
        print("DIALOG_BUTTONS: \(alert.buttons.allElementsBoundByIndex.map(\.label))")

        alert.buttons["Cancel"].tap()
    }
}
