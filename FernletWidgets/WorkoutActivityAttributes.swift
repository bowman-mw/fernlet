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

struct WorkoutActivityAttributes: ActivityAttributes {
    /// The workout's title (e.g. "Push day"). Fixed for the life of the activity.
    var workoutTitle: String

    struct ContentState: Codable, Hashable {
        /// `working` = doing a set (show set / reps). `resting` = between sets (show the countdown).
        /// Deliberately NOT the runner's four-case `Phase` — the Live Activity surface only ever
        /// renders while a workout is in progress, so `.ready`/`.done` never reach it.
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
