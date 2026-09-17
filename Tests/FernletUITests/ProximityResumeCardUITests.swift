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
//
// NOT RUN BY CI EITHER: `FernletUITests` is named in no workflow — `.github/workflows` holds
// `pages.yml`, `power-of-10.yml` and `s3-wall.yml`, and none of them mentions it — so this suite
// runs exactly when somebody runs it from a Mac session, and never on a push.

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

    /// The Friends album surface's own header — "the surface is up", as `ScreenHeader` publishes it.
    private static let screen = "screen.friends"

    /// The disposable camera's shutter: the element that exists only while the in-session surface
    /// has replaced the album (`DisposableCameraView`).
    private static let shutter = "camera.shutter"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Launches with one forced presentation and lands on the Friends tab.
    ///
    /// **It waits for the surface, not just for the tap.** The tab button existing says the tab bar
    /// rendered; it says nothing about the Friends surface having drawn, and every assertion below
    /// is about something on that surface — an absence cell would pass against a screen that had not
    /// appeared yet. `screen.friends` is the album layout's own `ScreenHeader` identifier, which is
    /// what the silence cell already anchors on.
    ///
    /// - Parameter token: The `FERNLET_MESH_RESUME_PRESENTATION` value.
    /// - Returns: the launched app, already on the Friends tab, with its surface up.
    @MainActor
    private func launchOnFriends(_ token: String) -> XCUIApplication {
        let app = UXTestApp.launch(extraEnvironment: [Self.presentationKey: token])
        let friends = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friends.waitForExistence(timeout: 10), "the Friends tab button never appeared")
        friends.tap()
        let screen = app.descendants(matching: .any)[Self.screen]
        XCTAssertTrue(screen.waitForExistence(timeout: 10),
                      "the Friends surface never rendered, so nothing asserted about it means anything")
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
    ///
    /// **And the silence must not cost the tab its search** (P7 post-close review, P2-1). This is
    /// the one launch where the two rules could disagree: the override forces `.nothing`, so no card
    /// is drawn — while a simulator whose container still holds a sealed context inside its ceiling
    /// raises a REAL `offersForegroundResume` behind it, and that flag holds the mesh seam's fresh
    /// search (`ProximityRunStateSeam.resumeOffered`). Before the fix the two together were a
    /// Friends tab that could never look for anyone, with nothing on screen to release it.
    /// `FriendsView.releaseTheHeldSearchIfTheCardSaysNothing()` declines the standing offer through
    /// the card's own dismiss path and re-pushes the policy, so the ordinary search arms instead.
    ///
    /// **What is asserted, and why it is the weaker pair.** Nothing on this surface publishes the
    /// search state under an identifier — the "Looking for nearby friends…" pulse carries none, and
    /// asserting its English would break on the first translation, which this suite's header
    /// forbids. Nor could a pulse be required: the simulator may have no Local Network permission,
    /// in which case the discovery-failure banner is the honest render. So the pair pinned is the
    /// one that is true on every device: the card is absent, AND the tab is still a usable tab —
    /// its surface up and its floating tab bar there to leave by, which is the same "the tab is
    /// drawing something and can be left" invariant ``testAcceptingTheOfferNeverStrandsTheFriendsTab()``
    /// rests on. A held search is invisible here; a strand or a vanished tab bar is not.
    @MainActor
    func testNothingPresentsNoCardAtAll() throws {
        let app = launchOnFriends("nothing")
        XCTAssertTrue(app.descendants(matching: .any)[Self.screen].exists,
                      "the Friends surface never rendered, so the absence below proves nothing")
        XCTAssertFalse(cardElement(in: app).exists, "a silent restore drew a card")
        XCTAssertFalse(app.buttons[Self.accept].exists, "and offered a resume")
        XCTAssertFalse(app.buttons[Self.dismiss].exists, "and something to dismiss")
        XCTAssertFalse(app.descendants(matching: .any)[Self.shutter].exists, """
            a silent restore adopted a session: the camera surface is up over a launch that was \
            never offered one
            """)
        XCTAssertTrue(app.buttons["Friends"].firstMatch.exists, """
            the album is up with no tab bar under it: the tab cannot be left, and a search held \
            behind a card nobody can see would be held for the rest of the launch
            """)
    }

    // MARK: - The accept

    /// Tapping the accept pill leaves this tab USABLE — the strand negative (pass 2 fix review,
    /// P1-1).
    ///
    /// **What this override can and cannot drive, stated plainly.**
    /// `FERNLET_MESH_RESUME_PRESENTATION` substitutes the whole decision, so the card's shape here
    /// is forced rather than derived — and, more to the point, the launch it forces has no sealed
    /// context and no standing offer behind it, so the manager's real door
    /// (`acceptForegroundResume(now:)`) refuses this tap at its first guard and adopts nothing. A
    /// REAL accept therefore cannot be driven from here at all: it needs a sealed
    /// `MeshSessionContext` inside its six-hour ceiling, written by a previous run, which is the
    /// thing this whole suite exists because a single device cannot make.
    ///
    /// So what is pinned is the INVARIANT, which holds whichever way the tap went — and it has to
    /// be written that way, because the simulator's container is not reset between runs: a sealed
    /// context left inside its ceiling by an earlier run would make this tap a real accept. Either
    /// the camera surface is up (the resume was adopted, and `sessionReady` rose with it), or it is
    /// not and the album is still the album, with the floating tab bar still there to leave by.
    /// The strand is exactly the third state — camera chrome, no camera, no tab bar — and it is the
    /// one this cell forbids.
    ///
    /// The card itself is not asserted about: under the override the presentation is a constant, so
    /// it stays up whatever the door answered. In shipping the projection takes it down
    /// (`offersForegroundResume` is spent) or replaces it with the ended notice (a barred try raises
    /// the hit); both are pinned at tier 1 in `ProximityResumeDecisionTests`, where a sealed context
    /// is one line.
    @MainActor
    func testAcceptingTheOfferNeverStrandsTheFriendsTab() throws {
        let app = launchOnFriends("offerResume")
        let accept = app.buttons[Self.accept]
        XCTAssertTrue(accept.waitForExistence(timeout: 10), "the accept action never appeared")
        accept.tap()
        let cameraCameUp = app.descendants(matching: .any)[Self.shutter].waitForExistence(timeout: 5)
        if cameraCameUp {
            XCTAssertFalse(app.descendants(matching: .any)[Self.screen].exists, """
                the camera surface and the album are both up, so the Social tab is drawing two \
                session states at once
                """)
        } else {
            XCTAssertTrue(app.descendants(matching: .any)[Self.screen].exists,
                          "no camera came up and the album is gone: the tab is drawing nothing at all")
            XCTAssertTrue(app.buttons["Friends"].firstMatch.exists, """
                the tab bar is gone with no camera to justify it — the Social tab took the camera \
                chrome (ContentView drops the bar on `isInSession`) over the album, with no way back
                """)
        }
    }
}
