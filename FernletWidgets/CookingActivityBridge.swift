// CookingActivityBridge.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The one place that pushes a CookingRunState onto the live cooking activity, shared by the app
// (in-app Next/Back/timer) and the App Intents (Lock Screen "Next" button, Siri "next step"). Both run
// in the APP process, so enumerating `Activity<CookingActivityAttributes>.activities` and calling
// `update`/`end` is valid from either — and going through this single seam keeps the two drivers
// byte-for-byte consistent. Mirror of GuidedWorkoutActivityBridge.
//
// Requesting a NEW activity stays app-only (CookingLiveActivityController), because only the app ever
// starts a cook; this bridge only ever updates or ends the one already on screen.
//
// SEPARATE ACTIVITY TYPE: this enumerates ONLY `Activity<CookingActivityAttributes>`, so ending the
// cooking activity never touches a live workout activity (a different `ActivityAttributes` type), and
// vice-versa. Starting a cook while a workout Live Activity is up leaves the workout untouched.

import ActivityKit
import Foundation

/// The single seam that reflects a ``CookingRunState`` onto the live cooking activity — updating it
/// while a cook is in progress and ending it on finish.
///
/// Shared by both drivers that run in the APP process: the in-app cooking walker (Next/Back/timer via
/// `FernletStore`) and the App Intents (``CookingIntentRunner``, behind the Lock Screen "Next" button
/// and Siri). Funneling both through one namespace keeps their activity updates byte-for-byte
/// consistent. It enumerates ONLY `Activity<CookingActivityAttributes>`, so it can never touch a live
/// workout activity (a different `ActivityAttributes` type). Requesting a NEW activity is deliberately
/// out of scope — only the app (`CookingLiveActivityController`) ever starts a cook; this bridge only
/// updates or ends what is already on screen. Stateless enum of async statics; safe to call from any
/// task.
enum CookingActivityBridge {

    /// Reflect the run state onto the live activity: update while the cook is in progress, end
    /// (immediate dismissal) once it reaches `finished`. No-op when nothing is on screen.
    static func sync(to state: CookingRunState) async {
        if state.isFinished {
            await end()
            return
        }
        let content = ActivityContent(state: state.contentState, staleDate: state.staleDate(postedAt: Date()))
        for activity in Activity<CookingActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    /// End every live cooking activity immediately (used on finish, discard, and stale cleanup). Only
    /// cooking activities — never the workout activity.
    static func end() async {
        for activity in Activity<CookingActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
