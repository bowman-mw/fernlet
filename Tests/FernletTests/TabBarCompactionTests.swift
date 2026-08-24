import Testing
import CoreGraphics
@testable import Fernlet
import FernletUI

/// Decision-logic tests for the bottom tab bar's compaction hysteresis
/// (`FernletTabBarCompactionModifier.shouldCompact`). Pure function — no UI, no scroll view.
///
/// The bug this guards (tester #10): the old single-threshold gate flipped compact⇄expand forever
/// because the compacting tab bar's own animated bottom inset swung the scroll view's visible
/// region back across the same threshold. The fix measures distance-scrolled-past-top (inset
/// invariant) and adds an 8…48 dead band so no single value can oscillate.
@Suite struct TabBarCompactionTests {

    private func decide(isCompact: Bool, _ distance: CGFloat) -> Bool {
        FernletTabBarCompactionModifier.shouldCompact(isCompact: isCompact, distanceScrolledPastTop: distance)
    }

    // MARK: - Entering compaction (from expanded)

    @Test func staysExpandedBelowEnterThreshold() {
        // Only real downward travel past 48pt may compact; a barely-scrolled or unscrollable
        // screen stays expanded.
        #expect(decide(isCompact: false, 0) == false)
        #expect(decide(isCompact: false, 8) == false)
        #expect(decide(isCompact: false, 47) == false)
        #expect(decide(isCompact: false, 48) == false)   // strictly greater than
    }

    @Test func entersCompactOnlyPastEnterThreshold() {
        #expect(decide(isCompact: false, 49) == true)
        #expect(decide(isCompact: false, 200) == true)
    }

    @Test func unscrollableContentCannotCompact() {
        // Negative / near-zero distance (rubber-band or no overflow) never compacts.
        #expect(decide(isCompact: false, -20) == false)
        #expect(decide(isCompact: false, 0) == false)
    }

    // MARK: - Leaving compaction (from compact)

    @Test func staysCompactWithinDeadBand() {
        // Once compact, everything in the old oscillation band (8…48) holds compact — no flip.
        #expect(decide(isCompact: true, 9) == true)
        #expect(decide(isCompact: true, 24) == true)   // the old single threshold
        #expect(decide(isCompact: true, 48) == true)
        #expect(decide(isCompact: true, 49) == true)
    }

    @Test func leavesCompactOnlyBelowLeaveThreshold() {
        #expect(decide(isCompact: true, 8) == false)   // strictly greater than
        #expect(decide(isCompact: true, 7) == false)
        #expect(decide(isCompact: true, 0) == false)
        #expect(decide(isCompact: true, -5) == false)
    }

    // MARK: - Stability: a dwelling value cannot self-oscillate

    @Test func anyDwellingValueIsAFixedPoint() {
        // Feed each decision's own output back in as the new state, for values spanning the range.
        // With hysteresis every value converges to a single stable state and stops — the limit
        // cycle that caused the jitter is impossible.
        for distance in stride(from: CGFloat(-40), through: 240, by: 4) {
            let first = decide(isCompact: false, distance)
            let settled = decide(isCompact: first, distance)
            // Applying the decision to its own result yields the same result (fixed point).
            #expect(decide(isCompact: settled, distance) == settled)
            // And re-running never disagrees with the settled value.
            #expect(settled == decide(isCompact: settled, distance))
        }
    }

    @Test func deadBandValueHoldsWhicheverStateItStartedIn() {
        // The defining property of the fix: inside 8…48 the decision preserves the incoming state
        // rather than forcing one — so an animated inset that lands a page here can't toggle it.
        for distance in stride(from: CGFloat(9), through: 48, by: 3) {
            #expect(decide(isCompact: false, distance) == false)
            #expect(decide(isCompact: true, distance) == true)
        }
    }
}

/// Policy tests for the height fed from the floating tab bar into every tab's scroll-content
/// padding. The reservation must not follow the bar's per-frame compact/expand geometry.
@MainActor
@Suite struct TabBarClearanceTests {

    @Test func retainsTheLargestValidMeasurement() {
        let expanded: CGFloat = 94
        let compact: CGFloat = 58

        let afterExpanded = FernletTabBarClearance.stableHeight(current: 0, measured: expanded)
        let afterCompact = FernletTabBarClearance.stableHeight(current: afterExpanded, measured: compact)

        #expect(afterExpanded == expanded)
        #expect(afterCompact == expanded)
    }

    @Test func acceptsAGreaterExpandedMeasurement() {
        let previous: CGFloat = 94
        let accessibilitySize: CGFloat = 126

        let result = FernletTabBarClearance.stableHeight(
            current: previous,
            measured: accessibilitySize
        )

        #expect(result == accessibilitySize)
    }

    @Test func rejectsInvalidMeasurementsWithoutLosingReservation() {
        let reservation: CGFloat = 94

        #expect(FernletTabBarClearance.stableHeight(current: reservation, measured: .nan) == reservation)
        #expect(FernletTabBarClearance.stableHeight(current: reservation, measured: .infinity) == reservation)
        #expect(FernletTabBarClearance.stableHeight(current: reservation, measured: -1) == reservation)
    }
}
