// WorkoutSessionBudget.swift
// FernletDomainModel
//
// Fits a session into its time budget (2026-10-20, idea 5). A rival's "30 minute" workouts ran 45 to
// 60-plus minutes; a Fernlet session set to 30 minutes is planned to take 30 by the same estimate the
// plan card shows and the guided runner counts down from — or its note says plainly how long it runs.
//
// A lifting session trims in a fixed order, each step only while the session is still over:
// 1. the short warm-up — about four minutes of the owner's flow, chosen for the day's muscles;
// 2. cool-down stretches, the last-picked first, down to two;
// 3. accessory work, lowest priority first: the activation's jumps, the lifting block's accessory
//    lifts from the last one up, then the activation's balance drill;
// 4. accessory sets, one at a time from the last accessory lift, round after round, never below two;
// 5. main-lift sets, the same way, never below two.
// Main lifts are never dropped (a lift eased to accessory work for a mild injury is still the slot's
// main lift), the activation block keeps at least one move and the lifting block at least one lift.
// Nothing is ever added or made harder, so the injury limits and the 48-hour guard's lighter sets still
// hold after trimming. A cardio or mobility session is its descriptor: the minutes it names are capped
// at the budget instead.

import Foundation

/// How long a planned session takes, by the rule the guided runner counts down with.
///
/// Per step: a rep-counted set takes ``workSecondsPerSet``, a timed set its hold plus the
/// ``holdLeadInSeconds`` get-into-position lead-in, with the step's rest between its own sets (the
/// step's override, else ``WorkoutRestGuidance``'s default for the goal — the same rest the runner
/// bakes in). A descriptor line (no sets: a conditioning finisher, the fallback circuit) takes the
/// minutes it names ("Conditioning intervals - 12 min"), else ``descriptorFallbackSeconds``. The plan
/// card shows ``minutes(of:goal:)``, and a run started from the same steps begins its header countdown
/// (`GuidedWorkoutRunState.estimatedSecondsRemaining`) at the same total. Pure and deterministic.
public nonisolated enum WorkoutSessionTime {
    /// Seconds between a timed step starting and its hold starting — the runner's lead-in, spelled
    /// here because the run state cannot import the domain (a test pins the two equal).
    public static let holdLeadInSeconds = 5
    /// A rep-counted working set: a typical 8–12-rep set.
    public static let workSecondsPerSet = 45
    /// A descriptor line that names no minutes.
    public static let descriptorFallbackSeconds = 300

    /// The rest between one step's own sets: its override, else the research default for `goal`.
    public static func restSeconds(for step: PrescribedExercise, goal: GoalType) -> Int {
        step.restSecondsOverride
            ?? WorkoutRestGuidance.restSeconds(forExerciseNamed: step.name, role: step.role, goal: goal)
    }

    /// Seconds one step takes, given the rest between its sets.
    public static func seconds(of step: PrescribedExercise, restSeconds: Int) -> Int {
        guard step.sets >= 1 else { return descriptorSeconds(step.name) }
        let perSet = step.holdSeconds.map { $0 + holdLeadInSeconds } ?? workSecondsPerSet
        return step.sets * perSet + (step.sets - 1) * max(0, restSeconds)
    }

    /// Seconds one step takes under `goal`'s rest defaults.
    public static func seconds(of step: PrescribedExercise, goal: GoalType) -> Int {
        guard step.sets > 1 else { return seconds(of: step, restSeconds: 0) }
        return seconds(of: step, restSeconds: restSeconds(for: step, goal: goal))
    }

    /// Seconds a whole session takes.
    public static func seconds(of steps: [PrescribedExercise], goal: GoalType) -> Int {
        steps.reduce(0) { $0 + seconds(of: $1, goal: goal) }
    }

    /// Whole minutes a session takes, rounded up and never under one: the plan card's "~45 min".
    public static func minutes(of steps: [PrescribedExercise], goal: GoalType) -> Int {
        minutes(fromSeconds: seconds(of: steps, goal: goal))
    }

    /// Seconds rounded up to whole minutes, never under one.
    public static func minutes(fromSeconds seconds: Int) -> Int {
        max(1, (max(0, seconds) + 59) / 60)
    }

    /// A descriptor step's time: the minutes its line names; else, for an interval line the guided runner
    /// times (``WorkoutTimedSessions``), its rounds of work and easy; else ``descriptorFallbackSeconds``. A timed
    /// cardio part's get-ready lead-in is not counted here or in the runner's countdown, so a budget's capped
    /// minutes stay whole and the plan card and a started run agree.
    public static func descriptorSeconds(_ descriptor: String) -> Int {
        if let minutes = WorkoutProgram.descriptorMinutes(in: descriptor) { return minutes * 60 }
        if case .intervals(let rounds, let workSeconds, let easySeconds) = WorkoutTimedSessions.classify(descriptor) {
            return rounds * (workSeconds + easySeconds)
        }
        return descriptorFallbackSeconds
    }
    }
}

/// Fits a session into its time budget — the trim order is in this file's header.
///
/// Pure and deterministic: the same blocks and budget always trim the same way. ``fit(_:budgetMinutes:goal:shortWarmUp:)``
/// reports each trim in order (``Trim``) and the session note: what was trimmed, or — when even the
/// shortest version is over — how long the session runs.
public nonisolated enum WorkoutSessionBudget {
    /// No lift's sets are cut below this (and a lift already under it is never raised).
    public static let minimumSets = 2
    /// The cool-down keeps at least this many stretches.
    public static let minimumCoolDownMoves = 2
    /// Bound on the set-trimming rounds — far past any prescription's set count.
    static let maxSetRounds = 12

    /// One trim, in the order the budget made it.
    public enum Trim: Equatable, Sendable {
        case shortWarmUp
        case coolDownStretch(String)
        case accessory(String)
        case accessorySet(String)
        case mainSet(String)

        /// The trim's step in the order (1 … 5): the trims of a fit never step backwards.
        public var stage: Int {
            switch self {
            case .shortWarmUp: 1
            case .coolDownStretch: 2
            case .accessory: 3
            case .accessorySet: 4
            case .mainSet: 5
            }
        }
    }

    /// A lifting session's blocks on their way through the budget, in run order.
    ///
    /// `mainLift` runs parallel to `lifting`: whether each step is one of the session's main lifts,
    /// which are never dropped. Left out, it is read from each step's role.
    public struct Blocks: Equatable {
        public var warmUp: [PrescribedExercise]
        public var activation: [PrescribedExercise]
        public var lifting: [PrescribedExercise]
        public var mainLift: [Bool]
        public var cardio: [PrescribedExercise]
        public var coolDown: [PrescribedExercise]

        public init(
            warmUp: [PrescribedExercise] = [], activation: [PrescribedExercise] = [],
            lifting: [PrescribedExercise] = [], mainLift: [Bool]? = nil,
            cardio: [PrescribedExercise] = [], coolDown: [PrescribedExercise] = []
        ) {
            self.warmUp = warmUp
            self.activation = activation
            self.lifting = lifting
            let byRole = lifting.map { $0.role == .main }
            self.mainLift = mainLift.flatMap { $0.count == lifting.count ? $0 : nil } ?? byRole
            self.cardio = cardio
            self.coolDown = coolDown
        }

        /// Every step in run order: warm-up, activation, lifting, cardio, cool-down.
        public var exercises: [PrescribedExercise] { warmUp + activation + lifting + cardio + coolDown }
    }

    /// What a fit did: the trimmed blocks, each trim in order, and the estimate against the budget.
    public struct Outcome {
        public var blocks: Blocks
        public var trims: [Trim]
        public var estimatedSeconds: Int
        public var budgetMinutes: Int

        /// Whether the session now runs within its budget.
        public var fits: Bool { estimatedSeconds <= budgetMinutes * 60 }
        /// The estimate as the plan card rounds it.
        public var estimatedMinutes: Int { WorkoutSessionTime.minutes(fromSeconds: estimatedSeconds) }
        /// The session note: what was trimmed to fit, or how long the session runs when even its
        /// shortest version is over. Nil when nothing changed.
        public var note: String? { WorkoutSessionBudget.note(for: self) }
    }

    /// Fits `blocks` into `budgetMinutes`, trimming in the header's order only while the session is
    /// over. `shortWarmUp` is the warm-up to swap in at the first step (nil keeps the warm-up as it
    /// is — already short, or off).
    public static func fit(
        _ blocks: Blocks, budgetMinutes: Int, goal: GoalType, shortWarmUp: [PrescribedExercise]? = nil
    ) -> Outcome {
        let budget = max(1, budgetMinutes)
        var work = Work(blocks: blocks, budgetSeconds: budget * 60, clock: Clock(goal: goal, steps: blocks.exercises))
        if work.isOver, let short = shortWarmUp, !work.blocks.warmUp.isEmpty,
           work.clock.seconds(short) < work.clock.seconds(work.blocks.warmUp) {
            work.blocks.warmUp = short
            work.trims.append(.shortWarmUp)
        }
        trimCoolDown(&work)
        dropActivation(&work, timed: false)
        dropAccessoryLifts(&work)
        dropActivation(&work, timed: true)
        reduceSets(&work, mainLifts: false)
        reduceSets(&work, mainLifts: true)
        return Outcome(blocks: work.blocks, trims: work.trims, estimatedSeconds: work.seconds, budgetMinutes: budget)
    }

    /// A cardio or mobility session's descriptor with the minutes it names capped at the budget —
    /// "Steady cardio - 40 min" at 30 min reads "Steady cardio - 30 min" — and the note saying so.
    /// A descriptor that names no minutes, or already fits, comes back unchanged with no note.
    public static func capped(_ descriptor: String, length: WorkoutSessionLength) -> (text: String, note: String?) {
        guard let budget = length.minutes, let minutes = WorkoutProgram.descriptorMinutes(in: descriptor),
              minutes > budget else { return (descriptor, nil) }
        for separator in [" - ", " – ", " — "] {
            guard let range = descriptor.range(of: separator) else { continue }
            return ("\(descriptor[..<range.lowerBound])\(separator)\(budget) min", "Shortened to fit \(budget) min.")
        }
        return (descriptor, nil)
    }

    // MARK: - The trims

    /// The session as it is being trimmed.
    struct Work {
        var blocks: Blocks
        var trims: [Trim] = []
        let budgetSeconds: Int
        let clock: Clock

        init(blocks: Blocks, budgetSeconds: Int, clock: Clock) {
            self.blocks = blocks
            self.budgetSeconds = budgetSeconds
            self.clock = clock
        }

        var seconds: Int { clock.seconds(blocks.exercises) }
        var isOver: Bool { seconds > budgetSeconds }
    }

    /// Each step's rest, looked up once: the lookup scans the catalog by name, and the trims ask for
    /// the session's total after every change.
    struct Clock {
        private var rests: [UUID: Int] = [:]

        init(goal: GoalType, steps: [PrescribedExercise]) {
            for step in steps where step.sets > 1 && step.restSecondsOverride == nil {
                rests[step.id] = WorkoutSessionTime.restSeconds(for: step, goal: goal)
            }
        }

        /// Seconds `steps` take (``WorkoutSessionTime``), with each step's rest from the lookup.
        func seconds(_ steps: [PrescribedExercise]) -> Int {
            steps.reduce(0) { total, step in
                let rest = step.restSecondsOverride ?? rests[step.id] ?? 0
                return total + WorkoutSessionTime.seconds(of: step, restSeconds: rest)
            }
        }
    }

    /// Step 2: the cool-down's last-picked stretches go first, both sides of a one-sided stretch
    /// together, down to ``minimumCoolDownMoves``.
    static func trimCoolDown(_ work: inout Work) {
        for _ in 0..<max(1, WorkoutSessionBlocks.coolDownMoves) {
            let moves = orderedNames(work.blocks.coolDown)
            guard work.isOver, moves.count > minimumCoolDownMoves, let last = moves.last else { return }
            work.blocks.coolDown.removeAll { $0.name == last }
            work.trims.append(.coolDownStretch(last))
        }
    }

    /// Step 3's activation half: the activation's rep-counted extras (the jumps, `timed` false) or
    /// its timed ones (the balance drill, `timed` true) — never the core move, and never the block's
    /// last move.
    static func dropActivation(_ work: inout Work, timed: Bool) {
        let extras = orderedNames(work.blocks.activation.filter { $0.role != .core && ($0.holdSeconds != nil) == timed })
        for name in extras.reversed() {
            guard work.isOver, orderedNames(work.blocks.activation).count > 1 else { return }
            work.blocks.activation.removeAll { $0.name == name }
            work.trims.append(.accessory(name))
        }
    }

    /// Step 3's lifting half: the accessory lifts from the last one up. A main lift stays, and so
    /// does the block's last lift.
    static func dropAccessoryLifts(_ work: inout Work) {
        for index in work.blocks.lifting.indices.reversed() {
            guard work.isOver else { return }
            let step = work.blocks.lifting[index]
            guard !work.blocks.mainLift[index], step.sets >= 1,
                  work.blocks.lifting.filter({ $0.sets >= 1 }).count > 1 else { continue }
            work.blocks.lifting.remove(at: index)
            work.blocks.mainLift.remove(at: index)
            work.trims.append(.accessory(step.name))
        }
    }

    /// Steps 4 and 5: one set at a time from the last lift of the kind, round after round, never
    /// below ``minimumSets``.
    static func reduceSets(_ work: inout Work, mainLifts: Bool) {
        for _ in 0..<maxSetRounds {
            var reduced = false
            for index in work.blocks.lifting.indices.reversed() where work.blocks.mainLift[index] == mainLifts {
                guard work.isOver else { return }
                guard work.blocks.lifting[index].sets > minimumSets else { continue }
                work.blocks.lifting[index].sets -= 1
                let name = work.blocks.lifting[index].name
                work.trims.append(mainLifts ? .mainSet(name) : .accessorySet(name))
                reduced = true
            }
            guard reduced else { return }
        }
    }

    /// Names in first-appearance order, each once (a one-sided stretch is two steps of one name).
    static func orderedNames(_ steps: [PrescribedExercise]) -> [String] {
        var seen: Set<String> = []
        return steps.map(\.name).filter { seen.insert($0).inserted }
    }

    // MARK: - The note

    /// The session note for an outcome (``Outcome/note``). Plain English, like the planner's other
    /// notes: the plan text is persisted on the logged row and is not localized yet.
    static func note(for outcome: Outcome) -> String? {
        let changes = changeSummary(outcome.trims)
        if outcome.fits {
            guard !changes.isEmpty else { return nil }
            return "Fitted to \(outcome.budgetMinutes) min: \(changes)."
        }
        let trimmed = changes.isEmpty ? "" : " Trimmed: \(changes)."
        return "Runs about \(outcome.estimatedMinutes) min — over your \(outcome.budgetMinutes) min, but as short as "
            + "today's session goes with its main lifts kept.\(trimmed)"
    }

    /// "shorter warm-up; fewer cool-down stretches; left out Squat jump, Cable curl; fewer sets of
    /// Bench press" — the trims in order, empty when there were none.
    static func changeSummary(_ trims: [Trim]) -> String {
        var dropped: [String] = []
        var fewerSets: [String] = []
        var coolDown = false
        for trim in trims {
            switch trim {
            case .shortWarmUp: continue
            case .coolDownStretch: coolDown = true
            case .accessory(let name): dropped.append(name)
            case .accessorySet(let name), .mainSet(let name):
                if !fewerSets.contains(name) { fewerSets.append(name) }
            }
        }
        var parts: [String] = []
        if trims.contains(.shortWarmUp) { parts.append("shorter warm-up") }
        if coolDown { parts.append("fewer cool-down stretches") }
        if !dropped.isEmpty { parts.append("left out \(dropped.joined(separator: ", "))") }
        if !fewerSets.isEmpty { parts.append("fewer sets of \(fewerSets.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }
}
