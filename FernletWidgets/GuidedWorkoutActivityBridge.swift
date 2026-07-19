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

enum GuidedWorkoutActivityBridge {

    /// Reflect the run state onto the live activity: update while the workout is live, end (immediate
    /// dismissal) once it reaches `.done`. No-op when nothing is on screen.
    static func sync(to state: GuidedWorkoutRunState) async {
        if state.isDone {
            await end()
            return
        }
        let content = ActivityContent(state: state.contentState, staleDate: state.staleDate(postedAt: Date()))
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    /// End every live workout activity immediately (used on finish, abandon, and stale cleanup).
    static func end() async {
        for activity in Activity<WorkoutActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
