// GuidedWorkoutActivityBridge.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The one place that pushes a GuidedWorkoutRunState onto the live workout activity, shared by the app
// (in-app transitions) and the App Intents (Lock Screen buttons). Both run in the APP process, so
// enumerating `Activity<WorkoutActivityAttributes>.activities` and calling `update`/`end` is valid
// from either — and going through this single seam keeps the two drivers byte-for-byte consistent.
//
// Requesting a NEW activity stays app-only (WorkoutLiveActivityController), because only the app ever
// starts a workout; this bridge only ever updates or ends the one already on screen.

import ActivityKit
import Foundation

/// The single seam that reflects a ``GuidedWorkoutRunState`` onto the live workout activity —
/// updating it while the workout is live and ending it on `.done`.
///
/// Shared by both drivers that run in the APP process: the in-app guided sheet (via `FernletStore`)
/// and the App Intents (``GuidedWorkoutIntentRunner``, behind the Lock Screen buttons). Funneling
/// both through one namespace keeps their activity updates byte-for-byte consistent. It enumerates
/// ONLY `Activity<WorkoutActivityAttributes>`, so it never touches a live cooking activity.
/// Requesting a NEW activity is deliberately out of scope — only the app
/// (`WorkoutLiveActivityController`) ever starts a workout; this bridge only updates or ends what is
/// already on screen. Stateless enum of async statics; safe to call from any task.
enum GuidedWorkoutActivityBridge {

    /// Reflect the run state onto the live activity: update while the workout is live, end (immediate
    /// dismissal) once it reaches `.done`. No-op when nothing is on screen.
    static func sync(to state: GuidedWorkoutRunState) async {
        await LiveActivityReflector.sync(to: state)
    }

    /// End every live workout activity immediately (used on finish, abandon, and stale cleanup).
    static func end() async {
        await LiveActivityReflector.end(WorkoutActivityAttributes.self)
    }
}
