import XCTest

/// A long flight history in Sprout's passport (World-Airports-Spec §8; owner 2026-11-02, 178 imported flights had made
/// 30 pages): the DEBUG `flightsMany` scene's 178 made-up flights take one Flights page, whose years open their logs,
/// and VoiceOver's names for it all read sensibly.
final class PassportFlightsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches straight into the scene: `UXTestApp.launch` waits for a hittable Home tab, which the open book covers.
    @MainActor
    private func openFlightsPage() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["FERNLET_UI_TEST_SEED_DEMO"] = "1"
        app.launchEnvironment["FERNLET_UI_TEST_PASSPORT_BOOK"] = "flightsMany"
        app.launch()
        XCTAssertTrue(row(2024, in: app).waitForExistence(timeout: UXTestApp.launchHandoverTimeout),
                      "the Flights page did not list its years")
        return app
    }

    private func row(_ year: Int, in app: XCUIApplication) -> XCUIElement {
        app.buttons["passport.flights.year.\(year)"]
    }

    /// The first element whose VoiceOver label starts with `prefix`.
    private func element(labelled prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    /// The sample book has three stamp pages, so 178 flights make it seven pages: the Flights page is the sixth.
    @MainActor
    func testLongHistoryIsOnePageOfYears() {
        let app = openFlightsPage()
        XCTAssertTrue(app.buttons["passport.contents"].label.hasPrefix("Page 6 of 7, Flights"), app.buttons["passport.contents"].label)
        // The made-up history runs to December 2026, so how many of the 178 are flown yet depends on today's date.
        let heading = app.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES %@", "^1[0-9]{2} flights, .*")).firstMatch
        XCTAssertTrue(heading.exists, "the page's heading doesn't read its totals")
        XCTAssertTrue(row(2024, in: app).label.hasPrefix("2024, 23 flights, "), row(2024, in: app).label)
        XCTAssertTrue(row(2026, in: app).frame.minY < row(2024, in: app).frame.minY, "the newest year comes first")
        XCTAssertTrue(app.buttons["passport.flights.addPast"].exists, "Add past flights is gone from the page")
    }

    /// A year opens its log with its heading and stubs; the bar steps to the next year and back returns to the list.
    @MainActor
    func testYearOpensAndStepsAndComesBack() {
        let app = openFlightsPage()
        row(2024, in: app).tap()

        let back = app.buttons["Back to Flights"]
        XCTAssertTrue(back.waitForExistence(timeout: 6), "the year's log did not open")
        XCTAssertTrue(element(labelled: "2024, 23 flights, ", in: app).exists, "the log's heading doesn't read the year")
        let stub = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", " 2024, ", ", imported")).firstMatch
        XCTAssertTrue(stub.exists, "a stub doesn't read its place, date and tag")

        app.buttons["Older year"].tap()
        XCTAssertTrue(element(labelled: "2023, 19 flights, ", in: app).waitForExistence(timeout: 6), "the bar did not step to 2023")

        back.tap()
        XCTAssertTrue(row(2024, in: app).waitForExistence(timeout: 6), "back did not return to the years")
        XCTAssertFalse(app.buttons["Older year"].exists, "the page bar did not come back")
    }
}
