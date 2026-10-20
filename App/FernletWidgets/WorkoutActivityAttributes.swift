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
// ContentState only changes on discrete moves — a set, an exercise, a ±15 s rest adjustment, a weight
// picked in the app — never per-second, never via push. The one exception is opt-in and bounded: during
// guided cardio with a live heart rate, the app pushes a changed reading at most every five seconds
// (`GuidedZoneDirector`), from its own process, still never via push.

import ActivityKit
import Foundation

/// The ActivityKit contract for the guided-workout Live Activity: the fixed attributes (workout
/// title) plus the per-set ``ContentState`` snapshot.
///
/// Compiled into BOTH targets: the app's `WorkoutLiveActivityController` requests and updates the
/// activity with these values, and the widget's `WorkoutLiveActivity` renders them. A plain
/// Codable/Hashable value type with no app or domain-model imports (S3 wall) —
/// ``CookingActivityAttributes`` mirrors this shape for cooking mode. The rest timer ticks natively
/// via `Text(timerInterval:)`, so the content state only changes on discrete moves (a set, an
/// exercise, a ±15 s rest adjustment, a weight picked in the app) — never per-second, never via push.
///
/// `nonisolated`, with its nested types, so the app target's default main-actor isolation does not
/// make its `ActivityAttributes` conformance an isolated one: ActivityKit enumerates, updates and
/// ends activities from `@concurrent` code, and ``LiveActivityRunReflectable`` holds its
/// `Attributes` to `Sendable`, which an isolated conformance cannot meet.
nonisolated struct WorkoutActivityAttributes: ActivityAttributes {
    /// The workout's title (e.g. "Push day"). Fixed for the life of the activity.
    var workoutTitle: String

    /// The dynamic per-set snapshot the widget renders: exercise name, set/exercise cursors, the
    /// two-case phase, the optional fixed rest window, and the set's display-only load line.
    ///
    /// Produced only by `GuidedWorkoutRunState.contentState` (the app-group run state's Live Activity
    /// mapping), so both drivers — the in-app guided sheet and the Lock Screen intents — publish
    /// byte-identical snapshots. The one addition is the app's: during guided cardio it lays the live
    /// heart-rate reading over ``zone`` (`GuidedWorkoutActivityBridge.sync(to:zone:)`), which the run
    /// state never stores; a Lock Screen tap publishes the run's own zone (the talk test) until the
    /// app's next reading.
    nonisolated struct ContentState: Codable, Hashable {
        /// The two-case rendering phase: `working` = doing a set (show set / reps), `resting` =
        /// between sets (show the countdown).
        ///
        /// Deliberately narrower than the run state's three-case ``GuidedWorkoutRunState/Phase`` —
        /// the Live Activity surface only ever renders while a workout is in progress, so `.done`
        /// never reaches it (the activity is ended the instant a run finishes).
        nonisolated enum Phase: String, Codable, Hashable {
            case working
            case resting
        }

        /// The exercise's name as drawn — the run step's `displayedName`, already in the user's
        /// language. Display only; nothing reads it back as an identifier.
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
        /// The FIXED hold window of a timed step being worked (a stretch, a plank), paired like the
        /// rest window so `Text(timerInterval:)` never inverts; both nil for a rep-counted set.
        var holdStartsAt: Date? = nil
        var holdEndsAt: Date? = nil
        /// The step's session block (`GuidedWorkoutRunState.BlockToken`) and side ("left"/"right"),
        /// as raw strings; nil for an untagged lifting step and a two-sided one.
        var blockRaw: String? = nil
        var sideRaw: String? = nil
        /// The current set's weight and last time's numbers for the lift — DISPLAY ONLY: the Live
        /// Activity never edits a weight (the runner's weight panel is the one place one is picked).
        /// Nil for a step with nothing to show (a stretch, a cardio line, a lift never logged and
        /// given no weight), and in a payload from before load display existed.
        var load: Load? = nil
        /// A timed cardio segment's pace — "steady" | "hard" | "easy", a
        /// `GuidedWorkoutRunState.PaceToken` — and, for an interval, its round and the rounds in all.
        /// Its countdown is the hold window above. Nil on every other step, and in a payload from
        /// before guided cardio existed.
        var paceRaw: String? = nil
        var round: Int? = nil
        var rounds: Int? = nil
        /// A timed cardio segment's heart-rate cue: the zone its pace aims for and — while Fernlet is
        /// reading a live heart rate — the reading against that zone's range. Nil on every other step,
        /// and in a payload from before heart-rate zones existed.
        var zone: Zone? = nil

        /// The numbers behind a cardio segment's heart-rate cue: the zone its pace aims for, and the
        /// live reading with the zone's range when there is one (comparison report idea 9).
        ///
        /// Numbers only, never text: the widget words them in its own locale
        /// (``WorkoutActivityZoneText``). Every field is optional, so a payload missing one — or the
        /// whole `zone` key — still decodes. With `target` alone the cue is the talk test; with `bpm`,
        /// `low` and `high` as well it is the live reading ("118 bpm · aim 110–125"). Four scalars:
        /// Live Activity payloads are small, and the heart rate itself is never stored anywhere.
        nonisolated struct Zone: Codable, Hashable {
            /// The zone the segment's pace aims for (2 for easy and steady, 4 for hard).
            var target: Int?
            /// The latest live heart rate, in beats per minute; nil without a live reading.
            var bpm: Int?
            /// The target zone's range, in beats per minute; nil without a live reading.
            var low: Int?
            var high: Int?

            /// Where a live reading sits against the range — always said in words, never colour alone.
            nonisolated enum Band: String, Hashable {
                /// Under the range: "a little low".
                case low
                /// Within the range: "in range".
                case inRange
                /// Over the range: "a little high".
                case high
            }

            /// Where `bpm` sits against `range`.
            static func band(bpm: Int, range: ClosedRange<Int>) -> Band {
                if bpm < range.lowerBound { return .low }
                return bpm > range.upperBound ? .high : .inRange
            }

            /// The target range, when the cue carries one in order.
            var range: ClosedRange<Int>? {
                guard let low, let high, low <= high else { return nil }
                return low...high
            }

            /// Where the live reading sits, or nil without one — the cue is then the talk test.
            var band: Band? {
                guard let bpm, let range else { return nil }
                return Self.band(bpm: bpm, range: range)
            }

            /// Whether the cue carries a live reading to draw.
            var isLive: Bool { band != nil }
        }

        /// The numbers behind the set's load line: the weight the runner shows, the engine's range,
        /// and last time's sets, reps and weight.
        ///
        /// Numbers and unit tokens, never text: the widget formats them in its own locale
        /// (``WorkoutActivityLoadText``). Every field is optional, so a payload missing one — or the
        /// whole `load` key — still decodes. Kept to nine scalars: Live Activity payloads are small.
        nonisolated struct Load: Codable, Hashable {
            /// The weight the runner shows for this set: the suggestion, preselected, until the lifter
            /// picks another in the app (`GuidedWorkoutRunState.Tracking.selected`).
            var weight: Double?
            /// The engine's suggestion, so the spoken line says "Suggested weight" only while
            /// `weight` still is it.
            var suggested: Double?
            /// The prescribed range, when the engine gave one.
            var rangeLow: Double?
            var rangeHigh: Double?
            /// "lb" | "kg" — the domain `LoadUnit` raw value of `weight` and the range.
            var unitRaw: String?
            /// Last time's sets, reps (as logged: "8", "8-10") and weight for this lift.
            var lastSets: Int?
            var lastReps: String?
            var lastWeight: Double?
            /// "lb" | "kg" for `lastWeight`, or nil when the logged line never said.
            var lastUnitRaw: String?

            /// Nothing to draw: no weight, no range and no last-time numbers.
            var isEmpty: Bool {
                weight == nil && rangeLow == nil && rangeHigh == nil && lastSets == nil && lastWeight == nil
            }
        }
    }
}
