// WorkoutPlanFinisher.swift
// FernletDomainModel
//
// The one finishing pass every plan goes through, however it was made (the owner's fix s1, 2026-11-10,
// review finding E5). The planner used to finish its own sessions in its tail — ease the lifts that load
// a mild area, take a set off muscles worked hard inside 48 hours, fit the time budget, give holds a
// countdown, write the note — and nothing else did. "Adjust with AI" replaced the lifting block and gave
// it weights and a ramp back; the editor's swap and a hand edit saved the rows as typed. So a mild-knee
// Leg press could come back 6 × 5 as a main lift, a session fitted to 30 minutes could run 45 under a
// note still saying it was fitted, and a Plank could return as the text "30 sec" with no countdown.
//
// Now there is one pass, and three ways in:
// - the planner's tail hands it the session's blocks straight from the slot picks
//   (``WorkoutPlanFinisher/settle(_:goal:recentHard:budgetMinutes:)``): the 48-hour trim and the time
//   budget run here and nowhere else;
// - an AI adjustment hands it the model's picks (``WorkoutPlanFinisher/adjusted(_:picks:request:pool:others:context:)``);
// - the plan editor hands it the edited rows (``WorkoutPlanFinisher/finish(_:previous:others:origin:context:)``).
// The last two first put the lifts in the state the planner's picks arrive in — a real hold on every
// timed movement, a lift that loads a mild area prescribed as accessory work, no repeat of the
// activation move or of another of today's sessions' lifts, a weight from the lift's own history, the
// warm-up ramp only where the planner would put one (never on an assisted lift) — and then run the same
// trim, the same budget, and rebuild the note from what the pass did (``WorkoutNotePart``).
//
// A session the pass has already finished comes back from it untouched: `WorkoutPlanFinisherTests`
// finishes freshly generated plans over many profiles and requires nothing to change. That is what
// keeps the planner's picks and this file from drifting apart.
//
// What is the person's stays the person's. In a hand edit the rows are theirs: the pass never drops
// one, and never changes the sets or reps of a lift that was already in the session. A lift they add or
// swap in is finished like a planner's pick. Pure and deterministic over its inputs.

import Foundation

/// One line of a session's note, and what it is about — so a later finishing pass can keep the lines
/// that are still true, rewrite its own, and drop the rest.
///
/// A generated session carries its note as these parts (`WorkoutProgram.SessionSuggestion.noteParts`);
/// the note text is always ``text(of:)`` of them. They are not written to today's plan file: a session
/// read back from it has none, and the pass then rebuilds its note from nothing.
public nonisolated struct WorkoutNotePart: Equatable, Sendable {
    /// What a note line is about.
    public enum Kind: String, Sendable {
        /// About the session as a whole (the space, the limits, a skipped slot): kept.
        case session
        /// About lifts as they were planned (a weight step, a strength check): kept only while every
        /// lift it names still stands with the same sets and reps.
        case lifts
        /// The time budget's line: rewritten by every pass. Empty text when there is nothing to say.
        case budget
        /// The 48-hour guard's "one set fewer" line: rewritten by every pass; `lifts` are the lifts
        /// it names.
        case recovery
        /// "Adjusted to your note.", once.
        case adjusted
    }

    /// What the line is about.
    public var kind: Kind
    /// The line, in the device's language when it was composed; empty for a slot with nothing to say.
    public var text: String
    /// The frozen names of the lifts the line is about; empty for a line about the session.
    public var lifts: [String]

    /// Creates a part.
    public init(_ kind: Kind, _ text: String, lifts: [String] = []) {
        self.kind = kind
        self.text = text
        self.lifts = lifts
    }

    /// The note for `parts`: every line that says something, in order.
    public static func text(of parts: [WorkoutNotePart]) -> String {
        parts.map(\.text).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The finishing pass (this file's header).
public nonisolated enum WorkoutPlanFinisher {

    /// How a session's lifting block came to change.
    public enum Origin: Sendable {
        /// The on-device model's picks: every lift is finished like a planner's pick.
        case adjustment
        /// The plan editor's rows (a swap, an add, a typed number): the rows are the person's.
        case handEdit
    }

    /// What the pass needs to know about the day — the same facts the planner built the plan from.
    public struct Context {
        /// The goal, for the rest between sets and the eased prescription.
        public var goal: GoalType
        /// The intensity the plan was committed with; nil when no plan is committed.
        public var intensity: WorkoutIntensity?
        /// The profile's sport, which shapes the goal's style.
        public var sport: String
        /// The limits in force today: the saved ones with today's "Anything else?" laid over them.
        public var limits: InjuryLimits
        /// Whether any of ``limits`` is a saved one (the note then says limits were worked around).
        public var savedLimitsApply: Bool
        /// The space the plan is for.
        public var location: WorkoutLocation
        /// The lifts' logged sessions; nil leaves weights and ramps as they are.
        public var load: WorkoutLoadContext?
        /// The muscles worked hard inside the 48-hour window.
        public var recentHard: Set<MuscleGroup>
        /// The time budget in minutes; nil for none.
        public var budgetMinutes: Int?
        /// What today's "Anything else?" applied, for a note rebuilt from nothing.
        public var todaysLines: [String]
        /// The exercises the pass may look names up in; nil for every exercise the app knows.
        public var catalog: [ExerciseTarget]?

        /// Creates a context.
        public init(
            goal: GoalType, intensity: WorkoutIntensity?, sport: String = "", limits: InjuryLimits = .empty,
            savedLimitsApply: Bool = false, location: WorkoutLocation, load: WorkoutLoadContext? = nil,
            recentHard: Set<MuscleGroup> = [], budgetMinutes: Int? = nil, todaysLines: [String] = [],
            catalog: [ExerciseTarget]? = nil
        ) {
            self.goal = goal
            self.intensity = intensity
            self.sport = sport
            self.limits = limits
            self.savedLimitsApply = savedLimitsApply
            self.location = location
            self.load = load
            self.recentHard = recentHard
            self.budgetMinutes = budgetMinutes
            self.todaysLines = todaysLines
            self.catalog = catalog
        }
    }

    /// The context for a plan built from these inputs — read the way `WorkoutProgram.dayPlan` reads
    /// them: today's note over the saved limits and the session length, and the 48-hour window as the
    /// guard counted it for the day the rotation is on.
    public static func context(
        goal: GoalType, intensity: WorkoutIntensity?, profile: WorkoutProfile, location: WorkoutLocation,
        note: String, split: TrainingSplit, rotationIndex: Int, load: WorkoutLoadContext?,
        recent: WorkoutRecoveryGuard.RecentTraining?, options: WorkoutSessionOptions, noteMayShorten: Bool
    ) -> Context {
        let today = WorkoutDayNote.Applied(context: note, saved: profile.injuryLimits, options: options,
                                           mayShorten: noteMayShorten)
        let counted = split.days.isEmpty ? nil : recent.map {
            WorkoutRecoveryGuard.counted($0, split: split, dueIndex: rotationIndex)
        }
        return Context(
            goal: goal, intensity: intensity, sport: profile.sport, limits: today.limits,
            savedLimitsApply: !today.saved.isEmpty, location: location, load: load,
            recentHard: counted?.hardMuscles ?? [], budgetMinutes: today.options.length.minutes,
            todaysLines: today.lines(matched: [])
        )
    }

    /// The most lifts one pass reads: a hand-edited session's own cap, with room to spare.
    static let maximumLifts = 60

    // MARK: - The pass itself: trim, fit

    /// A session's blocks on their way into the pass, with what it must know about the lifting steps.
    struct Draft {
        /// The blocks in run order; `mainLift` marks the lifts the budget never drops.
        var blocks: WorkoutSessionBudget.Blocks
        /// The catalog row behind each lifting step (parallel to `blocks.lifting`); nil for a step
        /// the catalog does not know.
        var targets: [ExerciseTarget?]
        /// The short warm-up the budget may swap in; nil keeps the warm-up as it is.
        var shortWarmUp: [PrescribedExercise]?
        /// The sets each lift already in the session stood at, by comparison key: a tired lift here
        /// has had its trim, and is only ever held to that count. Empty for the planner's picks.
        var settledSets: [String: Int] = [:]
        /// The lifts whose numbers are the person's own (comparison keys): never trimmed.
        var held: Set<String> = []
        /// True when the lifting rows are the person's: the budget may shorten what is around them
        /// but drops none of them and cuts none of their sets.
        var liftingIsFixed = false
    }

    /// What the pass did to a draft.
    struct Settled {
        /// The blocks, trimmed and fitted.
        var blocks: WorkoutSessionBudget.Blocks
        /// The lifts that gave up a set to the 48-hour guard in this pass, by frozen name, in order.
        var lightened: [String]
        /// The budget's outcome; nil when there is no budget.
        var budget: WorkoutSessionBudget.Outcome?
    }

    /// The pass's two trims, in order: a set off every lifting step whose primary muscles worked hard
    /// inside the 48-hour window (``WorkoutRecoveryGuard``), then the time budget
    /// (``WorkoutSessionBudget``). The planner's tail and every edit run this, and nothing else trims.
    static func settle(_ draft: Draft, goal: GoalType, recentHard: Set<MuscleGroup>, budgetMinutes: Int?) -> Settled {
        let recovery = trimmedForRecovery(draft, recentHard: recentHard)
        var blocks = draft.blocks
        blocks.lifting = recovery.lifting
        guard let budgetMinutes else { return Settled(blocks: blocks, lightened: recovery.names, budget: nil) }
        var outcome = WorkoutSessionBudget.fit(blocks, budgetMinutes: budgetMinutes, goal: goal,
                                               shortWarmUp: draft.shortWarmUp)
        if draft.liftingIsFixed { outcome = keepingLifting(of: blocks, in: outcome, goal: goal) }
        return Settled(blocks: outcome.blocks, lightened: recovery.names, budget: outcome)
    }

    /// The lifting steps with the 48-hour guard's lighter sets, and the lifts it lightened. A timed
    /// hold or a single-set step keeps its one set. A lift already in the session is held to the sets
    /// it stood at (``Draft/settledSets``) rather than trimmed a second time, and a lift whose numbers
    /// are the person's (``Draft/held``) is left alone.
    static func trimmedForRecovery(
        _ draft: Draft, recentHard: Set<MuscleGroup>
    ) -> (lifting: [PrescribedExercise], names: [String]) {
        let steps = draft.blocks.lifting
        guard !recentHard.isEmpty, steps.count == draft.targets.count else { return (steps, []) }
        var result = steps
        var names: [String] = []
        for index in result.indices where result[index].fromCatalog && result[index].block == .lifting {
            guard let target = draft.targets[index], !target.primaryMuscles.isDisjoint(with: recentHard) else { continue }
            let key = WorkoutExerciseCatalog.normalizedName(result[index].name)
            guard !draft.held.contains(key) else { continue }
            let fewer = draft.settledSets[key].map { min($0, result[index].sets) }
                ?? WorkoutRecoveryGuard.lightenedSets(result[index].sets)
            guard fewer < result[index].sets else { continue }
            result[index].sets = fewer
            if !names.contains(result[index].name) { names.append(result[index].name) }
        }
        return (result, names)
    }

    /// A budget outcome with the lifting block put back as it went in — for rows that are the
    /// person's. The trims around the lifts stand; the estimate and the note are for what now runs.
    static func keepingLifting(
        of blocks: WorkoutSessionBudget.Blocks, in outcome: WorkoutSessionBudget.Outcome, goal: GoalType
    ) -> WorkoutSessionBudget.Outcome {
        var kept = outcome.blocks
        kept.lifting = blocks.lifting
        kept.mainLift = blocks.mainLift
        let lifts = Set(blocks.lifting.map(\.name))
        let trims = outcome.trims.filter { trim in
            switch trim {
            case .shortWarmUp, .coolDownStretch: return true
            case .accessory(let name): return !lifts.contains(name)
            case .accessorySet, .warmUpRamp, .mainSet: return false
            }
        }
        return WorkoutSessionBudget.Outcome(
            blocks: kept, trims: trims, estimatedSeconds: WorkoutSessionTime.seconds(of: kept.exercises, goal: goal),
            budgetMinutes: outcome.budgetMinutes
        )
    }

    /// The 48-hour guard's note part for `lifts` (frozen names): its line, or an empty slot.
    static func recoveryPart(_ lifts: [String]) -> WorkoutNotePart {
        WorkoutNotePart(.recovery, lifts.isEmpty ? "" : WorkoutRecoveryGuard.lightenedNote(lifts: lifts), lifts: lifts)
    }

    // MARK: - An edited session

    /// Whether `session` is one the pass finishes: a lifting session with at least one counted lift —
    /// not a cardio or mobility day, and not the mobility offer.
    public static func isLifting(_ session: WorkoutProgram.SessionSuggestion) -> Bool {
        guard session.kind == .strength || session.kind == .fullBody || session.kind == .sport else { return false }
        return session.exercises.contains { $0.block == .lifting && $0.fromCatalog && $0.sets >= 1 }
    }

    /// `edited` — `previous` with its lifting block changed by the model or by hand — finished.
    ///
    /// `previous` is the session as it stood, already finished; `others` are today's other sessions,
    /// whose lifts an adjustment may not repeat. A session that is not a lifting one comes back as
    /// `edited`; one the pass has nothing to do to comes back as `previous` itself, note and all.
    public static func finish(
        _ edited: WorkoutProgram.SessionSuggestion, previous: WorkoutProgram.SessionSuggestion,
        others: [WorkoutProgram.SessionSuggestion] = [], origin: Origin, context: Context
    ) -> WorkoutProgram.SessionSuggestion {
        guard isLifting(previous) else { return edited }
        let working = lifts(of: edited, previous: previous, others: others, origin: origin, context: context)
        return finished(working, edited: edited, previous: previous, origin: origin, context: context)
    }

    /// What an AI adjustment came to.
    public enum Adjustment {
        /// The session, adjusted and finished.
        case changed(WorkoutProgram.SessionSuggestion)
        /// The reply asked for what the session already is.
        case unchanged
        /// The reply would leave fewer than ``WorkoutProgram/minimumLifts`` lifts in a session that
        /// had more: refused, and the session stays as it was.
        case tooFewLifts
    }

    /// `session` with the model's `picks` as its lifting block, finished — or the reason it is left
    /// as it was.
    ///
    /// `request` is enforced here, not left to the model: a pick on equipment the person ruled out
    /// ("no barbell") is replaced by the nearest lift from `pool` that does the same work, or left
    /// out. `pool` is the filtered candidate list the model chose from. A reply that leaves fewer than
    /// ``WorkoutProgram/minimumLifts`` lifts in a session that had more is refused.
    public static func adjusted(
        _ session: WorkoutProgram.SessionSuggestion, picks: [PrescribedExercise], request: WorkoutAdjustmentRequest,
        pool: [ExerciseTarget], others: [WorkoutProgram.SessionSuggestion] = [], context: Context
    ) -> Adjustment {
        guard isLifting(session) else { return .unchanged }
        let rows = context.catalog ?? WorkoutExerciseCatalog.allExercises
        let allowed = request.enforced(on: picks, pool: pool, catalog: rows)
        guard !allowed.isEmpty else { return .tooFewLifts }
        let applied = WorkoutProgram.applyAdjustment(to: session, exercises: allowed)
        let working = lifts(of: applied, previous: session, others: others, origin: .adjustment, context: context)
        let had = liftCount(session.exercises.filter { $0.block == .lifting })
        let has = liftCount(working.map(\.step))
        guard has > 0, had <= WorkoutProgram.minimumLifts || has >= WorkoutProgram.minimumLifts else { return .tooFewLifts }
        let result = finished(working, edited: applied, previous: session, origin: .adjustment, context: context)
        return result.exercises == session.exercises ? .unchanged : .changed(result)
    }

    /// How many different counted lifts `steps` hold.
    static func liftCount(_ steps: [PrescribedExercise]) -> Int {
        Set(steps.filter { $0.fromCatalog && $0.sets >= 1 }.map { WorkoutExerciseCatalog.normalizedName($0.name) }).count
    }

    // MARK: - The lifts, as a planner's picks arrive

    /// One working lift on its way through the pass, with the catalog row behind it.
    struct Lift {
        var step: PrescribedExercise
        var target: ExerciseTarget?
    }

    /// `session`'s working lifts by comparison key, the first of each: no warm-up set and no
    /// strength-check step, whose weights are their own.
    static func standingLifts(_ session: WorkoutProgram.SessionSuggestion) -> [String: PrescribedExercise] {
        var byName: [String: PrescribedExercise] = [:]
        for step in session.exercises where step.block == .lifting && !WorkoutWarmUpSets.isWarmUpSet(step) {
            guard step.guidance?.calibration == nil else { continue }
            let key = WorkoutExerciseCatalog.normalizedName(step.name)
            if byName[key] == nil { byName[key] = step }
        }
        return byName
    }

    /// The edited lifting block as working lifts, each in the state a planner's pick arrives in: no
    /// repeat of a move today already has (an adjustment only), a kept lift standing on its own step,
    /// a real hold on a timed movement, and a lift that loads a mild area eased.
    static func lifts(
        of edited: WorkoutProgram.SessionSuggestion, previous: WorkoutProgram.SessionSuggestion,
        others: [WorkoutProgram.SessionSuggestion], origin: Origin, context: Context
    ) -> [Lift] {
        let rows = context.catalog ?? WorkoutExerciseCatalog.allExercises
        let before = standingLifts(previous)
        let style = WorkoutGoalStyle.style(for: context.goal, energy: context.intensity ?? .moderate, sport: context.sport)
        var taken = origin == .adjustment ? namesElsewhere(than: previous, others: others) : []
        // Main lifts' places, a lift under a strength check (several steps of one name) included.
        var mains = Set(previous.exercises.filter { $0.block == .lifting && $0.role == .main }.map(\.name)).count
        var result: [Lift] = []
        let rowsEdited = WorkoutWarmUpSets.removingWarmUpSets(from: edited.exercises.filter { $0.block == .lifting })
        for row in rowsEdited.prefix(maximumLifts) {
            let key = WorkoutExerciseCatalog.normalizedName(row.name)
            let target = WorkoutAdjustedLoad.target(named: row.name, in: rows)
            // A strength check's steps are the session's own, several of one name: passed through.
            guard row.guidance?.calibration == nil else {
                result.append(Lift(step: row, target: target))
                continue
            }
            if origin == .adjustment, !taken.insert(key).inserted { continue }
            var step = row
            if origin == .adjustment { step = standing(row, on: before[key], mains: &mains) }
            let isNew = before[key] == nil
            let isChanged = before[key] != step
            step = typedHold(step, target: target, style: style, fixingReps: origin == .adjustment && isChanged)
            step = eased(step, target: target, style: style, context: context,
                         numbers: origin == .adjustment ? isChanged : isNew)
            result.append(Lift(step: step, target: target))
        }
        return result
    }

    /// The comparison keys an adjusted lifting block may not repeat: the session's own activation
    /// moves, and the activation moves and lifts of today's other sessions.
    static func namesElsewhere(
        than session: WorkoutProgram.SessionSuggestion, others: [WorkoutProgram.SessionSuggestion]
    ) -> Set<String> {
        var names: Set<String> = []
        for step in session.exercises where step.fromCatalog && step.block == .activation {
            names.insert(WorkoutExerciseCatalog.normalizedName(step.name))
        }
        for other in others.prefix(maximumLifts) where other.id != session.id {
            for step in other.exercises where step.fromCatalog && (step.block == .activation || step.block == .lifting) {
                names.insert(WorkoutExerciseCatalog.normalizedName(step.name))
            }
        }
        return names
    }

    /// A model's pick standing on the session's own step. A lift the session already had keeps that
    /// step — its role, its rest, its id, and its weight while the reps are the same — with the
    /// pick's sets and reps. A new lift is a main lift only while the session has a main lift's place
    /// free for it (`mains`), so a reply cannot turn every compound pick into one.
    static func standing(_ pick: PrescribedExercise, on kept: PrescribedExercise?, mains: inout Int) -> PrescribedExercise {
        guard var step = kept else {
            var fresh = pick
            if fresh.role == .main {
                if mains > 0 { mains -= 1 } else { fresh.role = .accessory }
            }
            return fresh
        }
        if step.role == .main { mains -= 1 }
        guard step.holdSeconds == nil else { return step.sets == pick.sets ? step : resized(step, sets: pick.sets) }
        if step.reps != pick.reps {
            step.reps = pick.reps
            step.guidance = nil
        }
        step.sets = pick.sets
        return step
    }

    /// `step` with another set count.
    static func resized(_ step: PrescribedExercise, sets: Int) -> PrescribedExercise {
        var copy = step
        copy.sets = sets
        return copy
    }

    /// A timed movement always carries a real hold (`holdSeconds`), however it arrived: the seconds
    /// its text names ("30 sec", "45 s", "1 min"), else the goal's hold. With `fixingReps`, a
    /// rep-counted lift whose reps cannot be read ("30 sec" on a press) takes its role's reps.
    static func typedHold(
        _ step: PrescribedExercise, target: ExerciseTarget?, style: WorkoutGoalStyle, fixingReps: Bool
    ) -> PrescribedExercise {
        guard step.fromCatalog, let target else { return step }
        var copy = step
        if target.measure == .seconds {
            guard step.holdSeconds == nil else { return step }
            let seconds = holdSeconds(in: step.reps) ?? style.holdSeconds
            copy.holdSeconds = seconds
            copy.reps = PrescribedExercise.holdText(seconds: seconds)
            copy.guidance = nil
        } else if fixingReps, step.holdSeconds == nil, RepScheme(step.reps) == nil {
            copy.reps = style.reps(for: step.role)
            copy.guidance = nil
        }
        return copy
    }

    /// The longest hold a text may name.
    static let maximumHoldSeconds = 600

    /// The seconds a hold's text names — "30 sec", "45 s", "30-45 seconds" (its lower end), "1 min" —
    /// or nil for a text that names no time ("8-12").
    static func holdSeconds(in text: String) -> Int? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let digits = lower.prefix(while: \.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }
        let unit = lower.dropFirst(digits.count).drop { !$0.isLetter }
        if unit.hasPrefix("min") { return min(value * 60, maximumHoldSeconds) }
        return unit.hasPrefix("s") ? min(value, maximumHoldSeconds) : nil
    }

    /// A lift that loads an area being trained around (``InjuryLimits/eases(_:)``) is accessory work,
    /// as the planner prescribes it: never a main lift, so never ramped into and never a strength
    /// check. With `numbers`, its sets and reps are eased too — no more sets than accessory work gets,
    /// and no fewer reps than the accessory range starts at, so the weight that goes with them is a
    /// lighter one.
    static func eased(
        _ step: PrescribedExercise, target: ExerciseTarget?, style: WorkoutGoalStyle, context: Context, numbers: Bool
    ) -> PrescribedExercise {
        guard step.fromCatalog, let target, context.limits.eases(target) else { return step }
        var copy = step
        if copy.role == .main { copy.role = .accessory }
        guard numbers, copy.holdSeconds == nil else { return copy }
        let accessoryReps = style.reps(for: .accessory)
        if let floor = RepScheme(accessoryReps), let scheme = RepScheme(copy.reps), scheme.low < floor.low {
            copy.reps = accessoryReps
            copy.guidance = nil
        }
        copy.sets = min(copy.sets, style.adjustedSets(for: .accessory, energy: context.intensity ?? .moderate))
        return copy
    }
}
