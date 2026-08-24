import XCTest

// MARK: - What XCUITest can and cannot observe about the app-lock gate
//
// This file exists to hold up ONE claim that `Docs/Accessibility-Nutrition-Labels.md` §5 makes and
// that had no artifact behind it: **XCUITest queries do not respect `accessibilityHidden`.** That
// claim is load-bearing there, because it is the reason the gate's `.accessibilityHidden` /
// `.isModal` cover is enforced by a grep-wall (`FernletTests/LockGateAccessibilityBoundaryTests`)
// rather than by a runtime test — and a claim about a tool's limits, with no probe behind it, is
// exactly the kind of statement that quietly stops being true.
//
// The measurement was originally taken with a throwaway probe that was deleted in the same batch,
// leaving the document asserting a result nobody could re-run. This is the minimal committed
// version. It is deliberately shaped so that the GOOD outcome — a future iOS honouring the modifier
// in UI-test queries — fails it loudly, with a message saying what to change, rather than passing
// and letting the document keep citing a stale platform behaviour.
//
// The gate reachable from a UI test is the NOT-CONFIGURED one: a fresh simulator has no app-lock
// passcode, so `FernletLockGate` paints `setupCTAOverlay` over the Private hub. That overlay is a
// real gate — it carries `.isModal`, and the content beneath it carries `.accessibilityHidden(true)`
// — so it exercises the same cover the passcode overlay does.

/// Probes what XCUITest can actually see and do through the app lock's gate overlay.
///
/// Not an appearance suite and deliberately not part of the gallery: nothing here captures a
/// screenshot or runs the accessibility audit. Every test is a statement about the TOOL, recorded
/// so the accessibility-nutrition-label document can cite something re-runnable.
final class LockGateObservabilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    /// The Private hub, with the gate NOT bypassed, so the setup call-to-action overlay is up.
    @MainActor
    private func launchGatedPrivateHub() -> XCUIApplication {
        let app = UXTestApp.launch()
        app.buttons["Private"].firstMatch.tap()
        return app
    }

    /// The overlay's own call-to-action button, which is the proof that the gate is actually up.
    @MainActor
    private func setUpButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Set up app lock"].firstMatch
    }

    // MARK: - The claim under test

    /// **XCUITest finds an element that carries `.accessibilityHidden(true)`.**
    ///
    /// The subject is `FernletLockGate.setupCTAOverlay`'s `Image(systemName: "lock.shield")`. It is
    /// purely decorative next to the call-to-action text, so it carries an UNCONDITIONAL
    /// `.accessibilityHidden(true)` — there is no state in which it should be in the accessibility
    /// tree. If an XCUITest query can still see it, then `XCTAssertFalse(someElement.exists)` can
    /// never be a valid test of "this is hidden from assistive technology", which is the whole
    /// consequence recorded in the nutrition-label document.
    ///
    /// The query keys on the SYMBOL NAME appearing in the element's label, which is the second half
    /// of the original finding: XCUITest not only finds the image, it synthesises a label from the
    /// SF Symbol name for an image it should never have been handed. Keying on that is more specific
    /// than "the first image in the window", which would also match status-bar chrome.
    @MainActor
    func testXCUITestSeesElementsHiddenFromAssistiveTechnology() throws {
        let app = launchGatedPrivateHub()
        XCTAssertTrue(
            setUpButton(app).waitForExistence(timeout: 10),
            """
            The not-configured lock gate did not appear over the Private hub, so this probe never \
            reached the thing it measures. Either the demo seed now configures a passcode, or the \
            gate's call-to-action wording changed — fix the probe, do not delete it.
            """
        )

        let hiddenImage = app.descendants(matching: .image)
            .matching(NSPredicate(format: "label CONTAINS[c] 'lock' OR identifier CONTAINS[c] 'lock'"))
            .firstMatch
        let seen = hiddenImage.exists
        let allImages = app.descendants(matching: .image).allElementsBoundByIndex
            .map { "\($0.label)|\($0.identifier)" }
        let attachment = XCTAttachment(string: """
            gate overlay up: \(setUpButton(app).exists)
            image element found despite .accessibilityHidden(true): \(seen)
            its reported label: "\(seen ? hiddenImage.label : "<not found>")"
            its reported identifier: "\(seen ? hiddenImage.identifier : "<not found>")"
            every image element in the tree: \(allImages)
            """)
        attachment.name = "XCUITest vs accessibilityHidden"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(seen, """
            GOOD NEWS, PROBABLY: an XCUITest query no longer finds the gate overlay's decorative \
            `Image(systemName: "lock.shield")`, which carries an unconditional \
            `.accessibilityHidden(true)`. If the platform started honouring the modifier in UI-test \
            queries, then `Docs/Accessibility-Nutrition-Labels.md` §5 is out of date — it currently \
            says XCUITest ignores `accessibilityHidden`, and uses that to justify enforcing the \
            gate's cover by grep-wall alone. Re-take the measurement, update that section, and \
            consider whether the runtime test it abandoned is now writable. (The other possibility \
            is duller: the overlay stopped drawing an image.)
            """)
    }

    /// **A covered control cannot be operated through the gate overlay.**
    ///
    /// The nutrition-label document records that `.isHittable` reported `true` for controls under
    /// the gate, and triages that only as an observability problem. It is worth more than that: if
    /// a covered control were genuinely operable, the gate would be a picture of a lock rather than
    /// a lock. This is the cheapest available check of the safety property itself.
    ///
    /// The subject is the hub's own section picker, which sits INSIDE `.fernletLockGate` (it is a
    /// `safeAreaInset` on the gated `TabView`), so it is covered exactly as the pages are.
    ///
    /// **This test is NOT evidence that the gate blocks touches, and must never be cited as such.**
    /// A reviewer mutation-tested it by removing the overlay's touch blocking outright
    /// (`.allowsHitTesting(false)`) and **it still passed**. The reason is the finding in the test
    /// above: the assertion reads `setUpButton(app).exists`, and `exists` is measured through the
    /// very query mechanism that has just been proven to ignore covering. The gate's call-to-action
    /// is in the tree whether or not it is the thing receiving touches, so this assertion cannot
    /// distinguish "the tap was blocked" from "the tap went through and nothing observable changed".
    ///
    /// What it *does* buy is narrow and worth keeping: it fires if a covered tap causes a visible
    /// navigation that removes the gate's call-to-action from the tree — a whole-screen replacement,
    /// a dismissal, a push. That is a real, if coarse, guard against the loudest form of
    /// passthrough, and it costs one launch.
    ///
    /// **The touch-blocking question itself stays unanswered here and is on the manual device-check
    /// list.** So does the narrower one: whether the paged `TabView` underneath silently changed
    /// page, which XCUITest cannot see for the same reason. Answering either needs a human with a
    /// finger, or an in-process hit-test assertion this harness has no way to make.
    @MainActor
    func testTappingAControlCoveredByTheGateDoesNotOperateIt() throws {
        let app = launchGatedPrivateHub()
        XCTAssertTrue(setUpButton(app).waitForExistence(timeout: 10), "gate overlay never appeared")

        // "New journal entry" is the strongest target available: it is a real covered Button whose
        // action PRESENTS A SHEET, so a working passthrough would be unmistakable on screen rather
        // than a silent page change. "Previous month" is the fallback — it mutates the calendar
        // rather than presenting anything, so it is weaker, but it is still an action.
        //
        // The hub's section picker is deliberately NOT the target: with no passcode configured the
        // sealed Cycle surface resolves hidden, so the picker has one section and does not render.
        // (That inventory is itself worth recording — while the gate is up, XCUITest reports the
        // covered journal's entry button, its month arrows, its six mood chips and all 31 day cells.
        // The cover is doing its job; the query tree simply does not respect it.)
        let candidates = ["New journal entry", "Previous month"]
        guard let covered = candidates.map({ app.buttons[$0].firstMatch }).first(where: { $0.exists }) else {
            // Not a silent pass: the picker is what this probe aims at, and if it is not in the
            // tree the measurement did not happen. Recorded and skipped rather than asserted, so
            // the run says "unmeasured" instead of "fine".
            let inventory = app.buttons.allElementsBoundByIndex.map(\.label)
            throw XCTSkip("""
                None of \(candidates) was in the tree, so the tap-through probe had nothing to aim \
                at. This is UNMEASURED, not passing — the Private hub's section picker may have \
                changed shape. Buttons present: \(inventory)
                """)
        }

        // `tap()` on a non-hittable element raises its own failure, which would report "not
        // hittable" — an outcome this probe wants to MEASURE, not fail on. So the tap goes through a
        // coordinate when the element declines to be hittable: the point is to send a real touch at
        // the covered control's location either way and see what the app does with it.
        let wasHittable = covered.isHittable
        if wasHittable {
            covered.tap()
        } else {
            covered.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        let attachment = XCTAttachment(string: """
            covered control: "\(covered.label)"
            isHittable while the gate overlay is up: \(wasHittable)
            gate still up after tapping it: \(setUpButton(app).exists)
            """)
        attachment.name = "gate tap-through probe"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(setUpButton(app).exists, """
            Tapping a control COVERED by the app-lock gate changed what is on screen — the gate's \
            call-to-action is gone. The gate is supposed to be the only thing a tap can reach while \
            it is up. This is a real touch-passthrough defect, not an observability artifact.
            """)
    }
}
