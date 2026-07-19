// WorkoutLiveActivityController.swift
// Fernlet (app target only — REQUESTS the workout Live Activity).
//
// Only the app can start a Live Activity, so requesting one lives here. Updating and ending it are
// shared with the Live Activity buttons and therefore go through GuidedWorkoutActivityBridge (compiled
// into both targets) — see FernletStore's guided-run transitions and GuidedWorkoutLiveActivityIntents.
//
// The rest COUNTDOWN ticks natively in the widget via `Text(timerInterval:)`, so there is NO
// time-based update path and NO push/APNs — only discrete set/exercise transitions push a new
// snapshot. Degrades to in-app-only SILENTLY when Live Activities are disabled. One workout activity
// at a time.

import ActivityKit
import Foundation

@MainActor
enum WorkoutLiveActivityController {

    /// Begin a Live Activity for a guided run. No-op (in-app-only) when the user hasn't enabled Live
    /// Activities. Ends any activity already live first, so only one workout activity is ever on screen.
    static func start(_ state: GuidedWorkoutRunState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for stale in Activity<WorkoutActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = WorkoutActivityAttributes(workoutTitle: state.title)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state.contentState, staleDate: state.staleDate(postedAt: Date()))
            )
        } catch {
            // Silent degrade: the in-app sheet remains the full experience.
        }
    }
}
