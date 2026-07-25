// CookingActivityAttributes.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The ActivityKit contract for the cooking-mode Live Activity (F5). The APP target REQUESTS and
// UPDATES the activity (`CookingLiveActivityController`); the WIDGET target RENDERS it
// (`CookingLiveActivity`). Both targets must compile this one file — that dual target membership is
// the #1 ActivityKit setup pitfall. It is wired via the FernletWidgets folder's build-file exception
// set that adds this file to the Fernlet target, mirroring WorkoutActivityAttributes.swift exactly.
//
// S3 wall: plain Codable/Hashable value types only — no Private* store imports, no app/domain-model
// imports. The type is a byte-portable snapshot, exactly like WorkoutActivityAttributes alongside it.
// The per-step timer ticks natively via `Text(timerInterval:)`, so the ContentState only changes on
// discrete step transitions (and when a timer is started/reset) — never per-second, never via push.

import ActivityKit
import Foundation

struct CookingActivityAttributes: ActivityAttributes {
    /// The recipe's name (e.g. "Weeknight ragù"). Fixed for the life of the activity.
    var recipeName: String

    struct ContentState: Codable, Hashable {
        /// The current step's instruction text.
        var stepText: String
        /// 1-based step cursor and total, for "Step 3 of 8".
        var stepNumber: Int
        var stepCount: Int
        /// True on the final step — the Next button then reads "Finish".
        var isLastStep: Bool
        /// The FIXED per-step timer window. Paired so the widget can render
        /// `Text(timerInterval: timerStartedAt...timerEndsAt, countsDown: true)` — a valid,
        /// non-inverting range that clamps to 0:00 once the deadline passes. A live
        /// `Date()...timerEndsAt` lower bound would invert and fatalError once the timer expires
        /// (over-running a step is a designed state). Both are set only while a step timer is running
        /// and cleared together otherwise — nil when the step has no timer or it hasn't been started.
        var timerStartedAt: Date?
        var timerEndsAt: Date?
    }
}
