// WorkoutPlannerCopy.swift
// FernletDomainModel
//
// Every sentence the workout planner writes into a session note, as String Catalog keys (2026-10-20,
// idea 16 of the comparison report). The notes used to be English literals built by concatenation, so
// a Spanish, French or German plan would still have read in English after the translation phase.
//
// A note is composed when the plan is built and stored on the logged row as text (`Workout.notes`),
// in the language the device ran then. That is deliberate and stays: a stored note is never
// re-translated. What this file guarantees is that the COMPOSITION is translatable — each sentence is
// one key with its arguments as format specifiers a translator can reorder, and every counted noun is
// a plural-ruled count phrase (``repCount(_:)``, ``setCount(_:)``, ``weekCount(_:)``, ``hourCount(_:)``).
//
// Exercise names reach these sentences in the person's language (2026-10-20, N8): a note builder draws
// each frozen catalog name through ``WorkoutPlannerCopy/exerciseName(_:)`` or ``exerciseList(_:)``
// (``ExerciseHowToCatalog/displayName(for:)``) as it composes the note, the same name the plan card and
// the runner draw. The planner itself keeps the frozen name everywhere else — the plan text, the log,
// the progression keys, exports and prompts — and nothing ever reads a note back, so a drawn name in a
// stored note can never re-identify a lift.

import Foundation

/// The workout planner's note sentences, each a `String(localized:…, bundle: .module)` key.
///
/// English output is byte-for-byte what the planner wrote before the sentences moved here. Lists of
/// names arrive already joined (", ", which reads correctly in English, Spanish, French and German).
/// Stateless and `nonisolated`: the planner calls it from nonisolated code.
public nonisolated enum WorkoutPlannerCopy {

    // MARK: - Count phrases (plural-ruled)

    /// "12 reps".
    static func repCount(_ count: Int) -> String {
        String(localized: "workoutNote.count.reps", defaultValue: "\(count) reps", bundle: .module,
               comment: "Workout session note: a number of repetitions of a lift, e.g. '12 reps'. Placed inside other note sentences.")
    }

    /// "3 sets".
    static func setCount(_ count: Int) -> String {
        String(localized: "workoutNote.count.sets", defaultValue: "\(count) sets", bundle: .module,
               comment: "Workout session note: a number of sets of a lift, e.g. '3 sets'. Placed inside other note sentences.")
    }

    /// "3 weeks".
    static func weekCount(_ count: Int) -> String {
        String(localized: "workoutNote.count.weeks", defaultValue: "\(count) weeks", bundle: .module,
               comment: "Workout session note: a number of weeks, e.g. '3 weeks'. Placed inside other note sentences.")
    }

    /// "48 hours".
    static func hourCount(_ count: Int) -> String {
        String(localized: "workoutNote.count.hours", defaultValue: "\(count) hours", bundle: .module,
               comment: "Workout session note: a number of hours, e.g. '48 hours'. Placed inside other note sentences.")
    }

    // MARK: - Exercise names (N8)

    /// An exercise as a note names it: the frozen catalog name `name` drawn in the person's language
    /// (``ExerciseHowToCatalog/displayName(for:)``), or a custom or typed name as it is. Display only —
    /// the planner passes the frozen name everywhere else.
    static func exerciseName(_ name: String) -> String {
        ExerciseHowToCatalog.displayName(for: name)
    }

    /// Exercises as a note lists them: each drawn by ``exerciseName(_:)``, joined with ", " (which reads
    /// correctly in English, Spanish, French and German), in the order given.
    static func exerciseList(_ names: [String]) -> String {
        names.map { exerciseName($0) }.joined(separator: ", ")
    }

    // MARK: - Session-level notes (WorkoutProgram)

    /// "Noted: <what the person typed>".
    static func noted(_ context: String) -> String {
        String(localized: "workoutNote.noted", defaultValue: "Noted: \(context)", bundle: .module,
               comment: "Workout session note: echoes the note the person typed when asking for a plan. The argument is their own text.")
    }

    /// The person's injury limits shaped the plan.
    static var workedAroundLimits: String {
        String(localized: "workoutNote.workedAroundLimits", defaultValue: "Worked around your noted limits.", bundle: .module,
               comment: "Workout session note: the plan avoided the body areas or movements the person said to work around")
    }

    /// "Skipped Hinge, Core — no safe option here."
    static func skippedNoSafeOption(_ slots: String) -> String {
        String(localized: "workoutNote.skipped.noSafeOption",
               defaultValue: "Skipped \(slots) — no safe option here.", bundle: .module,
               comment: "Workout session note: parts of the session left out because nothing at this location was safe for them. The argument is a comma-separated list of slot names, e.g. 'Hinge, Core'.")
    }

    /// "Skipped Hinge — the only options here are ones you've hidden."
    static func skippedHidden(_ slots: String) -> String {
        String(localized: "workoutNote.skipped.hidden",
               defaultValue: "Skipped \(slots) — the only options here are ones you've hidden.", bundle: .module,
               comment: "Workout session note: parts of the session left out because the only exercises that fit are ones the person chose not to be suggested. The argument is a comma-separated list of slot names.")
    }

    /// The AI adjuster reshaped the lifting to the person's request.
    static var adjustedToNote: String {
        String(localized: "workoutNote.adjusted", defaultValue: "Adjusted to your note.", bundle: .module,
               comment: "Workout session note: the exercises were changed on device to match what the person asked for")
    }

    /// The note on the "just move" session a split with nothing to render falls back to.
    static var simpleOption: String {
        String(localized: "workoutNote.simpleOption", defaultValue: "A simple option for today.", bundle: .module,
               comment: "Workout session note on the fallback session: an easy full-body circuit offered when nothing else could be planned")
    }

    /// The rest-day plan's note (the app's ``WorkoutProgram/DayPlan`` for a day marked unwell).
    public static var restDayNote: String {
        String(localized: "workoutNote.restDay",
               defaultValue: "You marked yourself unwell, so rest is the real plan today. This is here only if moving would feel good.",
               bundle: .module,
               comment: "Workout session note on a day the person marked themselves unwell: rest is the plan, the gentle movement is optional")
    }

    // MARK: - The 48-hour guard (WorkoutRecoveryGuard)

    /// "Push today instead of Legs — those muscles worked hard in the last 48 hours."
    static func recoveryMoved(to day: String, from due: String, hours: Int) -> String {
        String(localized: "workoutNote.recovery.moved",
               defaultValue: "\(day) today instead of \(due) — those muscles worked hard in the last \(hourCount(hours)).",
               bundle: .module,
               comment: "Workout session note: the planner moved to a different day of the split. Arguments: the day planned (e.g. 'Push'), the day that was due (e.g. 'Legs'), and a number of hours (e.g. '48 hours').")
    }

    /// "One set fewer on Back squat, Lunge — those muscles worked hard in the last 48 hours."
    static func recoveryLightened(lifts: String, hours: Int) -> String {
        String(localized: "workoutNote.recovery.lightened",
               defaultValue: "One set fewer on \(lifts) — those muscles worked hard in the last \(hourCount(hours)).",
               bundle: .module,
               comment: "Workout session note: some lifts get one set fewer because the same muscles trained hard recently. Arguments: a comma-separated list of exercise names, and a number of hours (e.g. '48 hours').")
    }

    // MARK: - The time budget (WorkoutSessionBudget)

    /// "Shortened to fit 30 min."
    static func budgetShortened(minutes: Int) -> String {
        String(localized: "workoutNote.budget.shortened", defaultValue: "Shortened to fit \(minutes) min.", bundle: .module,
               comment: "Workout session note: a cardio or mobility session was cut to the person's session length. The argument is minutes.")
    }

    /// "Fitted to 30 min: shorter warm-up; fewer sets of Bench press."
    static func budgetFitted(minutes: Int, changes: String) -> String {
        String(localized: "workoutNote.budget.fitted", defaultValue: "Fitted to \(minutes) min: \(changes).", bundle: .module,
               comment: "Workout session note: the session was trimmed to fit the person's session length. Arguments: minutes, then a semicolon-separated list of what changed (e.g. 'shorter warm-up; fewer sets of Bench press').")
    }

    /// "Runs about 34 min — over your 30 min, but as short as today's session goes with its main lifts
    /// kept." with or without the trims that were made.
    static func budgetOver(estimated: Int, budget: Int, changes: String?) -> String {
        guard let changes else {
            return String(localized: "workoutNote.budget.over",
                          defaultValue: "Runs about \(estimated) min — over your \(budget) min, but as short as today's session goes with its main lifts kept.",
                          bundle: .module,
                          comment: "Workout session note: even trimmed, the session runs past the person's session length. Arguments: the estimated minutes, then the chosen session length in minutes.")
        }
        return String(localized: "workoutNote.budget.overTrimmed",
                      defaultValue: "Runs about \(estimated) min — over your \(budget) min, but as short as today's session goes with its main lifts kept. Trimmed: \(changes).",
                      bundle: .module,
                      comment: "Workout session note: even trimmed, the session runs past the person's session length. Arguments: the estimated minutes, the chosen session length in minutes, and a semicolon-separated list of what was trimmed.")
    }

    /// One change in a budget note: the short warm-up flow stood in for the full one.
    static var budgetShorterWarmUp: String {
        String(localized: "workoutNote.budget.shorterWarmUp", defaultValue: "shorter warm-up", bundle: .module,
               comment: "Part of a list in a workout session note, after 'Fitted to 30 min:' — the warm-up stretches were shortened. Lowercase in English because it continues a sentence.")
    }

    /// One change in a budget note: cool-down stretches were dropped.
    static var budgetFewerCoolDown: String {
        String(localized: "workoutNote.budget.fewerCoolDown", defaultValue: "fewer cool-down stretches", bundle: .module,
               comment: "Part of a list in a workout session note, after 'Fitted to 30 min:' — some cool-down stretches were left out")
    }

    /// One change in a budget note: "left out Squat jump, Cable curl".
    static func budgetLeftOut(_ names: String) -> String {
        String(localized: "workoutNote.budget.leftOut", defaultValue: "left out \(names)", bundle: .module,
               comment: "Part of a list in a workout session note, after 'Fitted to 30 min:' — exercises left out. The argument is a comma-separated list of exercise names.")
    }

    /// One change in a budget note: "fewer sets of Bench press".
    static func budgetFewerSets(_ names: String) -> String {
        String(localized: "workoutNote.budget.fewerSets", defaultValue: "fewer sets of \(names)", bundle: .module,
               comment: "Part of a list in a workout session note, after 'Fitted to 30 min:' — some exercises got fewer sets. The argument is a comma-separated list of exercise names.")
    }

    /// One change in a budget note: "one warm-up set for Back squat" — a lift's warm-up ramp was cut to
    /// its one set nearest 60 % of the working weight.
    static func budgetOneWarmUpSet(_ names: String) -> String {
        String(localized: "workoutNote.budget.oneWarmUpSet", defaultValue: "one warm-up set for \(names)", bundle: .module,
               comment: "Part of a list in a workout session note, after 'Fitted to 30 min:' — a lift's lighter warm-up sets were cut to just one. The argument is a comma-separated list of exercise names.")
    }
}
