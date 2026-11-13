// WorkoutPlanner+TravelDay.swift
// FernletScoring
//
// The travel-day session (World-Airports-Spec §13.2, approved screen 32; owner 2026-10-30 night: "on
// travel days, it should suggest lighter workouts or promote more cardio focused workouts due to all
// the sitting on a plane and at the airport"). A fixed list of moves already in the library, chosen by
// one yes/no: the app's travel-day answer — and, since 2026-11-10 (the owner's fix e2), run through the
// person's injury limits and hidden exercises like every other plan. Nothing about a flight, an airport, a time or a place ever
// reaches this file (the §13.1 wall); nothing here is AI.

import Foundation
import FernletDomainModel

extension WorkoutPlanner {
    /// The minutes the session's easy walk is timed for: the middle of the approved 20–30.
    public static let travelDayWalkMinutes = 25
    /// How long each of the travel session's stretches is held, each side (the approved "30 s").
    public static let travelDayHoldSeconds = 30
    /// Cat-cow's eight slow rounds, timed as one hold (about 5 s a round).
    public static let travelDayCatCowSeconds = 40
    /// The session's approved length, about 40 minutes (the walk, then about 15 minutes of moves).
    public static let travelDayMinutes = 40

    /// The travel session's walk line: plan text the runner times as one easy, steady segment and
    /// `WorkoutPlanLine` draws in the person's language. Frozen English, like every plan's line.
    public static var travelDayWalkLine: String { "Easy walk - \(travelDayWalkMinutes) min" }

    /// The frozen catalog names of the travel session's eight moves, in order (§13.2): every one is in
    /// the bundled library (`ExerciseHowTo+Conditioning`, `+Legs`, `+Stretches`). Treadmill walk is the
    /// indoor stand-in for the first. The calf raise is the bodyweight "Calf raise": "Standing calf
    /// raise" is the machine row, which an airport hotel room does not have (the owner's fix e2).
    public static let travelDayMoveNames = [
        "Easy walk", "Calf raise", "Glute bridge", "Low lunge stretch",
        "Figure-four stretch", "Cat-cow", "Thread the needle", "Calf stretch",
    ]

    /// One move of the travel session as the approved list writes it.
    struct TravelDayMove {
        /// The frozen catalog name.
        let name: String
        /// Sets, for the two activation moves; 1 for a stretch.
        var sets = 1
        /// Reps, for the two activation moves; empty for a stretch.
        var reps = ""
        /// The hold, for a stretch.
        var holdSeconds: Int?
        /// Whether a stretch is done on both sides.
        var bothSides = false
        /// The approved plan-text figure when it is not simply the hold ("8 slow", "5 each side").
        var figure: String?
    }

    /// The approved list after the walk: two light activation moves, then five stretches.
    static let travelDayMoves: [TravelDayMove] = [
        TravelDayMove(name: "Calf raise", sets: 2, reps: "15"),
        TravelDayMove(name: "Glute bridge", sets: 2, reps: "12"),
        TravelDayMove(name: "Low lunge stretch", holdSeconds: travelDayHoldSeconds, bothSides: true),
        TravelDayMove(name: "Figure-four stretch", holdSeconds: travelDayHoldSeconds, bothSides: true),
        TravelDayMove(name: "Cat-cow", holdSeconds: travelDayCatCowSeconds, figure: "8 slow"),
        TravelDayMove(name: "Thread the needle", holdSeconds: travelDayHoldSeconds, bothSides: true, figure: "5 each side"),
        TravelDayMove(name: "Calf stretch", holdSeconds: travelDayHoldSeconds, bothSides: true),
    ]

    /// The minutes of seated stretching that stands in for the walk when a walk is ruled out.
    public static let travelDaySeatedMinutes = 15

    /// The travel session's steps as approved, with nothing filtered: the easy walk (a timed easy
    /// segment), calf raises 2 × 15 and glute bridges 2 × 12 as light activation work (never progressed,
    /// never a lift's history), then the stretches as holds, each one-sided stretch on both sides.
    public static var travelDaySteps: [PrescribedExercise] {
        travelDayFitted(pool: nil, limits: .empty).steps
    }

    /// The travel session's plan text as approved: one line a move, stored on a taken session.
    static var travelDayPlanText: String {
        travelDayFitted(pool: nil, limits: .empty).planText
    }

    /// The travel session run through the person's limits and hidden exercises (the owner's fix e2,
    /// 2026-11-10): its steps, its plan text, and whether the walk gave way to seated mobility.
    ///
    /// `pool` is the planner's own pool for this space — equipment, injury limits and hidden exercises
    /// already applied (``WorkoutProgram/suggestablePool(in:location:profile:preferences:)``); nil
    /// filters nothing. A move that is not in the pool is swapped for a safe one of the same kind (a
    /// stretch for a stretch, a no-equipment strength move for one) or dropped. A severe ankle, knee
    /// or hip (``InjuryLimits/barsWalking``) replaces the walk with seated mobility; a hidden walk is
    /// dropped. Bounded by the seven moves.
    static func travelDayFitted(
        pool: [ExerciseTarget]?, limits: InjuryLimits
    ) -> (steps: [PrescribedExercise], planText: String, seated: Bool) {
        var steps: [PrescribedExercise] = []
        var lines: [String] = []
        let walkAllowed = pool.map { $0.contains { $0.name == "Easy walk" } } ?? true
        let seated = limits.barsWalking
        if seated {
            let line = "\(WorkoutProgram.seatedMobilityHead) - \(travelDaySeatedMinutes) min"
            steps.append(PrescribedExercise(name: line, sets: 0, reps: "", role: .accessory, fromCatalog: false))
            lines.append(line)
        } else if walkAllowed {
            steps.append(PrescribedExercise(name: travelDayWalkLine, sets: 0, reps: "", role: .accessory,
                                            fromCatalog: false, block: .cardio))
            lines.append(travelDayWalkLine)
        }
        var taken = Set(travelDayMoves.map(\.name))
        for move in travelDayMoves {
            guard let fitted = travelDayMove(move, pool: pool, taken: &taken) else { continue }
            steps += travelDaySteps(for: fitted.move, unilateral: fitted.unilateral)
            lines.append(travelDayLine(for: fitted.move, unilateral: fitted.unilateral))
        }
        return (steps, lines.joined(separator: "\n"), seated)
    }

    /// `move` as the pool allows it: itself, a safe move of the same kind in its place, or nil
    /// (dropped). `taken` holds the names already in the session, so nothing is done twice.
    static func travelDayMove(
        _ move: TravelDayMove, pool: [ExerciseTarget]?, taken: inout Set<String>
    ) -> (move: TravelDayMove, unilateral: Bool)? {
        guard let pool else { return (move, move.bothSides) }
        if pool.contains(where: { $0.name == move.name }) { return (move, move.bothSides) }
        let original = WorkoutExerciseCatalog.exercise(named: move.name)
        let wanted = original?.primaryMuscles ?? []
        let stretch = move.holdSeconds != nil
        let swaps = pool.filter { candidate in
            guard !taken.contains(candidate.name), candidate.requiredGear.isEmpty,
                  !candidate.primaryMuscles.isDisjoint(with: wanted) else { return false }
            if stretch { return candidate.modality == .mobility }
            return candidate.modality == .strength && candidate.measure == .reps
                && candidate.equipment == .bodyweight && candidate.difficulty != .advanced
        }
        guard let swap = swaps.min(by: { ($0.difficulty.rawValue, $0.name) < ($1.difficulty.rawValue, $1.name) }) else {
            return nil
        }
        taken.insert(swap.name)
        let fitted = TravelDayMove(name: swap.name, sets: move.sets, reps: move.reps,
                                   holdSeconds: stretch ? travelDayHoldSeconds : nil, bothSides: swap.unilateral)
        return (fitted, swap.unilateral)
    }

    /// One move's steps: an activation move as its sets, a stretch as a hold on each side it has.
    static func travelDaySteps(for move: TravelDayMove, unilateral: Bool) -> [PrescribedExercise] {
        guard let hold = move.holdSeconds else {
            return [PrescribedExercise(name: move.name, sets: move.sets, reps: move.reps, role: .accessory,
                                       fromCatalog: true, block: .activation)]
        }
        let sides: [ExerciseSide?] = unilateral ? ExerciseSide.allCases : [nil]
        return sides.map { side in
            PrescribedExercise(
                name: move.name, sets: 1, reps: PrescribedExercise.holdText(seconds: hold), role: .accessory,
                fromCatalog: true, restSecondsOverride: 0, block: .coolDown, holdSeconds: hold, side: side
            )
        }
    }

    /// One move's plan-text line ("Calf raise - 2 x 15", "Calf stretch - 30 s each side").
    static func travelDayLine(for move: TravelDayMove, unilateral: Bool) -> String {
        guard let hold = move.holdSeconds else { return "\(move.name) - \(move.sets) x \(move.reps)" }
        if let figure = move.figure { return "\(move.name) - \(figure)" }
        let text = PrescribedExercise.holdText(seconds: hold)
        return unilateral ? "\(move.name) - \(text) each side" : "\(move.name) - \(text)"
    }

    /// The travel-day session as today's whole plan (§13.2): one guided session, "Travel-day reset",
    /// saved under its frozen `WorkoutFallbackName` with the approved reason line as its note
    /// (`WorkoutFallbackCopy/travelDayNote`). `locationName` is the active workout space, as every
    /// plan carries. `pool` and `limits` run the list through the person's limits and hidden
    /// exercises (`travelDayFitted(pool:limits:)`); the defaults filter nothing.
    public static func travelDayPlan(
        locationName: String, pool: [ExerciseTarget]? = nil, limits: InjuryLimits = .empty
    ) -> WorkoutProgram.DayPlan {
        let name = WorkoutFallbackName.travelDayReset.rawValue
        let fitted = travelDayFitted(pool: pool, limits: limits)
        let note = fitted.seated ? WorkoutFallbackCopy.travelDaySeatedNote : WorkoutFallbackCopy.travelDayNote
        let session = WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: .cardio, exercises: fitted.steps,
            suggestion: WorkoutSuggestion(name: name, exercises: fitted.planText, notes: note)
        )
        return WorkoutProgram.DayPlan(splitName: name, dayTitle: name, sessions: [session], droppedSlots: [],
                                      locationName: locationName)
    }

    /// The moves of a travel-day session as its card lists them, in order: each catalog move once
    /// (a stretch's two sides are one move), a walk or seated-mobility line by its label.
    public static func travelDayMoveNames(in session: WorkoutProgram.SessionSuggestion) -> [String] {
        var names: [String] = []
        for step in session.exercises {
            let name = step.fromCatalog ? step.name : WorkoutTimedSessions.label(of: step.name)
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Whether `plan` is the travel-day session (its one session saved under the frozen name).
    public static func isTravelDayPlan(_ plan: WorkoutProgram.DayPlan) -> Bool {
        plan.sessions.count == 1 && plan.sessions.first?.suggestion.name == WorkoutFallbackName.travelDayReset.rawValue
    }

    /// ``suggestion(energy:goal:context:goals:)``, chosen by the travel-day yes/no: on a travel day the
    /// travel session as one loggable workout (light, about 40 minutes), whatever the energy; otherwise
    /// the energy-matched suggestion as before.
    public static func suggestion(
        energy: WorkoutIntensity, goal: String, context: String, goals: [FitnessGoal], travelDay: Bool
    ) -> Workout {
        guard travelDay else { return suggestion(energy: energy, goal: goal, context: context, goals: goals) }
        return Workout(name: WorkoutFallbackName.travelDayReset.rawValue, type: .cardio, exercises: travelDayPlanText,
                       rpe: nil, notes: WorkoutFallbackCopy.travelDayNote, duration: travelDayMinutes, intensity: .light)
    }
}

extension WorkoutFallbackCopy {
    /// The reason line when a severe ankle, knee or hip took the walk out of the session.
    static var travelDaySeatedNote: String {
        String(localized: "workoutFallback.note.travelDayReset.seated",
               defaultValue: "Lots of sitting today: some seated stretches, working around your limits.",
               bundle: .module,
               comment: "The reason line under the travel-day workout when an ankle, knee or hip injury rules out its walk: stretches done sitting or lying down instead")
    }

    /// The travel session's one reason line (§13.2, approved; the owner's note on 33 left it the only
    /// explanation the session gives).
    static var travelDayNote: String {
        String(localized: "workoutFallback.note.travelDayReset",
               defaultValue: "Lots of sitting today: an easy walk and some stretches for your legs, hips and back.",
               bundle: .module,
               comment: "The one reason line under the workout Fernlet suggests on a travel day (a flight's date, or the day after an overnight flight)")
    }
}
