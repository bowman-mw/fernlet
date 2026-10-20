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
        /// Last time's numbers for this lift, baked in when the run starts so the Live Activity can
        /// show them with no app state; nil for a step never logged, a timed or uncounted step, and a
        /// run persisted before the Live Activity showed them.
        var lastTime: LastTime?
        /// Seconds of "get ready" before this timed step's hold; nil is the usual
        /// ``GuidedWorkoutRunState/holdLeadInSeconds``. A cardio segment that follows straight on from
        /// the one before carries 0 — an interval's easy part starts the moment its hard part ends.
        var leadInSeconds: Int?
        /// The timed cardio segment this step is — its pace, round and source line; nil otherwise.
        var segment: Segment?
        /// Seconds of this step actually timed so far, added as each of its sets is moved on from (its
        /// countdown running out, "Next", a skip, the Lock Screen) — kept for a cardio segment or a
        /// stretch-session step only, and what such a run logs as its length. Nil until then.
        var heldSeconds: Int?
        /// A planned workout's line exactly as written, when it says more than this step shows (a coach's
        /// cue, "each side") — drawn under the name. Nil on every other step, and in an older run.
        var writtenLine: String?

        init(
            id: UUID = UUID(), name: String, sets: Int, reps: String, roleRaw: String, fromCatalog: Bool,
            restSeconds: Int, holdSeconds: Int? = nil, blockRaw: String? = nil, sideRaw: String? = nil,
            tracking: Tracking? = nil, displayName: String? = nil, lastTime: LastTime? = nil,
            leadInSeconds: Int? = nil, segment: Segment? = nil
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
            self.lastTime = lastTime
            self.leadInSeconds = leadInSeconds
            self.segment = segment
        }

        /// The step's block, with an untagged step (any run built before blocks existed) as lifting.
        var block: String { blockRaw ?? BlockToken.lifting }

        /// The name a screen, a spoken transition or the Live Activity draws: ``displayName`` when
        /// the app baked one in, else the frozen ``name``.
        var displayedName: String { displayName ?? name }

        /// This step's lead-in before its hold starts, in seconds — never negative.
        var holdLeadIn: Int { max(0, leadInSeconds ?? GuidedWorkoutRunState.holdLeadInSeconds) }

        /// The exercise this step belongs to, for the changeover estimate: the domain's
        /// `WorkoutSessionTime.exerciseKey(_:)`, spelled here because this file cannot import the domain
        /// (a test pins the two equal). Nil for a warm-up or cool-down stretch, which takes no changeover;
        /// one key for a whole stretch session; a cardio segment's plan line; else the frozen name.
        var changeoverKey: String? {
            switch block {
            case BlockToken.warmUp, BlockToken.coolDown: return nil
            case BlockToken.mobility: return BlockToken.mobility
            default: return segment?.descriptor ?? name
            }
        }

        /// A ramp-up set: a warm-up set before a heavy lift, or a calibration's ramp — light, one set,
        /// never a working set. The runner calls both "Warm-up set"; the log tags both "(ramp-up)".
        var isRampSet: Bool { tracking?.calibrationRaw == CalibrationToken.ramp }
    }

    /// One timed cardio segment (the domain `CardioSegment`), spelled as tokens because this shared
    /// file cannot import the domain.
    struct Segment: Codable, Hashable {
        /// "steady" | "hard" | "easy" — a ``PaceToken`` value.
        var paceRaw: String
        /// The 1-based round of an interval set, and the rounds in all; nil for a steady segment.
        var round: Int?
        var rounds: Int?
        /// The plan line the segment was read from — what the log folds the segments back into.
        var descriptor: String
    }

    /// The pace tokens, spelled here because this shared file cannot import the domain: each equals the
    /// domain `CardioPace` case's raw value (pinned by a test), and like it is FROZEN.
    nonisolated enum PaceToken {
        static let steady = "steady"
        static let hard = "hard"
        static let easy = "easy"
    }

    /// The heart-rate zone a segment of pace `paceRaw` aims for: 4 for an interval's hard part, 2 for an
    /// easy or steady one. Spelled here because this shared file cannot import the domain; equal to
    /// `HeartRateZones.targetZone(for:)` for every pace (pinned by a test). An unknown token (a newer
    /// build's) aims as steady, which only ever changes a cue on screen.
    nonisolated static func targetZone(paceRaw: String) -> Int {
        paceRaw == PaceToken.hard ? 4 : 2
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
        /// The weight came written in a planned workout's line: `suggested` is that weight, preselected as
        /// written, with no range around it. Nil for the engine's own suggestion, and in an older run.
        var asWritten: Bool?
        /// The loads the location owns for this lift's gear, lightest first, at most ``maxLoads`` (R6,
        /// 2026-10-20): the lighter and heavier buttons step through these instead of by ``step``. Nil
        /// when the location's weights say nothing, and in a run persisted before they were carried —
        /// optional, so such a run still decodes.
        var loads: [Double]?

        /// Sets an edit may carry at most.
        static let maxSets = 20
        /// Owned loads a run carries for one lift at most (the planner sends 48 around the suggestion).
        static let maxLoads = 64

        /// The weight one tap of the lighter (`direction` −1) or heavier (+1) button picks: the next
        /// owned load that way when the location's weights are known, else one ``step``. At the end of
        /// the owned loads it stays put; with nothing picked yet it starts from `start`.
        func steppedWeight(direction: Int, start: Double?) -> Double? {
            guard let selected else { return start }
            guard let loads, !loads.isEmpty else {
                return step.map { selected + Double(direction.signum()) * $0 }
            }
            if direction > 0 { return loads.first { $0 > selected + 0.01 } ?? selected }
            return loads.last { $0 < selected - 0.01 } ?? selected
        }

        /// `weight` placed on the owned loads (the nearest, a tie going lighter), or on the step when
        /// none are known.
        func snapped(_ weight: Double) -> Double? {
            if let loads, !loads.isEmpty {
                var best = loads[0]
                for load in loads.prefix(Self.maxLoads) where abs(load - weight) < abs(best - weight) - 1e-9 { best = load }
                return best
            }
            guard let step, step > 0 else { return nil }
            return max(step, (weight / step).rounded() * step)
        }

        /// The lift takes a load: the runner shows its weight picker.
        var isLoadable: Bool { step != nil && unitRaw != nil }

        /// The chosen weight sits outside the prescribed range.
        var isOutsideRange: Bool {
            guard let selected, let rangeLow, let rangeHigh else { return false }
            return selected < rangeLow - 0.01 || selected > rangeHigh + 0.01
        }
    }

    /// Last time's numbers for one lift — the logged history the runner's "Last time" pill reads
    /// (`FernletStore.exerciseHistoryEntries()`), carried as numbers so the widget formats them in its
    /// own locale. Display only; every field optional, so a partial record still decodes.
    struct LastTime: Codable, Hashable {
        var sets: Int?
        /// The reps as logged ("8", "8-10").
        var reps: String?
        var weight: Double?
        /// "lb" | "kg" — the domain `LoadUnit` raw value; nil when the logged line never said.
        var unitRaw: String?
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
        static let mobility = "mobility"
    }

    /// Seconds between a timed step starting and its hold starting: time to get into position, so a
    /// 20-second stretch is held for 20 seconds, not 15. `nonisolated` so the Move tab's nonisolated
    /// time estimate can read it under the app target's default main-actor isolation.
    nonisolated static let holdLeadInSeconds = 5

    /// The changeover before each exercise after the run's first — moving to the next station, loading a
    /// bar. The domain's `WorkoutSessionTime.changeoverSeconds`, spelled here because this file cannot
    /// import the domain (a test pins the two equal), so a started run counts down from the plan card's
    /// estimate.
    nonisolated static let changeoverSeconds = 60

    /// One "−15 s" / "+15 s" tap on the Lock Screen, the Dynamic Island or the runner. The buttons'
    /// words spell the same 15 (pinned by a test).
    nonisolated static let restAdjustStepSeconds = 15
    /// A "−15 s" never leaves less than this much of a rest: it shortens, it does not skip.
    nonisolated static let minimumRestLeftSeconds = 5
    /// A "+15 s" never stretches a rest past this, counted from when the rest began.
    nonisolated static let maximumRestSeconds = 10 * 60

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

    /// The planned workout this run walks — a row the person planned ahead or a coach's plan put on the
    /// calendar — which a natural finish completes, as "log it" does. Nil for the app's own sessions,
    /// and in a run persisted before planned workouts could be guided.
    var plannedWorkoutID: UUID?

    /// True when the lifter answered "no" to the Ready screen's optional "Eaten in the last few
    /// hours?" (G12, `WorkoutFuelCheck`). Every tracked lift's result carries it, so a shortfall in the
    /// later sets is held rather than counted as a miss; it never changes a weight. Nil when not asked,
    /// answered "yes", or in a run persisted before the question existed — which decodes unchanged.
    var unfueled: Bool?

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
    /// A "−15 s" / "+15 s" (``adjustRest(by:now:)``) moves it with the window.
    var restDuration: Int
    /// When the current set began — stamped on start, on moving to the next exercise, and on leaving
    /// a rest. A timed step's hold window counts from here (``holdWindow``); nil in a run persisted
    /// before holds existed, which then simply shows no countdown.
    var setStartedAt: Date?
    /// True only after the run was walked all the way to the end. An abandon leaves it false, so
    /// nothing is logged.
    var completedNaturally: Bool
    /// When the run began: stamped once when the app starts it and never moved, so a run resumed
    /// after a relaunch, or advanced from the Lock Screen, keeps its real start. The logged
    /// workout's duration counts from here. Nil in a run persisted before durations were recorded,
    /// which then logs without one.
    var startedAt: Date?
    /// When the run finished naturally, stamped by the finishing transition itself, so a finish
    /// tapped on the Lock Screen and logged at the app's next reconcile still ends at the tap. Nil
    /// until then, and after an abandon.
    var finishedAt: Date?
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
        guard phase == .working, let exercise = currentExercise, let hold = exercise.holdSeconds, hold > 0,
              let setStartedAt else {
            return nil
        }
        let start = setStartedAt.addingTimeInterval(TimeInterval(exercise.holdLeadIn))
        return start...start.addingTimeInterval(TimeInterval(hold))
    }

    /// The current step's block, or lifting when there is none.
    var currentBlock: String { currentExercise?.block ?? BlockToken.lifting }

    /// The current step's 1-based position within its block, and the block's size ("Warm-up · 3 of 23").
    /// A lift's ramp-up sets count as the lift they lead into, so a session with warm-up sets still
    /// reads "Exercise 2 of 5" — the card itself says "Warm-up set 1 of 3".
    var blockPosition: (index: Int, count: Int) {
        let block = currentBlock
        let indices = exercises.indices.filter { exercises[$0].block == block && !exercises[$0].isRampSet }
        let anchor = currentExercise?.isRampSet == true
            ? indices.first(where: { $0 > exerciseIndex }) ?? exerciseIndex
            : exerciseIndex
        let position = (indices.firstIndex(of: anchor) ?? 0) + 1
        return (position, max(1, indices.count))
    }

    /// The current step's place among its lift's ramp-up sets ("Warm-up set 2 of 3"): the ramp-up
    /// steps of the same lift in a row around the cursor. Nil on any other step.
    var warmUpPosition: (index: Int, count: Int)? {
        guard currentExercise?.isRampSet == true else { return nil }
        let run = warmUpRun(around: exerciseIndex)
        return (exerciseIndex - run.lowerBound + 1, run.count)
    }

    /// Whether the rest of the current lift's warm-up sets can be skipped — the runner's quiet "Skip
    /// warm-up sets" secondary, on a ramp-up step whose lift is still ahead.
    var canSkipWarmUpSets: Bool {
        guard isWorking || isResting, currentExercise?.isRampSet == true else { return false }
        return warmUpRun(around: exerciseIndex).upperBound < exercises.count - 1
    }

    /// The ramp-up steps of one lift in a row that include `index` (just `index` off a ramp-up step).
    /// Bounded: each walk moves one step at a time inside `exercises`.
    private func warmUpRun(around index: Int) -> ClosedRange<Int> {
        guard exercises.indices.contains(index) else { return index...index }
        let name = exercises[index].name
        var start = index
        while start > 0, exercises[start - 1].isRampSet, exercises[start - 1].name == name { start -= 1 }
        var end = index
        while end + 1 < exercises.count, exercises[end + 1].isRampSet, exercises[end + 1].name == name { end += 1 }
        return start...end
    }

    /// Whether the rest of the current block can be skipped from here — the runner's quiet "Skip
    /// warm-up" / "Skip cool-down" secondary, and "Skip cardio" / "Finish early" while a timed cardio
    /// or stretch block still has more ahead (on its last step, "Next" does the same thing).
    var canSkipBlock: Bool {
        guard isWorking || isResting else { return false }
        switch currentBlock {
        case BlockToken.warmUp, BlockToken.coolDown: return true
        case BlockToken.cardio, BlockToken.mobility: return hasMoreOfCurrentBlock
        default: return false
        }
    }

    /// Whether a later step belongs to the current step's block.
    var hasMoreOfCurrentBlock: Bool {
        let block = currentBlock
        return exercises.indices.contains { $0 > exerciseIndex && exercises[$0].block == block }
    }

    /// Whether anything follows the current block — a skipped cardio block hands over to it ("Skip
    /// cardio"); with nothing after, the skip finishes the session ("Finish early").
    var hasStepAfterCurrentBlock: Bool {
        let block = currentBlock
        return exercises.indices.contains { $0 > exerciseIndex && exercises[$0].block != block }
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
    ///   sets (`sets - 1` rests per exercise); an in-flight rest counts as one whole rest of its own
    ///   window's length, so a "+15 s" or "−15 s" moves the estimate with it;
    /// - a descriptor line (`sets == 0` — cardio/mobility walked as one step) costs the minutes it
    ///   names ("Conditioning intervals - 12 min"), else `descriptorSeconds` (default 5 min);
    /// - the working phase counts the current set as still ahead; the resting phase counts the
    ///   upcoming set (the counter already advanced when the rest began);
    /// - each exercise still ahead after the run's first adds a ``changeoverSeconds`` changeover
    ///   (``changeoverSecondsAhead()``); the current step's own changeover is already behind it.
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
            // A timed cardio part's get-ready lead-in is left out, as the plan card's estimate leaves it out.
            let leadIn = exercise.segment == nil ? exercise.holdLeadIn : 0
            let perSet = exercise.holdSeconds.map { $0 + leadIn } ?? workSecondsPerSet
            let setsAhead = index == exerciseIndex
                ? max(0, exercise.sets - currentSet + 1)
                : exercise.sets
            // The in-flight rest at its own (possibly adjusted) length, plus one between each pair ahead.
            let inFlightRest = index == exerciseIndex && isResting
                ? inFlightRestSeconds(fallback: exercise.restSeconds) : 0
            let restsBetween = max(0, setsAhead - 1)
            total += setsAhead * perSet + restsBetween * max(0, exercise.restSeconds) + inFlightRest
        }
        return total + changeoverSecondsAhead()
    }

    /// The changeovers still ahead, in seconds: one ``changeoverSeconds`` before each step after the
    /// current one that starts an exercise (``Exercise/changeoverKey``, a key other than the step
    /// before it's), unless it starts the run's first exercise. The domain's
    /// `WorkoutSessionTime.changeovers(in:)` counted from the current step, so a run starts at the plan
    /// card's total. Bounded: one pass over `exercises`.
    func changeoverSecondsAhead() -> Int {
        var previousKey: String?
        var started = false
        var ahead = 0
        for (index, exercise) in exercises.enumerated() {
            let key = exercise.changeoverKey
            let startsExercise = key != nil && key != previousKey
            previousKey = key
            guard startsExercise else { continue }
            if started && index > exerciseIndex { ahead += 1 }
            started = true
        }
        return ahead * Self.changeoverSeconds
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

    /// The in-flight rest's whole length: its fixed window, which "−15 s" / "+15 s" move, or
    /// `fallback` (the exercise's baked rest) when the window is missing.
    private func inFlightRestSeconds(fallback: Int) -> Int {
        guard let start = restStartedAt, let end = restEndsAt, start <= end else { return max(0, fallback) }
        return Int(end.timeIntervalSince(start).rounded())
    }

    // MARK: Transitions (pure — mirror the old WorkoutSessionRunner state machine)

    /// Mark the current set done. More sets of this exercise → rest; last set of this exercise →
    /// straight to the next exercise; last set of the last exercise → done.
    mutating func markSetDone(now: Date) {
        guard phase == .working, let exercise = currentExercise else { return }
        recordHeld(now: now)
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
            finish(at: now)
        }
    }

    /// End the rest early and resume the next set (counters were advanced when the rest began).
    mutating func skipRest(now: Date = Date()) {
        guard phase == .resting else { return }
        restStartedAt = nil
        restEndsAt = nil
        if currentExercise == nil {
            finish(at: now)
        } else {
            setStartedAt = now
            phase = .working
        }
    }

    /// Move the current rest's end by `seconds` — the "−15 s" / "+15 s" buttons. Returns whether it moved.
    ///
    /// A shorter rest never ends sooner than ``minimumRestLeftSeconds`` from `now` (a rest already
    /// that close, or over, is left alone — "Skip rest" ends it). A longer one starts from `now` when
    /// the timer has already run out, so "+15 s" over 0:00 means fifteen more seconds, and never runs
    /// past ``maximumRestSeconds`` from the rest's start. Only the end moves: the window stays fixed
    /// and ordered (`restStartedAt <= restEndsAt`), so the countdowns never invert; `restDuration`
    /// and the time-left estimate follow it.
    mutating func adjustRest(by seconds: Int, now: Date) -> Bool {
        guard phase == .resting, seconds != 0, let start = restStartedAt, let end = restEndsAt, start <= end else {
            return false
        }
        let earliestEnd = max(start, now.addingTimeInterval(TimeInterval(Self.minimumRestLeftSeconds)))
        let proposed: Date
        if seconds > 0 {
            let latestEnd = start.addingTimeInterval(TimeInterval(Self.maximumRestSeconds))
            proposed = min(max(end, now).addingTimeInterval(TimeInterval(seconds)), latestEnd)
            guard proposed > end, proposed >= earliestEnd else { return false }
        } else {
            proposed = max(end.addingTimeInterval(TimeInterval(seconds)), earliestEnd)
            guard proposed < end else { return false }
        }
        restEndsAt = proposed
        restDuration = Int(proposed.timeIntervalSince(start).rounded())
        return true
    }

    /// Skip the rest of the warm-up or of a timed cardio block (to the first step after it), or of the
    /// cool-down or a stretch session. Skipping the cool-down finishes the run NATURALLY — the work is
    /// done, so it is logged — and so does a block with nothing after it ("Finish early": the run logs
    /// the time actually held). Any other block is left alone (`canSkipBlock` is false there).
    mutating func skipBlock(now: Date) {
        guard canSkipBlock else { return }
        recordHeld(now: now)
        let block = currentBlock
        let next = exercises.indices.first { $0 > exerciseIndex && exercises[$0].block != block }
        // A timed cardio block hands over to what follows it (the cool-down), as the warm-up does.
        if block == BlockToken.cardio, let next {
            exerciseIndex = next
            currentSet = 1
            restStartedAt = nil
            restEndsAt = nil
            setStartedAt = now
            phase = .working
            return
        }
        guard block == BlockToken.warmUp, let next else {
            finish(at: now)
            return
        }
        exerciseIndex = next
        currentSet = 1
        restStartedAt = nil
        restEndsAt = nil
        setStartedAt = now
        phase = .working
    }

    /// Skip the current lift's remaining warm-up sets, the current one included, to its first working
    /// set — "Skip warm-up sets". The skipped sets are marked skipped, so the log leaves them out; any
    /// done before stay logged as ramp-ups. Nothing else moves (`canSkipWarmUpSets` guards it).
    mutating func skipWarmUpSets(now: Date) {
        guard canSkipWarmUpSets else { return }
        let run = warmUpRun(around: exerciseIndex)
        for index in exerciseIndex...run.upperBound where exercises[index].tracking != nil {
            exercises[index].tracking?.skipped = true
        }
        exerciseIndex = run.upperBound + 1
        currentSet = 1
        restStartedAt = nil
        restEndsAt = nil
        setStartedAt = now
        phase = .working
    }

    /// Adds the current timed set's held seconds to its step — from the end of its lead-in to `now`, no
    /// more than the hold, no less than nothing — for a cardio segment or a stretch-session step only,
    /// whose run logs its length from them (`GuidedRunTimedLog`).
    private mutating func recordHeld(now: Date) {
        guard let window = holdWindow, exercises.indices.contains(exerciseIndex),
              currentBlock == BlockToken.cardio || currentBlock == BlockToken.mobility else { return }
        let hold = window.upperBound.timeIntervalSince(window.lowerBound)
        let held = min(max(0, now.timeIntervalSince(window.lowerBound)), hold)
        exercises[exerciseIndex].heldSeconds = (exercises[exerciseIndex].heldSeconds ?? 0) + Int(held.rounded())
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

    /// The natural finish, stamped with the transition's own time (``finishedAt``).
    private mutating func finish(at now: Date) {
        restStartedAt = nil
        restEndsAt = nil
        completedNaturally = true
        finishedAt = now
        phase = .done
    }

    // MARK: Load tracking (in-app only; the Live Activity never edits these)

    /// The index of the step with `id`, or nil.
    private func index(of id: UUID) -> Int? {
        exercises.firstIndex { $0.id == id }
    }

    /// The weight the lifter picked for one lift, snapped to the location's owned loads when the run
    /// carries them (R6), else to the equipment's step, and kept positive.
    mutating func selectWeight(_ weight: Double?, forExercise id: UUID) {
        guard let index = index(of: id), var tracking = exercises[index].tracking, tracking.isLoadable else { return }
        if let weight, weight.isFinite, let placed = tracking.snapped(weight) {
            tracking.selected = placed
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
            sideRaw: currentExercise?.sideRaw,
            load: currentLoad,
            paceRaw: currentExercise?.segment?.paceRaw,
            round: currentExercise?.segment?.round,
            rounds: currentExercise?.segment?.rounds,
            zone: currentZone,
            warmUpSet: warmUpPosition?.index,
            warmUpSets: warmUpPosition?.count
        )
    }

    /// The current segment's heart-rate cue as the run alone knows it: the zone its pace aims for, which
    /// the widget words as the talk test. Nil on every other step. The live reading is the app's to lay
    /// over it (`GuidedZoneDirector`) — the run never stores a heart rate.
    var currentZone: WorkoutActivityAttributes.ContentState.Zone? {
        guard let segment = currentExercise?.segment else { return nil }
        return WorkoutActivityAttributes.ContentState.Zone(target: Self.targetZone(paceRaw: segment.paceRaw))
    }

    /// The current set's load line for the Live Activity — the weight the runner shows (the
    /// suggestion, preselected, or the lifter's own pick), the engine's range, and last time's
    /// numbers. Display only. Nil for a timed step and for a step with nothing to show.
    var currentLoad: WorkoutActivityAttributes.ContentState.Load? {
        guard let exercise = currentExercise, exercise.holdSeconds == nil else { return nil }
        let tracking = exercise.tracking?.isLoadable == true ? exercise.tracking : nil
        let last = exercise.lastTime
        let load = WorkoutActivityAttributes.ContentState.Load(
            weight: tracking?.selected, suggested: tracking?.suggested,
            rangeLow: tracking?.rangeLow, rangeHigh: tracking?.rangeHigh, unitRaw: tracking?.unitRaw,
            lastSets: last?.sets, lastReps: last?.reps, lastWeight: last?.weight, lastUnitRaw: last?.unitRaw
        )
        return load.isEmpty ? nil : load
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
