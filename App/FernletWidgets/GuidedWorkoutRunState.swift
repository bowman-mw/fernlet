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
        /// Seconds each set is held, for a timed step (a stretch, a plank, a carry); nil when the set
        /// is counted in reps. Optional so a run persisted by an older build still decodes.
        var holdSeconds: Int?
        /// The session block this step belongs to — a ``BlockToken`` value; nil reads as lifting.
        var blockRaw: String?
        /// "left" | "right" for a one-sided step — the domain `ExerciseSide` raw value; nil otherwise.
        var sideRaw: String?
        /// The load plan and what actually happened, for a rep-counted lift the planner prescribed;
        /// nil on every other step and in a run persisted before load tracking existed.
        var tracking: Tracking?
        /// The name screens draw for this step, in the user's language, baked in by the app when the
        /// run is built (this file cannot import the domain's lookup). Display only: ``name`` stays
        /// the FROZEN catalog name that logging, progression and matching read. Nil in a run persisted
        /// before display names existed, which then draws ``name``.
        var displayName: String?

        init(
            id: UUID = UUID(), name: String, sets: Int, reps: String, roleRaw: String, fromCatalog: Bool,
            restSeconds: Int, holdSeconds: Int? = nil, blockRaw: String? = nil, sideRaw: String? = nil,
            tracking: Tracking? = nil, displayName: String? = nil
        ) {
            self.id = id
            self.name = name
            self.sets = sets
            self.reps = reps
            self.roleRaw = roleRaw
            self.fromCatalog = fromCatalog
            self.restSeconds = restSeconds
            self.holdSeconds = holdSeconds
            self.blockRaw = blockRaw
            self.sideRaw = sideRaw
            self.tracking = tracking
            self.displayName = displayName
        }

        /// The step's block, with an untagged step (any run built before blocks existed) as lifting.
        var block: String { blockRaw ?? BlockToken.lifting }

        /// The name a screen, a spoken transition or the Live Activity draws: ``displayName`` when
        /// the app baked one in, else the frozen ``name``.
        var displayedName: String { displayName ?? name }
    }

    /// One lift's load plan (fixed when the run starts) and what happened (set in the app as the
    /// lifter picks a weight, edits reps, taps an effort, or says why they left the range).
    ///
    /// Tokens are the domain's raw values (`LoadUnit`, `Equipment`, `EstimateConfidence`,
    /// `CalibrationStep`, `ExerciseEffort`, `OverrideReason`), spelled as strings because this shared
    /// file cannot import the domain. Untouched, the lift logs as "completed as prescribed" at
    /// `selected` — the suggestion, preselected — with no extra step.
    struct Tracking: Codable, Hashable {
        var targetReps: Int
        var rangeLow: Double?
        var rangeHigh: Double?
        var suggested: Double?
        /// The equipment's weight step; nil when the lift takes no load.
        var step: Double?
        var unitRaw: String?
        var equipmentRaw: String?
        var confidenceRaw: String?
        var askReasonOnOverride: Bool
        var calibrationRaw: String?
        var easierSession: Bool
        var compoundsBefore: Int

        /// The weight the lifter will use; the suggestion until they change it.
        var selected: Double?
        /// Reps per set when they differed from the target; nil = completed as prescribed.
        var actualReps: [Int]?
        var effortRaw: String?
        var overrideReasonRaw: String?
        /// The runner skipped past this lift; it is logged as skipped and never read as a result.
        var skipped: Bool?

        /// Sets an edit may carry at most.
        static let maxSets = 20

        /// The lift takes a load: the runner shows its weight picker.
        var isLoadable: Bool { step != nil && unitRaw != nil }

        /// The chosen weight sits outside the prescribed range.
        var isOutsideRange: Bool {
            guard let selected, let rangeLow, let rangeHigh else { return false }
            return selected < rangeLow - 0.01 || selected > rangeHigh + 0.01
        }
    }

    /// Calibration-step tokens, spelled here for the same reason as ``BlockToken``.
    enum CalibrationToken {
        static let ramp = "ramp"
        static let test = "test"
        static let attempt = "attempt"
    }

    /// The session-block tokens, spelled here because this shared file cannot import the domain:
    /// each equals the domain `SessionBlock` case's raw value (pinned by a test), and like it is
    /// FROZEN — a run in progress stores them.
    enum BlockToken {
        static let warmUp = "warmUp"
        static let activation = "activation"
        static let lifting = "lifting"
        static let cardio = "cardio"
        static let coolDown = "coolDown"
    }

    /// Seconds between a timed step starting and its hold starting: time to get into position, so a
    /// 20-second stretch is held for 20 seconds, not 15. `nonisolated` so the Move tab's nonisolated
    /// time estimate can read it under the app target's default main-actor isolation.
    nonisolated static let holdLeadInSeconds = 5

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
    /// When the current set began — stamped on start, on moving to the next exercise, and on leaving
    /// a rest. A timed step's hold window counts from here (``holdWindow``); nil in a run persisted
    /// before holds existed, which then simply shows no countdown.
    var setStartedAt: Date?
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
        setStartedAt: Date? = nil,
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
        self.setStartedAt = setStartedAt
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

    /// Sets of the current exercise already done — what the runner's segmented set strip fills.
    ///
    /// `currentSet` is 1-based and advances the moment a rest BEGINS, so "completed" is
    /// `currentSet - 1` in both the working and the resting phase: while working, the current set
    /// is in progress (not done); while resting, the counter already points at the next set.
    var setsCompletedForCurrent: Int {
        max(0, min(currentSet - 1, totalSetsForCurrent))
    }

    /// The fixed hold window of the current set, for a timed step that is being worked: from the end
    /// of its lead-in to the end of the hold. Fixed (not `Date()`-based), so a countdown over it never
    /// inverts however long the user takes; nil for a rep-counted set, while resting, or without a
    /// set start.
    var holdWindow: ClosedRange<Date>? {
        guard phase == .working, let hold = currentExercise?.holdSeconds, hold > 0, let setStartedAt else {
            return nil
        }
        let start = setStartedAt.addingTimeInterval(TimeInterval(Self.holdLeadInSeconds))
        return start...start.addingTimeInterval(TimeInterval(hold))
    }

    /// The current step's block, or lifting when there is none.
    var currentBlock: String { currentExercise?.block ?? BlockToken.lifting }

    /// The current step's 1-based position within its block, and the block's size ("Warm-up · 3 of 23").
    var blockPosition: (index: Int, count: Int) {
        let block = currentBlock
        let indices = exercises.indices.filter { exercises[$0].block == block }
        let position = (indices.firstIndex(of: exerciseIndex) ?? 0) + 1
        return (position, max(1, indices.count))
    }

    /// Whether the warm-up or the cool-down can be skipped from here — the runner's quiet "Skip
    /// warm-up" / "Skip cool-down" secondary.
    var canSkipBlock: Bool {
        (isWorking || isResting) && (currentBlock == BlockToken.warmUp || currentBlock == BlockToken.coolDown)
    }

    /// Whether the run can jump past the rest of the current exercise to the next one — the
    /// runner's quiet "Skip to next exercise" secondary. False on the last exercise (there is
    /// nothing next; finishing early is the End affordance's job) and once the run is done.
    var canSkipToNextExercise: Bool {
        (isWorking || isResting) && exerciseIndex < exercises.count - 1
    }

    /// A rough time-left estimate for the header ("Exercise 1 of 5 · 38 min left"), in seconds.
    ///
    /// Heuristic, documented so it can be tuned in one place:
    /// - every remaining set of a catalog exercise costs `workSecondsPerSet` (default 45s — a
    ///   typical 8–12-rep working set), plus that exercise's baked `restSeconds` between its own
    ///   sets (`sets - 1` rests per exercise; an in-flight rest counts as one whole rest);
    /// - a descriptor line (`sets == 0` — cardio/mobility walked as one step) costs the minutes it
    ///   names ("Conditioning intervals - 12 min"), else `descriptorSeconds` (default 5 min);
    /// - the working phase counts the current set as still ahead; the resting phase counts the
    ///   upcoming set (the counter already advanced when the rest began).
    ///
    /// At the start of a run this is the plan card's estimate to the second (the domain's
    /// `WorkoutSessionTime`, which a session-length budget fits by; pinned by a test).
    /// Pure over the value's own fields — no clock — so it stays deterministic and testable.
    /// Bounded: one pass over `exercises` (capped by the plan-session exercise limit).
    func estimatedSecondsRemaining(workSecondsPerSet: Int = 45, descriptorSeconds: Int = 300) -> Int {
        guard !isDone else { return 0 }
        var total = 0
        for (index, exercise) in exercises.enumerated() where index >= exerciseIndex {
            if exercise.sets < 1 {
                total += Self.descriptorSeconds(named: exercise.name, fallback: descriptorSeconds)
                continue
            }
            let perSet = exercise.holdSeconds.map { $0 + Self.holdLeadInSeconds } ?? workSecondsPerSet
            let setsAhead = index == exerciseIndex
                ? max(0, exercise.sets - currentSet + 1)
                : exercise.sets
            let restsAhead = index == exerciseIndex && isResting
                ? max(0, setsAhead)             // the in-flight rest, plus one between each pair ahead
                : max(0, setsAhead - 1)
            total += setsAhead * perSet + restsAhead * max(0, exercise.restSeconds)
        }
        return total
    }

    /// A descriptor step's seconds: the minutes its trailing clause names ("Steady cardio - 20 min"
    /// → 1,200), else `fallback`. The rule of the domain's `WorkoutProgram.descriptorMinutes(in:)` —
    /// the first of " - ", " – ", " — " splits, and the clause must be a number then "min" — spelled
    /// here because this shared file cannot import the domain (a test pins the two equal).
    nonisolated static func descriptorSeconds(named name: String, fallback: Int) -> Int {
        for separator in [" - ", " – ", " — "] {
            guard let range = name.range(of: separator) else { continue }
            let clause = name[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let digits = clause.prefix(while: \.isNumber)
            let unit = clause.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
            guard let minutes = Int(digits), minutes > 0, minutes <= 600, unit.hasPrefix("min") else { return fallback }
            return minutes * 60
        }
        return fallback
    }

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
            setStartedAt = now
            phase = .working
        } else {
            finish()
        }
    }

    /// End the rest early and resume the next set (counters were advanced when the rest began).
    mutating func skipRest(now: Date = Date()) {
        guard phase == .resting else { return }
        restStartedAt = nil
        restEndsAt = nil
        if currentExercise == nil {
            finish()
        } else {
            setStartedAt = now
            phase = .working
        }
    }

    /// Skip the rest of the warm-up (to the first step after it) or of the cool-down. Skipping the
    /// cool-down finishes the run NATURALLY — the work is done, so it is logged — and so does a
    /// warm-up with nothing after it. Any other block is left alone (`canSkipBlock` is false there).
    mutating func skipBlock(now: Date) {
        guard canSkipBlock else { return }
        let block = currentBlock
        let next = exercises.indices.first { $0 > exerciseIndex && exercises[$0].block != block }
        guard block == BlockToken.warmUp, let next else {
            finish()
            return
        }
        exerciseIndex = next
        currentSet = 1
        restStartedAt = nil
        restEndsAt = nil
        setStartedAt = now
        phase = .working
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

    // MARK: Load tracking (in-app only; the Live Activity never edits these)

    /// The index of the step with `id`, or nil.
    private func index(of id: UUID) -> Int? {
        exercises.firstIndex { $0.id == id }
    }

    /// The weight the lifter picked for one lift, snapped to the equipment's step and kept positive.
    mutating func selectWeight(_ weight: Double?, forExercise id: UUID) {
        guard let index = index(of: id), var tracking = exercises[index].tracking, tracking.isLoadable else { return }
        if let weight, let step = tracking.step, step > 0, weight.isFinite {
            tracking.selected = max(step, (weight / step).rounded() * step)
        } else {
            tracking.selected = nil
        }
        exercises[index].tracking = tracking
    }

    /// The reps of each set when they differed. All-on-target clears the edit (back to "as
    /// prescribed"). A missed max attempt drops the attempts after it.
    mutating func setActualReps(_ reps: [Int], forExercise id: UUID) {
        guard let index = index(of: id), var tracking = exercises[index].tracking else { return }
        let clean = Array(reps.prefix(Tracking.maxSets)).map { max(0, $0) }
        let asPrescribed = Array(repeating: tracking.targetReps, count: max(1, exercises[index].sets))
        tracking.actualReps = clean == asPrescribed ? nil : clean
        exercises[index].tracking = tracking
        if tracking.calibrationRaw == CalibrationToken.attempt, clean.allSatisfy({ $0 == 0 }) {
            dropAttempts(after: index)
        }
    }

    /// How the lift felt; nil clears it.
    mutating func setEffort(_ raw: String?, forExercise id: UUID) {
        guard let index = index(of: id), exercises[index].tracking != nil else { return }
        exercises[index].tracking?.effortRaw = raw
    }

    /// Why the lifter left the range; nil clears it.
    mutating func setOverrideReason(_ raw: String?, forExercise id: UUID) {
        guard let index = index(of: id), exercises[index].tracking != nil else { return }
        exercises[index].tracking?.overrideReasonRaw = raw
    }

    /// Marks the current lift skipped before the runner jumps past it.
    mutating func markCurrentSkipped() {
        guard exercises.indices.contains(exerciseIndex), exercises[exerciseIndex].tracking != nil else { return }
        exercises[exerciseIndex].tracking?.skipped = true
    }

    /// Removes the remaining max attempts of the same lift after a miss: only steps after both
    /// `index` and the cursor, so the cursor stays on the step it was on.
    private mutating func dropAttempts(after index: Int) {
        let name = exercises[index].name
        let floor = max(index, exerciseIndex)
        exercises = exercises.enumerated().compactMap { offset, exercise in
            let isLaterAttempt = offset > floor && exercise.name == name
                && exercise.tracking?.calibrationRaw == CalibrationToken.attempt
            return isLaterAttempt ? nil : exercise
        }
    }

    // MARK: Live Activity mapping

    /// Snapshot into the Live Activity content. The three-case run phase collapses to the activity's
    /// two cases: only `.resting` shows the countdown; `.working`/`.done` render as `.working` (the
    /// activity is ended the instant a run finishes, so `.done`'s rendered phase is moot).
    var contentState: WorkoutActivityAttributes.ContentState {
        WorkoutActivityAttributes.ContentState(
            exerciseName: currentExercise?.displayedName ?? "",
            setNumber: currentSet,
            totalSets: totalSetsForCurrent,
            reps: currentExercise?.reps ?? "",
            phase: phase == .resting ? .resting : .working,
            restStartedAt: restStartedAt,
            restEndsAt: restEndsAt,
            exerciseIndex: exerciseIndex,
            totalExercises: totalExercises,
            holdStartsAt: holdWindow?.lowerBound,
            holdEndsAt: holdWindow?.upperBound,
            blockRaw: currentExercise?.blockRaw,
            sideRaw: currentExercise?.sideRaw
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
        if let hold = holdWindow {
            return hold.upperBound.addingTimeInterval(Staleness.restGrace)
        }
        return now.addingTimeInterval(Staleness.workingCap)
    }
}
