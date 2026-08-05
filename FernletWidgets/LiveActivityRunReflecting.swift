// LiveActivityRunReflecting.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The one generic engine behind GuidedWorkoutActivityBridge and CookingActivityBridge (and the
// app-side LiveActivityStarter): sync/end plumbing written once, parameterized by the run-state
// type. The bridges keep their names and remain the documented seams — they delegate here so the
// two copies of the update/end loop cannot drift.
//
// SEPARATE ACTIVITY TYPE: preserved by construction — every generic call is parameterized by its
// own `ActivityAttributes` type, so syncing or ending one activity kind can never enumerate the
// other kind's instances.
//
// Dual target membership is wired the same way as the bridges: a build-file exception set on the
// FernletWidgets folder group adds this file to the Fernlet target.

import ActivityKit
import Foundation

/// A Live Activity run state that the shared generic plumbing can reflect onto its activity:
/// it names its `ActivityAttributes` type and provides the content snapshot, terminal flag, and
/// stale-date budget the update/end/request loops need.
///
/// Conformed to by ``GuidedWorkoutRunState`` (terminal on `.done` — finish AND abandon) and
/// ``CookingRunState`` (terminal on `finished` — natural finish only; cooking abandons end the
/// activity directly). `contentState` and `staleDate(postedAt:)` are satisfied by the members the
/// run states already declare in their "Live Activity mapping" sections.
protocol LiveActivityRunReflectable {
    /// The `ActivityAttributes` type whose live activities this run state drives.
    associatedtype Attributes: ActivityAttributes

    /// Snapshot of this run state as the activity's dynamic content.
    var contentState: Attributes.ContentState { get }

    /// Whether the run has ended — `sync` ends the activity instead of updating it.
    var isTerminal: Bool { get }

    /// When a snapshot posted at the given instant should be treated as stale (paused/orphaned).
    func staleDate(postedAt: Date) -> Date
}

/// The shared generic update/end engine for Fernlet's Live Activities — the single implementation
/// ``GuidedWorkoutActivityBridge`` and ``CookingActivityBridge`` delegate to.
///
/// Both drivers run in the APP process, so enumerating `Activity<Attributes>.activities` and
/// calling `update`/`end` is valid from either seam. Every call is parameterized by one
/// `ActivityAttributes` type, so it only ever touches that kind's activities — ending the cooking
/// activity can never touch a live workout activity, and vice-versa. Stateless enum of async
/// statics; safe to call from any task.
enum LiveActivityReflector {

    /// Reflect the run state onto its live activity: update while the run is live, end (immediate
    /// dismissal) once it is terminal. No-op when nothing is on screen.
    static func sync<S: LiveActivityRunReflectable>(to state: S) async {
        if state.isTerminal {
            await end(S.Attributes.self)
            return
        }
        let content = ActivityContent(state: state.contentState, staleDate: state.staleDate(postedAt: Date()))
        for activity in Activity<S.Attributes>.activities {
            await activity.update(content)
        }
    }

    /// End every live activity of the given attributes type immediately — and ONLY that type, so
    /// the workout and cooking activities never touch each other.
    static func end<A: ActivityAttributes>(_ type: A.Type) async {
        for activity in Activity<A>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

// MARK: - Conformances
// Declared here (not in the run-state files) so the run states stay pure app-group snapshot types.

extension GuidedWorkoutRunState: LiveActivityRunReflectable {
    /// The guided-workout run drives `Activity<WorkoutActivityAttributes>`.
    typealias Attributes = WorkoutActivityAttributes

    /// Terminal on `.done` — a natural finish AND an abandon both end the workout activity.
    var isTerminal: Bool { isDone }
}

extension CookingRunState: LiveActivityRunReflectable {
    /// The cooking run drives `Activity<CookingActivityAttributes>`.
    typealias Attributes = CookingActivityAttributes

    /// Terminal on `finished` — natural finish only; cooking abandons call the bridge's `end()`
    /// directly rather than syncing a terminal state.
    var isTerminal: Bool { isFinished }
}
