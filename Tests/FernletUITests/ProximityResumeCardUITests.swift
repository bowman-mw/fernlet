import XCTest

// MARK: - The launch restore's resume card (network migration P7 item 5, pass 2 — tier 1b)
//
// What this suite is for: the three shapes of `ProximityResumeCard` are otherwise UNREACHABLE on one
// device. `offerResume` needs a sealed `MeshSessionContext` inside its six-hour ceiling written by a
// previous run; `couldNotReopen` needs a deliberately corrupted sealed file; `ended` needs a mesh
// that really ended with a peer. So the app carries one walled DEBUG launch switch —
// `FERNLET_MESH_RESUME_PRESENTATION=<token>`, inside the existing `FERNLET_MESH_*` family on
// `MeshMatrixDebugOptions`, compiled out of release entirely — which substitutes ONE fixed
// `ProximityResumePresentation` for the shipping decision and changes nothing else. No mesh is
// seeded, no file is written, no radio is started.
//
// Tokens (`ProximityResumePresentationToken`): `nothing`, `offerResume`, `couldNotReopen`, and
// `ended:<reason>` over `ProximityMeshEndedReason`'s eight at-rest spellings. An unrecognised token
// means "no override", so a typo leaves the shipping decision in place rather than silently picking
// a shape.
//
// What the cells assert is STRUCTURE, never wording: the card's identifier, its headline and second
// line, the actions, and that a dismissal really removes it for the rest of the launch. The
// sentences themselves are pinned verbatim at tier 1 in `ProximityResumeDecisionTests`, where they
// belong — an XCUITest that asserted English would break on the first translation.
//
// ENVIRONMENT: this suite is pinned to the **iPhone 17 simulator in PORTRAIT**, per the round's
// launcher, and `UXTestApp.launch` forces the orientation because simulator rotation is host state
// that drifts between runs.
//
// NOT RUN BY THE LANDING SESSION: there is no Swift toolchain in the environment this suite was
// written in, so nothing here has been compiled or executed. It is offered as written, and the first
// run of the round's gauntlet is what proves it.

final class ProximityResumeCardUITests: XCTestCase {

    // MARK: - Frozen identifiers (mirrors ProximityResumeCardIdentifiers)

    /// The card itself, whichever shape it took.
    private static let card = "friends.resume"

    /// The headline.
    private static let title = "friends.resume.title"

    /// The second line.
    private static let body = "friends.resume.body"

    /// The accept pill — the offer's only.
    private static let accept = "friends.resume.accept"

    /// The decline pill (offer) or the close control (the two notices).
    private static let dismiss = "friends.resume.dismiss"

    /// The launch switch that forces one presentation.
    private static let presentationKey = "FERNLET_MESH_RESUME_PRESENTATION"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches with one forced presentation and lands on the Friends tab.
    ///
    /// - Parameter token: The `FERNLET_MESH_RESUME_PRESENTATION` value.
    /// - Returns: the launched app, already on the Friends tab.
    @MainActor
    private func launchOnFriends(_ token: String) -> XCUIApplication {
        let app = UXTestApp.launch(extraEnvironment: [Self.presentationKey: token])
        let friends = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 10), "the Friends tab button never appeared")
        friends.tap()
        return app
    }

    /// The card element, whatever kind of element XCUI decides it is.
    ///
    /// - Parameter app: The launched app.
    /// - Returns: the query for the card's frozen identifier.
    @MainActor
    private func cardElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[Self.card]
    }

    // MARK: - The offer

    /// `offerResume` shows the card, both sentences, and both actions.
    @MainActor
    func testOfferResumeShowsTheCardWithBothActions() throws {
        let app = launchOnFriends("offerResume")
        XCTAssertTrue(cardElement(in: app).waitForExistence(timeout: 10),
                      "the resume card did not appear on the Friends tab")
        XCTAssertTrue(app.descendants(matching: .any)[Self.title].waitForExistence(timeout: 5),
                      "the offer has no headline")
        XCTAssertTrue(app.descendants(matching: .any)[Self.body].waitForExistence(timeout: 5),
                      "the offer has no second line")
        XCTAssertTrue(app.buttons[Self.accept].waitForExistence(timeout: 5),
                      "the offer has no accept action")
        XCTAssertTrue(app.buttons[Self.dismiss].waitForExistence(timeout: 5),
                      "the offer has no decline action")
    }

    /// Declining the offer takes the card away for the rest of the launch.
    @MainActor
    func testDecliningTheOfferRemovesTheCard() throws {
        let app = launchOnFriends("offerResume")
        let decline = app.buttons[Self.dismiss]
        XCTAssertTrue(decline.waitForExistence(timeout: 10), "the decline action never appeared")
        decline.tap()
        let gone = cardElement(in: app).waitForNonExistence(timeout: 5)
        XCTAssertTrue(gone, "the card survived its own dismissal")
    }

    // MARK: - The two notices

    /// `couldNotReopen` shows a notice with a close control and no accept action.
    @MainActor
    func testCouldNotReopenShowsANoticeWithNoResumeAction() throws {
        let app = launchOnFriends("couldNotReopen")
        XCTAssertTrue(cardElement(in: app).waitForExistence(timeout: 10),
                      "the could-not-reopen notice did not appear")
        XCTAssertTrue(app.descendants(matching: .any)[Self.title].waitForExistence(timeout: 5),
                      "the notice has no headline")
        XCTAssertTrue(app.descendants(matching: .any)[Self.body].waitForExistence(timeout: 5),
                      "the notice has no second line — and the second line is the reassurance")
        XCTAssertFalse(app.buttons[Self.accept].exists,
                       "a file that did not decode must never be offered as a resume")
        XCTAssertTrue(app.buttons[Self.dismiss].exists, "the notice has no close control")
    }

    /// Dismissing the could-not-reopen notice takes it away for the rest of the launch.
    @MainActor
    func testDismissingTheCouldNotReopenNoticeRemovesIt() throws {
        let app = launchOnFriends("couldNotReopen")
        let close = app.buttons[Self.dismiss]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the close control never appeared")
        close.tap()
        XCTAssertTrue(cardElement(in: app).waitForNonExistence(timeout: 5),
                      "the notice survived its own dismissal")
    }

    /// One `ended` reason renders and dismisses like the other notice.
    ///
    /// `own-departure` is the reason chosen because it is the one a single device can reach for
    /// itself — the user left — so the shape under test is the one a tester meets first.
    @MainActor
    func testEndedNoticeShowsAndDismisses() throws {
        let app = launchOnFriends("ended:own-departure")
        XCTAssertTrue(cardElement(in: app).waitForExistence(timeout: 10),
                      "the ended notice did not appear")
        XCTAssertTrue(app.descendants(matching: .any)[Self.title].waitForExistence(timeout: 5),
                      "the ended notice has no headline")
        XCTAssertTrue(app.descendants(matching: .any)[Self.body].waitForExistence(timeout: 5),
                      "the ended notice does not say WHY it ended")
        XCTAssertFalse(app.buttons[Self.accept].exists,
                       "a mesh this device may never re-enter is never offered as a resume")
        let close = app.buttons[Self.dismiss]
        XCTAssertTrue(close.exists, "the ended notice has no close control")
        close.tap()
        XCTAssertTrue(cardElement(in: app).waitForNonExistence(timeout: 5),
                      "the ended notice survived its own dismissal")
    }

    // MARK: - Silence

    /// `nothing` renders no card at all — the absence is the claim.
    ///
    /// This is the cell that keeps the other four honest: without it they would pass just as well
    /// against a card that is always up, and "a deferred restore says nothing" is a positive claim
    /// of the decisions table rather than an omission.
    @MainActor
    func testNothingPresentsNoCardAtAll() throws {
        let app = launchOnFriends("nothing")
        XCTAssertTrue(app.descendants(matching: .any)["screen.friends"].waitForExistence(timeout: 10),
                      "the Friends surface never rendered, so the absence below proves nothing")
        XCTAssertFalse(cardElement(in: app).exists, "a silent restore drew a card")
        XCTAssertFalse(app.buttons[Self.accept].exists, "and offered a resume")
        XCTAssertFalse(app.buttons[Self.dismiss].exists, "and something to dismiss")
    }
}
