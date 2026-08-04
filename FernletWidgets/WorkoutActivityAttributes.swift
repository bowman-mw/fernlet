// WorkoutActivityAttributes.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The ActivityKit contract for the guided-workout Live Activity. The APP target REQUESTS and UPDATES
// the activity (`WorkoutLiveActivityController`); the WIDGET target RENDERS it (`WorkoutLiveActivity`).
// Both targets must compile this one file — that dual target membership is the #1 ActivityKit setup
// pitfall. It is wired via a second `PBXFileSystemSynchronizedBuildFileExceptionSet` on the
// FernletWidgets folder group that adds this file to the Fernlet target (the folder's default owner is
// FernletWidgets), mirroring how Info.plist is EXCLUDED via its own exception set.
//
// S3 wall: plain Codable/Hashable value types only — no Private* store imports, no app/domain-model
// imports. The type is a byte-portable snapshot, exactly like the app-group JSON contracts alongside
// it in WidgetSharedModels.swift. The rest timer ticks natively via `Text(timerInterval:)`, so the
// ContentState only changes on discrete set/exercise transitions — never per-second, never via push.

import ActivityKit
import Foundation

/// The ActivityKit contract for the guided-workout Live Activity: the fixed attributes (workout
/// title) plus the per-set ``ContentState`` snapshot.
///
/// Compiled into BOTH targets: the app's `WorkoutLiveActivityController` requests and updates the
/// activity with these values, and the widget's ``WorkoutLiveActivity`` renders them. A plain
/// Codable/Hashable value type with no app or domain-model imports (S3 wall) —
/// ``CookingActivityAttributes`` mirrors this shape for cooking mode. The rest timer ticks natively
/// via `Text(timerInterval:)`, so the content state only changes on discrete set/exercise
/// transitions — never per-second, never via push.
struct WorkoutActivityAttributes: ActivityAttributes {
    /// The workout's title (e.g. "Push day"). Fixed for the life of the activity.
    var workoutTitle: String

    /// The dynamic per-set snapshot the widget renders: exercise name, set/exercise cursors, the
    /// two-case phase, and the optional fixed rest window.
    ///
    /// Produced only by `GuidedWorkoutRunState.contentState` (the app-group run state's Live Activity
    /// mapping), so both drivers — the in-app guided sheet and the Lock Screen intents — publish
    /// byte-identical snapshots.
    struct ContentState: Codable, Hashable {
        /// The two-case rendering phase: `working` = doing a set (show set / reps), `resting` =
        /// between sets (show the countdown).
        ///
        /// Deliberately narrower than the run state's three-case ``GuidedWorkoutRunState/Phase`` —
        /// the Live Activity surface only ever renders while a workout is in progress, so `.done`
        /// never reaches it (the activity is ended the instant a run finishes).
        enum Phase: String, Codable, Hashable {
            case working
            case resting
        }

        var exerciseName: String
        var setNumber: Int
        var totalSets: Int
        var reps: String
        var phase: Phase
        /// The FIXED rest window. Paired so the widget can render
        /// `Text(timerInterval: restStartedAt...restEndsAt, countsDown: true)` — a valid, non-inverting
        /// range that clamps to 0:00 once the deadline passes. A live `Date()...restEndsAt` lower bound
        /// would invert and fatalError once the rest expires (over-resting is a designed state). Both
        /// are set only while `phase == .resting` and cleared together otherwise.
        var restStartedAt: Date?
        var restEndsAt: Date?
        var exerciseIndex: Int
        var totalExercises: Int
    }
}
