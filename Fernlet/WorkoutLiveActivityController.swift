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

/// Requests the guided-workout Live Activity — the app-target-only half of the Live Activity flow.
///
/// Only the app process can start a Live Activity, so requesting one lives here; updates and ends
/// are shared with the Live Activity buttons and go through `GuidedWorkoutActivityBridge` (compiled
/// into both targets) from ``FernletStore``'s guided-run transitions. The rest countdown ticks
/// natively in the widget via `Text(timerInterval:)`, so there is no time-based update path and no
/// push/APNs — only discrete set/exercise transitions push a new snapshot. Degrades to in-app-only
/// silently when Live Activities are disabled, and ends any activity already live before requesting,
/// so at most one workout activity is ever on screen.
@MainActor
enum WorkoutLiveActivityController {

    /// Begin a Live Activity for a guided run. No-op (in-app-only) when the user hasn't enabled Live
    /// Activities. Ends any activity already live first, so only one workout activity is ever on screen.
    static func start(_ state: GuidedWorkoutRunState) {
        LiveActivityStarter.start(state, attributes: WorkoutActivityAttributes(workoutTitle: state.title))
    }
}
