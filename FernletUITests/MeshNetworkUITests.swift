import XCTest

// MARK: - Mesh Network UI Test Suite
//
// Covers Phase 2 interaction scenarios and closed-mode discovery/admission behavior:
//   Phase 2 · Join          – starting a new mesh shows the detail view
//   Phase 2 · Rejoin        – leaving and re-entering a mesh returns to idle then detail
//   Phase 2 · Blocked fwd   – blocking a member surfaces the confirmation UI gate
//   Phase 2 · Closed adv.   – switching mode to Closed updates the segmented picker
//   Phase 2 · Manifest sync – mesh detail always exposes the Shared pictures section
//   Closed-mode discovery   – closed mesh hides rename affordance, open mesh shows it
//   Admission behavior      – pending request sheet appears; Allow/Decline each dismiss it
//
// Environment variables (set in launchEnvironment before launch):
//   FERNLET_UI_TEST_MESH_OPEN      – inject a pre-built open mesh into MeshNetworkManager
//   FERNLET_UI_TEST_MESH_CLOSED    – inject a pre-built closed mesh into MeshNetworkManager
//   FERNLET_UI_TEST_MESH_ADMISSION – inject an open mesh + one pending admission request
//
// Launch arguments:
//   -completeOnboarding  – skip onboarding and land on the main screen

final class MeshNetworkUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Phase 2 · Join

    /// Tapping "Start new mesh" transitions the lobby from idle to the mesh detail view.
    @MainActor
    func testJoin_startNewMeshShowsDetailView() throws {
        let app = launchMeshLobby()
        XCTAssertTrue(app.buttons["mesh.lobby.start"].waitForExistence(timeout: 4))

        app.buttons["mesh.lobby.start"].tap()

        XCTAssertTrue(
            app.scrollViews["mesh.detail"].waitForExistence(timeout: 4),
            "Expected mesh detail scroll view after starting a new mesh"
        )
    }

    /// The detail view after joining contains the mode picker, shared-pictures section,
    /// and the leave button.
    @MainActor
    func testJoin_detailViewShowsExpectedControls() throws {
        let app = launchMeshLobby()
        XCTAssertTrue(app.buttons["mesh.lobby.start"].waitForExistence(timeout: 4))
        app.buttons["mesh.lobby.start"].tap()

        XCTAssertTrue(app.scrollViews["mesh.detail"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.segmentedControls["mesh.detail.mode"].waitForExistence(timeout: 3),
            "Expected mode picker in mesh detail"
        )
        XCTAssertTrue(
            app.staticTexts["Shared pictures"].waitForExistence(timeout: 3),
            "Expected 'Shared pictures' section header"
        )
        XCTAssertTrue(
            app.buttons["mesh.detail.leave"].waitForExistence(timeout: 3),
            "Expected Leave mesh button"
        )
    }

    // MARK: - Phase 2 · Rejoin

    /// Confirming "Leave mesh" returns the lobby to the idle state.
    @MainActor
    func testRejoin_leaveConfirmationRestoresIdleView() throws {
        let app = launchMeshLobby()
        XCTAssertTrue(app.buttons["mesh.lobby.start"].waitForExistence(timeout: 4))
        app.buttons["mesh.lobby.start"].tap()

        XCTAssertTrue(app.buttons["mesh.detail.leave"].waitForExistence(timeout: 4))
        app.buttons["mesh.detail.leave"].tap()
        app.buttons["Leave"].tap()

        XCTAssertTrue(
            app.scrollViews["mesh.lobby.idle"].waitForExistence(timeout: 4),
            "Expected idle lobby view after leaving the mesh"
        )
        XCTAssertTrue(
            app.buttons["mesh.lobby.start"].waitForExistence(timeout: 3),
            "Expected 'Start new mesh' button visible after leaving"
        )
    }

    /// After leaving a mesh, a second "Start new mesh" tap enters a new mesh detail view.
    @MainActor
    func testRejoin_canStartMeshAgainAfterLeaving() throws {
        let app = launchMeshLobby()
        XCTAssertTrue(app.buttons["mesh.lobby.start"].waitForExistence(timeout: 4))
        app.buttons["mesh.lobby.start"].tap()

        XCTAssertTrue(app.buttons["mesh.detail.leave"].waitForExistence(timeout: 4))
        app.buttons["mesh.detail.leave"].tap()
        app.buttons["Leave"].tap()

        XCTAssertTrue(app.buttons["mesh.lobby.start"].waitForExistence(timeout: 4))
        app.buttons["mesh.lobby.start"].tap()

        XCTAssertTrue(
            app.scrollViews["mesh.detail"].waitForExistence(timeout: 4),
            "Expected mesh detail view after rejoining"
        )
    }

    // MARK: - Phase 2 · Blocked forwarding

    /// Tapping an injected mesh member surfaces the "Block" confirmation dialog, which
    /// is the UI gate that drives shouldAcceptInvitation / photo-forwarding prevention.
    @MainActor
    func testBlockedForwarding_blockMemberDialogAppearsFromMeshDetail() throws {
        let app = launchMeshLobby(meshOpen: true)

        XCTAssertTrue(app.scrollViews["mesh.detail"].waitForExistence(timeout: 4))

        // The injected member's button carries the fingerprint-based identifier.
        let memberButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'mesh.member.'"))
            .firstMatch
        XCTAssertTrue(
            memberButton.waitForExistence(timeout: 3),
            "Expected at least one member button in the detail view"
        )
        memberButton.tap()

        XCTAssertTrue(
            app.buttons["Block Test Host"].waitForExistence(timeout: 3),
            "Expected destructive 'Block Test Host' action in the confirmation dialog"
        )
    }

    // MARK: - Phase 2 · Closed advertising

    /// Tapping "Closed" in the mode segmented picker switches the selection.
    @MainActor
    func testClosedAdvertising_switchModeToClosedUpdatesSegment() throws {
        let app = launchMeshLobby(meshOpen: true)

        XCTAssertTrue(app.segmentedControls["mesh.detail.mode"].waitForExistence(timeout: 4))
        let modePicker = app.segmentedControls["mesh.detail.mode"]

        modePicker.buttons["Closed"].tap()

        XCTAssertTrue(
            modePicker.buttons["Closed"].isSelected,
            "Expected 'Closed' segment to be selected after tapping it"
        )
    }

    /// Switching to Closed mode removes the rename (pencil) affordance.
    @MainActor
    func testClosedAdvertising_switchToClosedHidesRenameButton() throws {
        let app = launchMeshLobby(meshOpen: true)

        XCTAssertTrue(app.buttons["mesh.detail.rename"].waitForExistence(timeout: 4),
                      "Expected rename button before switching to Closed")

        app.segmentedControls["mesh.detail.mode"].buttons["Closed"].tap()

        XCTAssertTrue(
            app.buttons["mesh.detail.rename"].waitForNonExistence(timeout: 3),
            "Expected rename button to disappear after switching to Closed mode"
        )
    }

    /// An injected closed mesh has the Closed segment selected on first render.
    @MainActor
    func testClosedAdvertising_injectedClosedMeshShowsClosedSegment() throws {
        let app = launchMeshLobby(meshClosed: true)

        XCTAssertTrue(app.segmentedControls["mesh.detail.mode"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.segmentedControls["mesh.detail.mode"].buttons["Closed"].isSelected,
            "Expected 'Closed' segment selected for injected closed mesh"
        )
    }

    // MARK: - Phase 2 · Manifest sync

    /// The mesh detail view always contains the "Shared pictures" section header,
    /// confirming the manifest-sync UI surface is wired up regardless of photo count.
    @MainActor
    func testManifestSync_meshDetailContainsSharedPicturesSection() throws {
        let app = launchMeshLobby(meshOpen: true)

        XCTAssertTrue(app.scrollViews["mesh.detail"].waitForExistence(timeout: 4))
        XCTAssertTrue(
            app.staticTexts["Shared pictures"].waitForExistence(timeout: 3),
            "Expected 'Shared pictures' section header for manifest sync"
        )
    }

    // MARK: - Closed-mode discovery: rename affordance

    /// A closed mesh does not show the rename button.
    @MainActor
    func testClosedMode_renameButtonAbsent() throws {
        let app = launchMeshLobby(meshClosed: true)

        XCTAssertTrue(app.scrollViews["mesh.detail"].waitForExistence(timeout: 4))
        XCTAssertFalse(
            app.buttons["mesh.detail.rename"].exists,
            "Expected rename button to be absent for a closed mesh"
        )
    }

    /// An open mesh shows the rename button with the pencil affordance.
    @MainActor
    func testOpenMode_renameButtonPresent() throws {
        let app = launchMeshLobby(meshOpen: true)

        XCTAssertTrue(
            app.buttons["mesh.detail.rename"].waitForExistence(timeout: 4),
            "Expected rename button for an open mesh"
        )
    }

    // MARK: - Admission behavior

    /// A pending admission request for the current mesh presents the prompt sheet
    /// with both Allow and Decline buttons and the requester's display name.
    @MainActor
    func testAdmission_pendingRequestPresentsSheet() throws {
        let app = launchMeshLobby(admission: true)

        XCTAssertTrue(
            app.buttons["mesh.admission.allow"].waitForExistence(timeout: 6),
            "Expected Allow button in admission prompt sheet"
        )
        XCTAssertTrue(
            app.buttons["mesh.admission.decline"].exists,
            "Expected Decline button in admission prompt sheet"
        )
        XCTAssertTrue(
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS[c] 'Alice'"))
                .firstMatch
                .exists,
            "Expected requester name 'Alice' in admission sheet body"
        )
    }

    /// Tapping Decline removes the pending request and dismisses the admission sheet.
    @MainActor
    func testAdmission_declineRequestDismissesSheet() throws {
        let app = launchMeshLobby(admission: true)

        XCTAssertTrue(app.buttons["mesh.admission.decline"].waitForExistence(timeout: 6))
        app.buttons["mesh.admission.decline"].tap()

        XCTAssertTrue(
            app.buttons["mesh.admission.decline"].waitForNonExistence(timeout: 3),
            "Expected admission sheet to dismiss after Decline"
        )
        XCTAssertTrue(
            app.scrollViews["mesh.detail"].waitForExistence(timeout: 3),
            "Expected mesh detail visible after dismissing admission sheet"
        )
    }

    /// Tapping Allow removes the pending request and dismisses the admission sheet.
    @MainActor
    func testAdmission_allowRequestDismissesSheet() throws {
        let app = launchMeshLobby(admission: true)

        XCTAssertTrue(app.buttons["mesh.admission.allow"].waitForExistence(timeout: 6))
        app.buttons["mesh.admission.allow"].tap()

        XCTAssertTrue(
            app.buttons["mesh.admission.allow"].waitForNonExistence(timeout: 3),
            "Expected admission sheet to dismiss after Allow"
        )
        XCTAssertTrue(
            app.scrollViews["mesh.detail"].waitForExistence(timeout: 3),
            "Expected mesh detail visible after admitting requester"
        )
    }

    // MARK: - Helpers

    /// Launches the app and navigates to the Social → Meshes section.
    @MainActor
    private func launchMeshLobby(
        meshOpen: Bool = false,
        meshClosed: Bool = false,
        admission: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-completeOnboarding"]
        if meshOpen  { app.launchEnvironment["FERNLET_UI_TEST_MESH_OPEN"]      = "1" }
        if meshClosed { app.launchEnvironment["FERNLET_UI_TEST_MESH_CLOSED"]   = "1" }
        if admission  { app.launchEnvironment["FERNLET_UI_TEST_MESH_ADMISSION"] = "1" }
        app.launch()
        navigateToMeshes(app)
        return app
    }

    /// Taps the Social ("Life") tab, then the "Meshes" section picker button.
    @MainActor
    private func navigateToMeshes(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 8),
                      "App did not reach home screen in time")
        app.buttons["Life"].tap()
        let meshesTab = app.buttons["Meshes"].firstMatch
        XCTAssertTrue(meshesTab.waitForExistence(timeout: 4))
        meshesTab.tap()
    }
}
