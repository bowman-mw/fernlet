// CookingLiveActivityController.swift
// Fernlet (app target only — REQUESTS the cooking Live Activity).
//
// Only the app can start a Live Activity, so requesting one lives here. Updating and ending it are
// shared with the Live Activity button / Siri intents and therefore go through CookingActivityBridge
// (compiled into both targets) — see FernletStore's cooking-run transitions and CookingLiveActivityIntents.
//
// The per-step COUNTDOWN ticks natively in the widget via `Text(timerInterval:)`, so there is NO
// time-based update path and NO push/APNs — only discrete step transitions (and starting/resetting a
// timer) push a new snapshot. Degrades to in-app-only SILENTLY when Live Activities are disabled. One
// cooking activity at a time.
//
// SEPARATE ACTIVITY TYPE: this ends only prior `Activity<CookingActivityAttributes>` instances, never a
// live workout activity — starting a cook while a workout Live Activity is up leaves the workout alone.

import ActivityKit
import Foundation

@MainActor
enum CookingLiveActivityController {

    /// Begin a Live Activity for a cooking run. No-op (in-app-only) when the user hasn't enabled Live
    /// Activities. Ends any cooking activity already live first, so only one cooking activity is ever on
    /// screen — a workout activity (a different type) is untouched.
    static func start(_ state: CookingRunState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for stale in Activity<CookingActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        let attributes = CookingActivityAttributes(recipeName: state.recipeName)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state.contentState, staleDate: state.staleDate(postedAt: Date()))
            )
        } catch {
            // Silent degrade: the in-app cooking walker remains the full experience.
        }
    }
}
