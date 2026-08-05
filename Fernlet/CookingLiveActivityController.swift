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

/// App-target-only requester of the cooking Live Activity — starting an activity is the one thing
/// only the app process can do.
///
/// Called from `FernletStore`'s cooking-run start transition; updates and ends go through the shared
/// `CookingActivityBridge` instead (compiled into both targets), and the per-step countdown ticks
/// natively in the widget via `Text(timerInterval:)`, so there is no time-based update path and no
/// push channel. Degrades silently to in-app-only when Live Activities are disabled, and only ever
/// ends prior `CookingActivityAttributes` instances — a live workout activity is untouched.
@MainActor
enum CookingLiveActivityController {

    /// Begin a Live Activity for a cooking run. No-op (in-app-only) when the user hasn't enabled Live
    /// Activities. Ends any cooking activity already live first, so only one cooking activity is ever on
    /// screen — a workout activity (a different type) is untouched.
    static func start(_ state: CookingRunState) {
        LiveActivityStarter.start(state, attributes: CookingActivityAttributes(recipeName: state.recipeName))
    }
}
