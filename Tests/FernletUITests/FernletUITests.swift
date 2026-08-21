//
//  FernletUITests.swift
//  FernletUITests
//
//  Created by Michael Bowman on 5/16/26.
//

import XCTest
import FernletDomainModel

final class FernletUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testKindToggleChangesSearchPlaceholder() throws {
        let app = launchCompletedApp()
        openWorkoutSheet(in: app)

        let exerciseSearch = app.textFields["exercise.search"]
        XCTAssertTrue(exerciseSearch.waitForExistence(timeout: 3))
        XCTAssertEqual(exerciseSearch.value as? String, "Search exercise or muscle")

        app.buttons["workout.kind.activity"].tap()
        let activitySearch = app.textFields["activity.search"]
        XCTAssertTrue(activitySearch.waitForExistence(timeout: 3))
        XCTAssertEqual(activitySearch.value as? String, "Search workout type")
    }

    @MainActor
    func testFocusTagFieldNoLongerVisible() throws {
        let app = launchCompletedApp()
        openWorkoutSheet(in: app)

        XCTAssertFalse(app.staticTexts["Focus tag"].exists)
    }

    @MainActor
    func testActivityModeRequiresTypeBeforeSave() throws {
        let app = launchCompletedApp()
        openWorkoutSheet(in: app)

        app.buttons["workout.kind.activity"].tap()
        XCTAssertTrue(app.textFields["activity.search"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Save"].isEnabled)

        // MOVE-10: the everyday types are one-tap chips above the search; picking one collapses
        // the picker to the chosen row (with Change) and seeds a default duration, so Save enables.
        app.buttons["activity.common.running"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["activity.change"].waitForExistence(timeout: 3),
                      "picking a type must collapse the picker to the chosen row with a Change action")
        XCTAssertFalse(app.textFields["activity.search"].exists,
                       "the search must give way to the chosen row once a type is picked")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
    }

    // testSettingsMoveTabHasNoFocusTagsSection was retired with the Settings Move tab itself
    // (SETT-26, 2026-08-21 redesign): the hub row it tapped no longer exists, and its regression —
    // no focus-tags section returning to SettingsSheet — is pinned by MoveRefactorTests' source grep.

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    private func launchCompletedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        app.launch()
        return app
    }

    @MainActor
    private func launchSettingsApp() -> XCUIApplication {
        let app = launchCompletedApp()
        let settingsButton = app.buttons["home.settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 6))
        settingsButton.tap()
        return app
    }

    @MainActor
    private func openWorkoutSheet(in app: XCUIApplication) {
        let moveButton = app.buttons["Move"].firstMatch
        XCTAssertTrue(moveButton.waitForExistence(timeout: 6))
        moveButton.tap()
        let logButton = app.buttons["Log"].firstMatch
        XCTAssertTrue(logButton.waitForExistence(timeout: 4))
        logButton.tap()
        XCTAssertTrue(app.staticTexts["Log workout"].waitForExistence(timeout: 3))
    }

}
