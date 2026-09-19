// MeshContinuationCardUITests.swift
// FernletUITests
//
// Network migration P8 item 7, tier 1b: the Friends tab actually renders the continuation card, and
// the person can read it.
//
// Why a launch hook rather than a driven flow: nothing on a Simulator can produce a real refusal or
// expiry — `BGTaskScheduler` refuses a continued-processing request outright (error 1, plan §15.1),
// and the claim only ever moves from a backgrounded scene. `FERNLET_MESH_CONTINUATION` seeds
// `FernletStore`'s projection at launch through `MeshContinuationCardKind`'s own inverse, so this
// suite exercises the real table, the real copy and the real card — everything but the task.
//
// `MeshNetworkUITests` is skipped wholesale (its mesh lobby was removed from the Friends tab), so
// this is a suite of its own, built on `UXTestApp.launch` for the pinned environment the appearance
// harness already forces (portrait, seeded demo content).

import XCTest

/// The refused / expired continuation cards, on the Friends tab, by identifier.
final class MeshContinuationCardUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A refused claim: iOS gave no background time, so the session lives on the screen.
    @MainActor
    func testRefusedContinuationCardIsOnTheFriendsTab() {
        assertContinuationCard(kind: "refused")
    }

    /// An expired claim: the background time ran out and the session carries on in the foreground.
    @MainActor
    func testExpiredContinuationCardIsOnTheFriendsTab() {
        assertContinuationCard(kind: "expired")
    }

    /// No claim, no card: the non-vacuity half. Without it, the two assertions above would pass on
    /// a surface that showed every card, or on one that showed them unconditionally.
    @MainActor
    func testAnIdleClaimShowsNoContinuationCard() {
        let app = UXTestApp.launch()
        let friendsTab = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friendsTab.waitForExistence(timeout: 30), "the app never reached the tab bar")
        friendsTab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["screen.friends"].waitForExistence(timeout: 10),
                      "the Friends tab never came up")
        // R2: bounded by the three kinds.
        for kind in ["refused", "expired", "endedBySystem"] {
            XCTAssertFalse(app.descendants(matching: .any)["friends.meshContinuation.\(kind)"].exists,
                           "an idle claim showed the \(kind) card")
        }
    }

    /// Launches with the claim seeded, opens Friends, and waits for that kind's card.
    ///
    /// - Parameters:
    ///   - kind: A `MeshContinuationCardKind` rawValue — a frozen token, matching the identifier's
    ///     suffix.
    ///   - file: The calling test's file, for a failure that points at the case.
    ///   - line: The calling test's line.
    @MainActor
    private func assertContinuationCard(
        kind: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = UXTestApp.launch(extraEnvironment: ["FERNLET_MESH_CONTINUATION": kind])
        let friendsTab = app.buttons["Friends"].firstMatch
        XCTAssertTrue(friendsTab.waitForExistence(timeout: 30),
                      "the app never reached the tab bar", file: file, line: line)
        friendsTab.tap()
        let identifier = "friends.meshContinuation.\(kind)"
        let card = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10),
                      "the Friends tab showed no \(identifier) card for a seeded \(kind) claim",
                      file: file, line: line)
    }
}
