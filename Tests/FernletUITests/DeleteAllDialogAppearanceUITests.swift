import XCTest

/// Screenshot the delete-everything confirm sheet into the UX gallery.
///
/// The copy IS the feature here — the bug being fixed was a label that promised more than the code
/// delivered — so the two scannable lists ("This deletes" / "Kept on purpose"), the Apple Health
/// paragraph and the typed gate need to be reviewable as rendered text, not just read in source.
/// Since 2026-08-21 (artboard 5e) the confirm is a typed-gate sheet, not a system alert.
@MainActor
final class DeleteAllDialogAppearanceUITests: XCTestCase {

    func testDeleteEverythingSheetAppearance() {
        let app = UXTestApp.launch(openSheet: "settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "settings sheet did not open")

        let deleteButton = app.descendants(matching: .any)["settings.deleteAll"]
        for _ in 0..<12 where !(deleteButton.exists && deleteButton.isHittable) { app.swipeUp() }
        XCTAssertTrue(deleteButton.isHittable, "delete-everything button not reachable")
        deleteButton.tap()

        let title = app.staticTexts["Delete everything?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no confirm sheet")

        // Both lists render, the typed gate exists, and the confirm starts disabled (opacity,
        // never a red error).
        XCTAssertTrue(app.descendants(matching: .any)["deleteAll.deletesList"].exists, "no deletes list")
        XCTAssertTrue(app.descendants(matching: .any)["deleteAll.keptList"].exists, "no kept-on-purpose list")
        XCTAssertFalse(app.descendants(matching: .any)["deleteAll.confirm"].isEnabled,
                       "the confirm must start disabled")

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Delete everything — confirm sheet"
        shot.lifetime = .keepAlways
        add(shot)

        // Read the rendered copy back into the log so a reviewer can diff the wording without
        // opening the screenshot. (Only what is on screen — the gate below the fold is covered by
        // DeleteAllDataUITests.)
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label)
        print("SHEET_COPY_BEGIN\n\(labels.joined(separator: "\n---\n"))\nSHEET_COPY_END")

        // Cancel is a real, always-rendered button (XCUT-02).
        app.descendants(matching: .any)["sheet.cancel"].tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2), "sheet stayed up after Cancel")
    }
}
