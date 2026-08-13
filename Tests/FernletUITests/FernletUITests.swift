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

        app.buttons["activity.row.running"].tap()
        XCTAssertTrue(app.buttons["Save"].isEnabled)
    }

    @MainActor
    func testSettingsMoveTabHasNoFocusTagsSection() throws {
        let app = launchSettingsApp()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 6))
        let moveSettingsButton = app.buttons["settings.move"]
        XCTAssertTrue(moveSettingsButton.waitForExistence(timeout: 3))
        for _ in 0..<6 where !moveSettingsButton.isHittable || moveSettingsButton.frame.midY > app.frame.height * 0.72 {
            app.swipeUp()
        }
        XCTAssertTrue(moveSettingsButton.isHittable)
        moveSettingsButton.tap()

        let fitnessText = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Fitness")).firstMatch
        XCTAssertTrue(fitnessText.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Workout focus tags"].exists)
    }

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
