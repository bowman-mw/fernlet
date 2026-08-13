// GuidedWorkoutRunState.swift
// FernletWidgets  —  compiled into BOTH the Fernlet app target AND the FernletWidgets extension.
//
// The serializable source of truth for an in-progress guided workout. It lives in the app-group
// container so the interactive Live Activity buttons ("Done set" / "Skip rest") can advance the
// workout from the Lock Screen / Dynamic Island — even when the app is suspended or was terminated
// and the system cold-launches it just to run the intent. The app mirrors this state into the group
// on every in-app transition and reconciles back from it on foreground, so the in-app guided sheet
// and the Live Activity never disagree about which set you're on.
//
// Dual target membership (like WorkoutActivityAttributes.swift): the WIDGET target references it in
// the App Intents; the APP target reads/writes it (FernletStore) and maps it to/from the domain.
// It is wired into the Fernlet target via the FernletWidgets folder's build-file exception set.
//
// S3 wall: plain Codable/Hashable value types + ActivityKit only — no Private* stores, no
// FernletDomainModel import. The APP target owns the domain⇄run-state mapping (it can import both);
// this shared type stays byte-portable, storing roles/kinds/intensity as raw strings.

import ActivityKit
import Foundation

/// A guided workout in progress, captured as a flat value so it survives process death in the
/// app-group container and can be advanced by an App Intent with no live app state.
///
/// Carries everything a cold-launched process needs: the full `exercises` list (so a Lock Screen
/// "Done set" needs no domain plan) and the complete logging payload (session id, day key,
/// intensity, title, notes) so a workout finished entirely from the Lock Screen can still be logged
/// on the app's next reconcile. Persisted as ISO-8601 JSON by ``GuidedWorkoutRunStateStore``; its
/// two writers (the app while foregrounded, the App Intents otherwise) never run concurrently. All
/// transitions are pure `mutating` functions mirroring the old WorkoutSessionRunner state machine,
/// and the rest-window invariant (`restStartedAt`/`restEndsAt` set and cleared together, only while
/// `.resting`) keeps the widget's `Text(timerInterval:)` from ever seeing an inverting range.
struct GuidedWorkoutRunState: Codable, Hashable {

    /// The runner's live phase.
    ///
    /// `.done` covers both a natural finish and an abandon; the `completedNaturally` flag
    /// distinguishes them (only a natural finish is logged).
    enum Phase: String, Codable, Hashable {
        case working
        case resting
        case done
    }

    /// One prescribed movement, with its per-exercise rest baked in at build time.
    ///
    /// The rest is a research-backed default (overridable by the editor / the future coach app),
    /// baked in so advancing the workout from a cold-launched intent needs no rest-length
    /// computation.
    struct Exercise: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        /// Prescribed set count. A cardio/mobility descriptor line carries 0 and is walked as a
        /// single step (see `totalSetsForCurrent`).
        var sets: Int
        var reps: String
        /// "main" | "accessory" | "core" — mirror of the domain `SlotRole` (which has no raw value).
        var roleRaw: String
        var fromCatalog: Bool
        /// Rest AFTER a set of this exercise, in seconds. Baked in when the run is built.
        var restSeconds: Int

        init(id: UUID = UUID(), name: String, sets: Int, reps: String, roleRaw: String, fromCatalog: Bool, restSeconds: Int) {
            self.id = id
            self.name = name
            self.sets = sets
            self.reps = reps
            self.roleRaw = roleRaw
            self.fromCatalog = fromCatalog
            self.restSeconds = restSeconds
        }
    }

    // MARK: Identity + logging payload
    // Enough to log the finished workout from a cold-launched process, without the domain plan.

    /// The `SessionSuggestion.id` this run walks — the dedup key against `guidedCompletedSessionIDs`.
    var sessionID: UUID
    /// The day the plan was committed to. A rest between sets can cross local midnight; the workout is
    /// logged under this day (like `completeGuidedRunnerSession`), not "today".
    var committedDayKey: String
    /// Committed `WorkoutIntensity` raw value — so the logged row reflects how the plan was built.
    var intensityRaw: String
    /// The workout title (also the Live Activity title).
    var title: String
    /// The suggestion's human-readable exercise list + notes (what the logged `Workout` records).
    var suggestionExercisesText: String
    var suggestionNotes: String
    /// `SessionKind` raw value — picks the logged `Workout`'s mode/type.
    var sessionKindRaw: String

    var exercises: [Exercise]

    // MARK: Cursor

    /// 0-based index into `exercises`.
    var exerciseIndex: Int
    /// 1-based set counter for the current exercise.
    var currentSet: Int
    var phase: Phase
    /// The FIXED rest window (paired), so the widget renders a non-inverting `Text(timerInterval:)`.
    var restStartedAt: Date?
    var restEndsAt: Date?
    /// Seconds of the most recent rest — surfaced separately so tests can assert length without a clock.
    var restDuration: Int
    /// True only after the run was walked all the way to the end. An abandon leaves it false, so
    /// nothing is logged.
    var completedNaturally: Bool
    /// When this run was last written to the app group. Stamped on every persist. Reconcile uses its
    /// age to tell a live run (recently touched — e.g. a rest that crossed local midnight) from a run
    /// the process merely outlived (untouched for hours → abandoned), instead of keying off the day.
    var updatedAt: Date

    /// A run untouched for longer than this is treated as abandoned and retired on the next reconcile.
    /// Generous: a real session (even a long over-rest) is touched far more often; only a genuinely
    /// left-behind run reaches it.
    static let abandonedAfter: TimeInterval = 6 * 60 * 60

    init(
        sessionID: UUID,
        committedDayKey: String,
        intensityRaw: String,
        title: String,
        suggestionExercisesText: String,
        suggestionNotes: String,
        sessionKindRaw: String,
        exercises: [Exercise],
        exerciseIndex: Int = 0,
        currentSet: Int = 1,
        phase: Phase = .working,
        restStartedAt: Date? = nil,
        restEndsAt: Date? = nil,
        restDuration: Int = 0,
        completedNaturally: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.committedDayKey = committedDayKey
        self.intensityRaw = intensityRaw
        self.title = title
        self.suggestionExercisesText = suggestionExercisesText
        self.suggestionNotes = suggestionNotes
        self.sessionKindRaw = sessionKindRaw
        self.exercises = exercises
        self.exerciseIndex = exerciseIndex
        self.currentSet = currentSet
        self.phase = phase
        self.restStartedAt = restStartedAt
        self.restEndsAt = restEndsAt
        self.restDuration = restDuration
        self.completedNaturally = completedNaturally
        self.updatedAt = updatedAt
    }

    // MARK: Derived

    var currentExercise: Exercise? {
        exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
    }

    /// A cardio/conditioning descriptor (`sets == 0`) is one completable step.
    var totalSetsForCurrent: Int {
        max(1, currentExercise?.sets ?? 1)
    }

    var totalExercises: Int { exercises.count }

    var isWorking: Bool { phase == .working }
    var isResting: Bool { phase == .resting }
    var isDone: Bool { phase == .done }
    /// A natural finish that should be logged (as opposed to an abandon).
    var isFinishedNaturally: Bool { phase == .done && completedNaturally }

    // MARK: Transitions (pure — mirror the old WorkoutSessionRunner state machine)

    /// Mark the current set done. More sets of this exercise → rest; last set of this exercise →
    /// straight to the next exercise; last set of the last exercise → done.
    mutating func markSetDone(now: Date) {
        guard phase == .working, let exercise = currentExercise else { return }
        let total = max(1, exercise.sets)
        if currentSet < total {
            currentSet += 1
            beginRest(seconds: exercise.restSeconds, now: now)
        } else if exerciseIndex < exercises.count - 1 {
            exerciseIndex += 1
            currentSet = 1
            restStartedAt = nil
            restEndsAt = nil
            phase = .working
        } else {
            finish()
        }
    }

    /// End the rest early and resume the next set (counters were advanced when the rest began).
    mutating func skipRest() {
        guard phase == .resting else { return }
        restStartedAt = nil
        restEndsAt = nil
        if currentExercise == nil {
            finish()
        } else {
            phase = .working
        }
    }

    /// Abandon the run: `.done` but `completedNaturally` stays false, so nothing is logged.
    mutating func end() {
        restStartedAt = nil
        restEndsAt = nil
        phase = .done
    }

    private mutating func beginRest(seconds: Int, now: Date) {
        let s = max(0, seconds)
        restDuration = s
        restStartedAt = now
        restEndsAt = now.addingTimeInterval(TimeInterval(s))
        phase = .resting
    }

    private mutating func finish() {
        restStartedAt = nil
        restEndsAt = nil
        completedNaturally = true
        phase = .done
    }

    // MARK: Live Activity mapping

    /// Snapshot into the Live Activity content. The three-case run phase collapses to the activity's
    /// two cases: only `.resting` shows the countdown; `.working`/`.done` render as `.working` (the
    /// activity is ended the instant a run finishes, so `.done`'s rendered phase is moot).
    var contentState: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            exerciseName: currentExercise?.name ?? "",
            setNumber: currentSet,
            totalSets: totalSetsForCurrent,
            reps: currentExercise?.reps ?? "",
            phase: phase == .resting ? .resting : .working,
            restStartedAt: restStartedAt,
            restEndsAt: restEndsAt,
            exerciseIndex: exerciseIndex,
            totalExercises: totalExercises
        )
    }

    /// Named stale-date budgets (mirrors the old ContentState.Staleness).
    ///
    /// Generous enough that a real long rest or set never trips them — they exist only to retire an
    /// orphaned activity.
    enum Staleness {
        static let restGrace: TimeInterval = 10 * 60
        static let workingCap: TimeInterval = 30 * 60
    }

    /// When this snapshot should be treated as stale (paused/orphaned), given when it is posted.
    func staleDate(postedAt now: Date) -> Date {
        if phase == .resting, let end = restEndsAt {
            return end.addingTimeInterval(Staleness.restGrace)
        }
        return now.addingTimeInterval(Staleness.workingCap)
    }
}
