import XCTest
import FernletDomainModel

final class OnboardingFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFullHappyPathThroughAllEightScreens() throws {
        let app = launchOnboardingApp()

        XCTAssertTrue(app.staticTexts["Welcome to Fernlet"].waitForExistence(timeout: 4))
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.staticTexts["Protect private spaces"].waitForExistence(timeout: 2))
        tapButton("onboarding.lock.biometrics", app: app)

        chooseStorage("Just on this device", app: app)
        continueFromGoal(app)
        continueFromStarter(app)
        continueFromPersonalDetails(app)
        continueFromDiet(app)
        finishPermissions(app)

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSkipLockPathCompletesOnboarding() throws {
        let app = launchOnboardingApp()

        app.buttons["Continue"].tap()
        XCTAssertTrue(app.staticTexts["Protect private spaces"].waitForExistence(timeout: 2))
        tapButton("onboarding.lock.skip", app: app)

        chooseStorage("Just on this device", app: app)
        finishRemainingScreens(app)

        XCTAssertTrue(app.buttons["Home"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testICloudSelectionContinuesFlow() throws {
        let app = launchOnboardingApp()

        app.buttons["Continue"].tap()
        tapButton("onboarding.lock.biometrics", app: app)

        chooseStorage("Sync to iCloud", app: app)
        XCTAssertTrue(app.staticTexts["Choose your focus"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testLocalOnlySelectionContinuesFlow() throws {
        let app = launchOnboardingApp()

        app.buttons["Continue"].tap()
        tapButton("onboarding.lock.biometrics", app: app)

        chooseStorage("Just on this device", app: app)
        XCTAssertTrue(app.staticTexts["Choose your focus"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testExistingDataRestorePathUsesDetectedSummary() throws {
        let app = launchOnboardingApp(existingCloudData: true)

        app.buttons["Continue"].tap()
        tapButton("onboarding.lock.biometrics", app: app)

        XCTAssertTrue(app.staticTexts["Restore from iCloud"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '7 meal logs'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '3 journal entries'")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '2 workouts'")).firstMatch.exists)
    }

    @MainActor
    private func launchOnboardingApp(existingCloudData: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-resetOnboarding"]
        app.launchEnvironment["FERNLET_UI_TEST_DISABLE_CLOUD_DETECTION"] = existingCloudData ? "0" : "1"
        if existingCloudData {
            app.launchEnvironment["FERNLET_UI_TEST_EXISTING_CLOUD_DATA"] = "1"
            app.launchEnvironment["FERNLET_UI_TEST_MEAL_LOGS"] = "7"
            app.launchEnvironment["FERNLET_UI_TEST_JOURNAL_ENTRIES"] = "3"
            app.launchEnvironment["FERNLET_UI_TEST_WORKOUTS"] = "2"
        }
        app.launch()
        return app
    }

    @MainActor
    private func chooseStorage(_ title: String, app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Choose where logs live"].waitForExistence(timeout: 4))
        let identifier = title == "Sync to iCloud" ? "onboarding.storage.icloud" : "onboarding.storage.local"
        tapButton(identifier, app: app)
        app.buttons["Continue"].tap()
    }

    @MainActor
    private func tapButton(_ identifier: String, app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        button.tap()
    }

    @MainActor
    private func continueFromGoal(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Choose your focus"].waitForExistence(timeout: 2))
        app.buttons["Continue"].tap()
    }

    @MainActor
    private func continueFromStarter(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Make Fernlet yours"].waitForExistence(timeout: 2))
        app.buttons["Continue"].tap()
    }

    @MainActor
    private func continueFromPersonalDetails(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Add personal details"].waitForExistence(timeout: 2))
        app.buttons["Continue"].tap()
    }

    @MainActor
    private func continueFromDiet(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Pick an eating pattern"].waitForExistence(timeout: 2))
        app.buttons["Continue"].tap()
    }

    @MainActor
    private func finishPermissions(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Permissions when needed"].waitForExistence(timeout: 2))
        app.buttons["Start Fernlet"].tap()
    }

    @MainActor
    private func finishRemainingScreens(_ app: XCUIApplication) {
        continueFromGoal(app)
        continueFromStarter(app)
        continueFromPersonalDetails(app)
        continueFromDiet(app)
        finishPermissions(app)
    }
}
