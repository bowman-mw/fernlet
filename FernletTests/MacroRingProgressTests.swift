import Foundation
import Testing
import SwiftUI
@testable import Fernlet

/// The macro rings on Home, Food and Journal all render through `MacroRing`, whose fill is
/// `current / goal` fed to `.trim(to:)`. Once macro goals became user-typed overrides, `goal == 0`
/// became reachable — and `0 / 0` is `.nan`, which crashes SwiftUI's path builder when handed to
/// `.trim`. These pin the guard so a zero (or absurd) goal degrades to an empty/full ring instead of
/// taking down every screen that shows macros.
struct MacroRingProgressTests {

    @Test func zeroGoalDoesNotProduceNaN() {
        // The ship-blocking case: an all-zero ring. Old code did `min(0.0/0.0, 1)` → `.nan`.
        let progress = MacroRing.ringProgress(current: 0, goal: 0)
        #expect(progress.isFinite)
        #expect(progress == 0)
    }

    @Test func zeroGoalWithIntakeStaysFinite() {
        // `50 / 0` is `+inf`; the guard must catch it before it reaches `.trim`.
        let progress = MacroRing.ringProgress(current: 50, goal: 0)
        #expect(progress.isFinite)
        #expect(progress == 0)
    }

    @Test func progressIsTheRatioWhenUnderGoal() {
        #expect(MacroRing.ringProgress(current: 0, goal: 100) == 0)
        #expect(MacroRing.ringProgress(current: 50, goal: 100) == 0.5)
        #expect(MacroRing.ringProgress(current: 100, goal: 100) == 1)
    }

    @Test func progressClampsAtOneWhenOverGoal() {
        let progress = MacroRing.ringProgress(current: 150, goal: 100)
        #expect(progress == 1)
        #expect(progress <= 1)
    }

    @Test func everyRingFillIsAFiniteUnitFraction() {
        // Sweep the space a user could type into a goal, including 0 and a negative intake.
        for goal in [0, 1, 20, 100, 3000] {
            for current in [-10, 0, 1, 50, 500, 9999] {
                let progress = MacroRing.ringProgress(current: current, goal: goal)
                #expect(progress.isFinite, "goal=\(goal) current=\(current) produced \(progress)")
                #expect(progress >= 0 && progress <= 1, "goal=\(goal) current=\(current) → \(progress)")
            }
        }
    }
}
