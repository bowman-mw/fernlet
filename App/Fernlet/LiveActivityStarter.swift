// LiveActivityStarter.swift
// Fernlet (app target only — REQUESTS Live Activities).
//
// The shared generic requester behind WorkoutLiveActivityController and CookingLiveActivityController.
// Only the app process can start a Live Activity, so requesting stays app-only: this file lives in
// the Fernlet folder and is deliberately NOT in the dual-membership set (unlike the update/end
// engine, LiveActivityReflector, which the Lock Screen intents also need).

import ActivityKit
import Foundation
import FernletFoundation

/// The shared generic requester behind ``WorkoutLiveActivityController`` and
/// ``CookingLiveActivityController`` — the app-target-only half of the Live Activity flow.
///
/// Starting an activity is the one thing only the app process can do, so this stays out of the
/// dual-membership set the update/end plumbing (`LiveActivityReflector`) compiles into. Each call
/// is parameterized by one `ActivityAttributes` type, so starting one activity kind only ever ends
/// stale instances of that same kind — a live activity of the other kind is untouched.
@MainActor
enum LiveActivityStarter {

    /// Begin a Live Activity for a run. No-op (in-app-only) when the user hasn't enabled Live
    /// Activities. Ends any activity of the same attributes type already live first, so at most one
    /// is ever on screen — the stale ends are deliberately fire-and-forget, racing the request
    /// exactly as both original controllers did. Request failures degrade silently: the in-app
    /// surface remains the full experience.
    static func start<S: LiveActivityRunReflectable>(_ state: S, attributes: S.Attributes) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for stale in Activity<S.Attributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state.contentState, staleDate: state.staleDate(postedAt: Date()))
            )
        } catch {
            // Silent degrade for the user: the in-app surface remains the full experience. The audit
            // line is the recovery trail — a Live Activity that never appears (entitlement, per-app
            // cap, OS refusal) otherwise leaves no trace at all.
            FernletAuditLog.log("liveActivity.request.failed",
                                context: ["kind": String(describing: S.Attributes.self),
                                          "errorType": "\(type(of: error))"])
        }
    }
}
