// WorkoutPlanner+TravelDay.swift
// FernletScoring
//
// The travel-day session (World-Airports-Spec §13.2, approved screen 32; owner 2026-10-30 night: "on
// travel days, it should suggest lighter workouts or promote more cardio focused workouts due to all
// the sitting on a plane and at the airport"). A fixed list of moves already in the library, chosen by
// one yes/no: the app's travel-day answer. Nothing about a flight, an airport, a time or a place ever
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
    /// indoor stand-in for the first.
    public static let travelDayMoveNames = [
        "Easy walk", "Standing calf raise", "Glute bridge", "Low lunge stretch",
        "Figure-four stretch", "Cat-cow", "Thread the needle", "Calf stretch",
    ]

    /// The travel session's steps, as the guided runner walks them: the easy walk (a timed easy
    /// segment), calf raises 2 × 15 and glute bridges 2 × 12 as light activation work (never progressed,
    /// never a lift's history), then the stretches as holds, each one-sided stretch on both sides.
    public static var travelDaySteps: [PrescribedExercise] {
        var steps = [
            PrescribedExercise(name: travelDayWalkLine, sets: 0, reps: "", role: .accessory, fromCatalog: false,
                               block: .cardio),
            PrescribedExercise(name: "Standing calf raise", sets: 2, reps: "15", role: .accessory, fromCatalog: true,
                               block: .activation),
            PrescribedExercise(name: "Glute bridge", sets: 2, reps: "12", role: .accessory, fromCatalog: true,
                               block: .activation),
        ]
        let holds: [(name: String, seconds: Int, sides: Bool)] = [
            ("Low lunge stretch", travelDayHoldSeconds, true), ("Figure-four stretch", travelDayHoldSeconds, true),
            ("Cat-cow", travelDayCatCowSeconds, false), ("Thread the needle", travelDayHoldSeconds, true),
            ("Calf stretch", travelDayHoldSeconds, true),
        ]
        // Bounded: five stretches, at most two sides each.
        for hold in holds {
            let sides: [ExerciseSide?] = hold.sides ? ExerciseSide.allCases : [nil]
            for side in sides {
                steps.append(PrescribedExercise(
                    name: hold.name, sets: 1, reps: PrescribedExercise.holdText(seconds: hold.seconds), role: .accessory,
                    fromCatalog: true, restSecondsOverride: 0, block: .coolDown, holdSeconds: hold.seconds, side: side
                ))
            }
        }
        return steps
    }

    /// The travel session's plan text: one line a move, stored on a taken session like any plan's.
    static var travelDayPlanText: String {
        let hold = PrescribedExercise.holdText(seconds: travelDayHoldSeconds)
        return [
            travelDayWalkLine, "Standing calf raise - 2 x 15", "Glute bridge - 2 x 12",
            "Low lunge stretch - \(hold) each side", "Figure-four stretch - \(hold) each side",
            "Cat-cow - 8 slow", "Thread the needle - 5 each side", "Calf stretch - \(hold) each side",
        ].joined(separator: "\n")
    }

    /// The travel-day session as today's whole plan (§13.2): one guided session, "Travel-day reset",
    /// saved under its frozen ``WorkoutFallbackName`` with the approved reason line as its note
    /// (``WorkoutFallbackCopy/travelDayNote``). `locationName` is the active workout space, as every
    /// plan carries.
    public static func travelDayPlan(locationName: String) -> WorkoutProgram.DayPlan {
        let name = WorkoutFallbackName.travelDayReset.rawValue
        let session = WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: .cardio, exercises: travelDaySteps,
            suggestion: WorkoutSuggestion(name: name, exercises: travelDayPlanText, notes: WorkoutFallbackCopy.travelDayNote)
        )
        return WorkoutProgram.DayPlan(splitName: name, dayTitle: name, sessions: [session], droppedSlots: [],
                                      locationName: locationName)
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
    /// The travel session's one reason line (§13.2, approved; the owner's note on 33 left it the only
    /// explanation the session gives).
    static var travelDayNote: String {
        String(localized: "workoutFallback.note.travelDayReset",
               defaultValue: "Lots of sitting today: an easy walk and some stretches for your legs, hips and back.",
               bundle: .module,
               comment: "The one reason line under the workout Fernlet suggests on a travel day (a flight's date, or the day after an overnight flight)")
    }
}
