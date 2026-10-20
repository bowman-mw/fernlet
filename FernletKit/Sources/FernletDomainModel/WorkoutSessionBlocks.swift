import Foundation

/// Builds the blocks that wrap a lifting session: the warm-up stretch flow, the activation block
/// (light core, balance, and low-rep jumps when they fit), and the cool-down's long holds.
///
/// The session runs in ``SessionBlock`` order — stretch, activate, lift, any cardio, cool down — the
/// owner's layout (2026-10-19). Every step is a catalog row run through the same equipment and
/// injury filter as the lifts (the caller passes the already-filtered `feasible` list), so a knee
/// note drops the lunge stretches and the jumps exactly as it drops lunges. Deterministic: the same
/// inputs always build the same steps.
///
/// The hold lengths follow the stretching evidence the owner was shown: before lifting or jumping,
/// static holds of about 30 s or less per muscle cost no meaningful strength or power, while holds of
/// 60 s or more do (Behm et al. 2016), so the warm-up holds 20–30 s and the long holds wait for the
/// cool-down.
public nonisolated enum WorkoutSessionBlocks {

    /// One step of a stretch flow: a catalog movement, how long it is held, and which side.
    public struct FlowStep: Sendable, Equatable {
        public let name: String
        public let seconds: Int
        public let side: ExerciseSide?

        public init(name: String, seconds: Int, side: ExerciseSide? = nil) {
            self.name = name
            self.seconds = seconds
            self.side = side
        }
    }

    /// A warm-up stretch's hold — short enough not to blunt the lifting that follows.
    public static let warmUpHoldSeconds = 20
    /// The seated and floor holds in the warm-up, which the owner's flow lingers on a little longer.
    public static let warmUpLongHoldSeconds = 30
    /// A cool-down hold: the long static stretch, once the heavy work is done.
    public static let coolDownHoldSeconds = 45
    /// A light activation hold (a plank, a single-leg stance).
    public static let activationHoldSeconds = 20
    /// Movements the cool-down holds, at most (each one-sided move is two steps).
    static let coolDownMoves = 4

    /// The owner's warm-up flow, in their order: touch the toes, lunge, back up to the toes, the
    /// inner-thigh side lunge, back into the lunge, the lying leg stretch — then all of that again for
    /// the other leg; butterfly, a few yoga moves, a balancing quad stretch each side, the wide-leg
    /// fold, and arm stretches. About eight minutes.
    public static var warmUpFlow: [FlowStep] {
        let short = warmUpHoldSeconds
        let long = warmUpLongHoldSeconds
        var steps: [FlowStep] = []
        for side in ExerciseSide.allCases {
            steps += [
                FlowStep(name: "Standing forward fold", seconds: short),
                FlowStep(name: "Low lunge stretch", seconds: short, side: side),
                FlowStep(name: "Standing forward fold", seconds: short),
                FlowStep(name: "Side lunge stretch", seconds: short, side: side),
                FlowStep(name: "Low lunge stretch", seconds: short, side: side),
                FlowStep(name: "Lying hamstring stretch", seconds: short, side: side),
            ]
        }
        steps += [
            FlowStep(name: "Butterfly stretch", seconds: long),
            FlowStep(name: "Cat-cow", seconds: long),
            FlowStep(name: "Downward dog", seconds: short),
            FlowStep(name: "Child's pose", seconds: short),
            FlowStep(name: "Standing quad stretch", seconds: short, side: .left),
            FlowStep(name: "Standing quad stretch", seconds: short, side: .right),
            FlowStep(name: "Wide-leg forward fold", seconds: short),
            FlowStep(name: "Cross-body shoulder stretch", seconds: short, side: .left),
            FlowStep(name: "Cross-body shoulder stretch", seconds: short, side: .right),
            FlowStep(name: "Overhead triceps stretch", seconds: short, side: .left),
            FlowStep(name: "Overhead triceps stretch", seconds: short, side: .right),
        ]
        return steps
    }

    /// The warm-up steps this lifter can do here: the flow, minus any stretch the injury filter
    /// removed (it is not in `feasible`).
    static func warmUp(feasible: [ExerciseTarget]) -> [PrescribedExercise] {
        let allowed = Set(feasible.map(\.name))
        return warmUpFlow.filter { allowed.contains($0.name) }.map { step in
            timedStep(name: step.name, seconds: step.seconds, side: step.side, block: .warmUp)
        }
    }

    /// The cool-down: up to ``coolDownMoves`` long-hold stretches for the muscles the lifting
    /// worked, each one-sided move both sides.
    ///
    /// Chosen greedily for coverage: each pick is the stretch that reaches the most worked muscles
    /// not stretched yet (then overall overlap, then name), so a leg day ends on hamstrings, quads
    /// and glutes rather than four hamstring stretches.
    static func coolDown(worked: Set<MuscleGroup>, feasible: [ExerciseTarget]) -> [PrescribedExercise] {
        var remaining = feasible.filter { $0.modality == .mobility }
        var covered: Set<MuscleGroup> = []
        var picked: [ExerciseTarget] = []
        for _ in 0..<coolDownMoves {
            let scored = remaining.map { stretch -> (ExerciseTarget, Int) in
                let fresh = stretch.primaryMuscles.intersection(worked.subtracting(covered)).count
                let overlap = stretch.primaryMuscles.intersection(worked).count
                let secondary = stretch.secondaryMuscles.intersection(worked).count
                return (stretch, fresh * 10 + overlap * 3 + secondary)
            }
            guard let best = scored.filter({ $0.1 > 0 }).min(by: { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }) else {
                break
            }
            picked.append(best.0)
            covered.formUnion(best.0.primaryMuscles)
            remaining.removeAll { $0.name == best.0.name }
        }
        var steps: [PrescribedExercise] = []
        for stretch in picked {
            let sides: [ExerciseSide?] = stretch.unilateral ? ExerciseSide.allCases : [nil]
            for side in sides {
                steps.append(timedStep(name: stretch.name, seconds: coolDownHoldSeconds, side: side, block: .coolDown))
            }
        }
        return steps
    }

    /// The balance drill and, when it fits, the jumps that follow the activation core work.
    ///
    /// Balance for everyone (NASM's stabilization work). Jumps only for a trained lifter on a goal
    /// that wants power, on a day that is not light, in a session that trains the legs — and never
    /// for a beginner, whose first block stays low-impact. Low reps (2 × 4) so they prime rather
    /// than tire.
    static func balanceAndJumps(
        feasible: [ExerciseTarget], experience: ExperienceLevel, goal: GoalType,
        intensity: WorkoutIntensity, trainsLegs: Bool
    ) -> [PrescribedExercise] {
        let byName = Dictionary(feasible.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var steps: [PrescribedExercise] = []
        if byName["Single-leg stance"] != nil {
            let hold = experience == .advanced ? 30 : activationHoldSeconds
            for side in ExerciseSide.allCases {
                steps.append(timedStep(name: "Single-leg stance", seconds: hold, side: side, block: .activation))
            }
        }
        let jumpGoals: Set<GoalType> = [.strength, .sportsPrep, .weightManagement, .exploring]
        let wantsJumps = experience != .beginner && jumpGoals.contains(goal) && intensity != .light && trainsLegs
        if wantsJumps, byName["Squat jump"] != nil {
            steps.append(PrescribedExercise(
                name: "Squat jump", sets: 2, reps: "4", role: .accessory, fromCatalog: true,
                restSecondsOverride: 45, block: .activation
            ))
        }
        return steps
    }

    /// A one-set timed step with no rest after it (the next step simply starts).
    static func timedStep(name: String, seconds: Int, side: ExerciseSide?, block: SessionBlock) -> PrescribedExercise {
        PrescribedExercise(
            name: name, sets: 1, reps: PrescribedExercise.holdText(seconds: seconds), role: .accessory,
            fromCatalog: true, restSecondsOverride: 0, block: block, holdSeconds: seconds, side: side
        )
    }

    /// Whole minutes a block's timed steps take, rounded up (the summary line's "- 9 min").
    public static func minutes(of steps: [PrescribedExercise]) -> Int {
        let seconds = steps.reduce(0) { $0 + max(1, $1.sets) * ($1.holdSeconds ?? 0) }
        return max(1, (seconds + 59) / 60)
    }

    /// The session's plan text: one summary line for the warm-up and one for the cool-down (their
    /// steps live in the guided run, not the log), and a line per activation, lifting and cardio
    /// movement in between. This is what a logged workout records, so it stays frozen English — the
    /// history parser and `descriptorMinutes` read it back — and a screen draws each line through
    /// ``WorkoutPlanLine/displayed(_:)`` (2026-10-20, idea 16).
    public static func planText(for exercises: [PrescribedExercise]) -> String {
        planText(for: exercises, loggedLines: [:])
    }

    /// ``planText(for:)`` with some steps' lines replaced — what a finished guided run logs: each
    /// tracked lift's own line ("Bench press - 3 x 8 @ 105 lb (did 8, 8, 6)") in place of its plan line.
    public static func planText(for exercises: [PrescribedExercise], loggedLines: [UUID: String]) -> String {
        let warmUp = exercises.filter { $0.block == .warmUp }
        let coolDown = exercises.filter { $0.block == .coolDown }
        var lines: [String] = []
        if !warmUp.isEmpty { lines.append("Warm-up stretch flow - \(minutes(of: warmUp)) min") }
        lines += exercises.filter { $0.block != .warmUp && $0.block != .coolDown }.map { loggedLines[$0.id] ?? $0.line }
        if !coolDown.isEmpty { lines.append("Cool-down stretches - \(minutes(of: coolDown)) min") }
        return lines.joined(separator: "\n")
    }
}
