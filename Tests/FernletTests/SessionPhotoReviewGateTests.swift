// SessionPhotoReviewGateTests.swift
// FernletTests
//
// Session photos U3 (2026-09-30): `SessionPhotoReviewGate` over its WHOLE input product — eleven
// Booleans and a zero / non-zero outstanding count, 4 096 rows (2 048 until fix round 1 added the
// answer-in-flight leg, U3-C-U3-R1) — in the shape
// `ProximityRunPolicyTests` uses: the product enumerated from a counter so no row can be skipped, a
// flat re-statement compared on every row (its value is catching a guard-order slip), and the rows
// the design names pinned by hand (invariants I9, I10, I13, the `sessionIsLive`,
// `heldPhotosCanBeShown`, `crisisSurfaceUp` and `answerInFlight` legs, and the First Aid mapping —
// owner question Q8).
//
// House rules: `#expect(_, "one literal")`, every `allSatisfy` bound to a `let` first, no rig, no
// clock, no RNG.

import Foundation
import Testing
@testable import Fernlet

/// The gate's input product and its flat re-statement.
enum SessionPhotoReviewGateProduct {

    /// The two counts the gate can tell apart: none outstanding, some outstanding.
    static let counts = [0, 3]

    /// The size of the product: 2 counts × 2¹¹ Booleans.
    static let count = 2 * 2_048

    /// Every row of the product.
    static func rows() -> [SessionPhotoReviewGate.Input] {
        counts.flatMap { outstanding in
            (0..<2_048).map { bits in
                SessionPhotoReviewGate.Input(
                    outstandingPhotoCount: outstanding,
                    sessionIsLive: (bits & 1) != 0,
                    heldPhotosCanBeShown: (bits & 2) != 0,
                    sceneIsActive: (bits & 4) != 0,
                    launchComplete: (bits & 8) != 0,
                    duressSessionActive: (bits & 16) != 0,
                    deleteAllInProgress: (bits & 32) != 0,
                    crisisSurfaceUp: (bits & 64) != 0,
                    cameraDevelopReviewUp: (bits & 128) != 0,
                    deferredByUser: (bits & 256) != 0,
                    isShowing: (bits & 512) != 0,
                    answerInFlight: (bits & 1_024) != 0
                )
            }
        }
    }

    /// One row with named defaults — the review due and nothing in its way, not yet showing.
    static func row(
        count: Int = 3, live: Bool = false, canShow: Bool = true, active: Bool = true,
        launched: Bool = true, duress: Bool = false, wipe: Bool = false, crisis: Bool = false,
        develop: Bool = false, deferred: Bool = false, showing: Bool = false, inFlight: Bool = false
    ) -> SessionPhotoReviewGate.Input {
        SessionPhotoReviewGate.Input(
            outstandingPhotoCount: count, sessionIsLive: live, heldPhotosCanBeShown: canShow,
            sceneIsActive: active, launchComplete: launched, duressSessionActive: duress,
            deleteAllInProgress: wipe, crisisSurfaceUp: crisis, cameraDevelopReviewUp: develop,
            deferredByUser: deferred, isShowing: showing, answerInFlight: inFlight
        )
    }

    /// The verdict, flat: the §4.5 product for `present`, the three step-aside facts for
    /// `hideWithoutAnswer`.
    static func expected(_ r: SessionPhotoReviewGate.Input) -> SessionPhotoReviewGate.Verdict {
        let stepAside = r.duressSessionActive || r.deleteAllInProgress || r.crisisSurfaceUp
        if r.isShowing { return stepAside ? .hideWithoutAnswer : .stayUp }
        let due = r.outstandingPhotoCount > 0 && !r.sessionIsLive && r.heldPhotosCanBeShown
        let clear = r.sceneIsActive && r.launchComplete && !stepAside && !r.cameraDevelopReviewUp && !r.deferredByUser
            && !r.answerInFlight
        return due && clear ? .present : .wait
    }
}

/// The gate, whole.
@Suite struct SessionPhotoReviewGateTests {

    private typealias Product = SessionPhotoReviewGateProduct

    /// The product is the size it says and no dimension collapsed into another.
    @Test func theInputProductIsWholeAndDistinct() {
        let rows = Product.rows()
        #expect(rows.count == Product.count, "every row was built")
        #expect(Set(rows).count == 4_096, "and no two rows are the same input")
    }

    /// The flat re-statement agrees on every row.
    @Test func theFlatStatementAgreesOnEveryRow() {
        let agrees = Product.rows().allSatisfy { SessionPhotoReviewGate.verdict(for: $0) == Product.expected($0) }
        #expect(agrees, "present exactly for the design's product; hide only for duress, delete-all or a crisis surface")
    }

    /// **I9.** `present` is exactly ONE row of the not-showing half per count > 0: every leg is
    /// load-bearing, and flipping any one of them away from its presenting value refuses.
    @Test func presentIsExactlyTheDesignsProduct() {
        let presenting = Product.rows().filter { SessionPhotoReviewGate.verdict(for: $0) == .present }
        #expect(presenting == [Product.row()], "one row presents: due, over, showable, active, launched, nothing in the way")
        let flips: [SessionPhotoReviewGate.Input] = [
            Product.row(count: 0), Product.row(live: true), Product.row(canShow: false),
            Product.row(active: false), Product.row(launched: false), Product.row(duress: true),
            Product.row(wipe: true), Product.row(crisis: true), Product.row(develop: true),
            Product.row(deferred: true), Product.row(inFlight: true),
        ]
        let everyFlipWaits = flips.allSatisfy { SessionPhotoReviewGate.verdict(for: $0) == .wait }
        #expect(everyFlipWaits, "each of the eleven legs, flipped alone, keeps the review down")
    }

    /// The design's named wait legs, one each: never over a live session (the camera is drawn
    /// then), never when the tiles could not load or a reconcile has not run, never over First Aid,
    /// and — fix round 1, U3-C-U3-R1 — never under an answer still in flight.
    @Test func theNamedWaitLegs() {
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(live: true)) == .wait,
                "an awaiting photo arriving mid-session must not pop the review over the live camera")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(canShow: false)) == .wait,
                "the decrypt seam shut, or the wall deferred before the reconcile: the review waits")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(crisis: true)) == .wait,
                "First Aid comes first (Q8): the review waits for it to close")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(develop: true)) == .wait,
                "the camera's own Develop review is answered there first")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(inFlight: true)) == .wait,
                "never under an answer still running: its own hide would take the new review down")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(showing: true, inFlight: true)) == .stayUp,
                "while the review's own answer runs it stays up")
    }

    /// **I13.** Under a duress session the review never presents, whatever else holds, and a
    /// showing one is taken down without an answer.
    @Test func duressNeverPresentsAndHidesAShowingReview() {
        let rows = Product.rows().filter(\.duressSessionActive)
        let neverPresents = rows.allSatisfy { SessionPhotoReviewGate.verdict(for: $0) != .present }
        #expect(neverPresents, "no row under duress presents")
        let showingHides = rows.filter(\.isShowing).allSatisfy { SessionPhotoReviewGate.verdict(for: $0) == .hideWithoutAnswer }
        #expect(showingHides, "and every showing row under duress is taken down, answering nothing")
    }

    /// **I10** (the gate's half): backgrounding, a closed seam, "Not now" and a live session never
    /// take a SHOWING review down — only the three step-aside facts do, and they answer nothing.
    @Test func onlyTheStepAsideFactsHideAShowingReview() {
        let showing = Product.rows().filter(\.isShowing)
        let calm = showing.filter { !$0.duressSessionActive && !$0.deleteAllInProgress && !$0.crisisSurfaceUp }
        let calmStaysUp = calm.allSatisfy { SessionPhotoReviewGate.verdict(for: $0) == .stayUp }
        #expect(calmStaysUp, "a background scene, a shut seam or anything else leaves it up; the snapshot cover does its job")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(active: false, showing: true)) == .stayUp,
                "the app switcher never takes the review down — it draws the cover instead (I18)")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(wipe: true, showing: true)) == .hideWithoutAnswer,
                "a delete-all takes it down")
        #expect(SessionPhotoReviewGate.verdict(for: Product.row(crisis: true, showing: true)) == .hideWithoutAnswer,
                "and so does First Aid opened underneath it (Q8)")
    }

    /// Q8's mapping: First Aid and the stress explainer (which links to it) are crisis surfaces;
    /// no other root sheet is, and no sheet is none.
    @Test func theCrisisSurfacesAreFirstAidAndTheStressExplainer() {
        #expect(SessionPhotoReviewGate.isCrisisSurface(.firstAid(nil)), "First Aid")
        #expect(SessionPhotoReviewGate.isCrisisSurface(.stressExplainer), "the stress explainer")
        #expect(!SessionPhotoReviewGate.isCrisisSurface(.journal), "a journal sheet is covered, never waited for")
        #expect(!SessionPhotoReviewGate.isCrisisSurface(.settings), "nor Settings")
        #expect(!SessionPhotoReviewGate.isCrisisSurface(nil), "and no sheet is no crisis")
    }
}
