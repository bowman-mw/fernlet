// WorkoutAdjustedLoad.swift
// FernletDomainModel
//
// The load pass, run again after "Adjust with AI" (round 2, R3, 2026-10-20). The on-device adjuster
// answers with lift names, sets and reps only — no weights and no warm-up sets — and
// ``WorkoutProgram/applyAdjustment(to:exercises:)`` drops them into the session as they came.
//
// Since the owner's fix s1 (2026-11-10) the re-run is part of the one finishing pass every plan goes
// through (``WorkoutPlanFinisher``): each lift's guidance (a lift the adjuster kept with the same reps
// keeps the guidance it had; any other catalog lift is prescribed from its own history, on the
// location's weights, for the person's training age), the count of compound lifts ahead of each, the
// warm-up ramp before the first heavy main lift when warm-up sets are on and the day isn't light — and
// then the easing, the 48-hour trim, the time budget and the note, which the first version left out.
// This file keeps the pieces the pass shares and the entry point the first version had.

import Foundation

/// The load side of the finishing pass for an AI-adjusted session, and the pieces the pass shares:
/// the catalog lookup and the rule for when a session ramps.
public nonisolated enum WorkoutAdjustedLoad {

    /// `adjusted` — a session after ``WorkoutProgram/applyAdjustment(to:exercises:)`` — finished as an
    /// adjustment of `original` (``WorkoutPlanFinisher/finish(_:previous:others:origin:context:)``),
    /// with no limits, no 48-hour window and no time budget in play.
    ///
    /// - A lift `original` had, with the same sets and reps, stands on the step it had there, weight
    ///   and all (never a calibration step's or a warm-up set's). Any other catalog lift is prescribed
    ///   from its own history in `load`, on `location`'s weights. Holds and lifts the catalog does not
    ///   know get none.
    /// - Each lift's `compoundsBefore` is counted again when the lifts or their order changed.
    /// - The warm-up ramp stands before the first heavy main lift when `load` has warm-up sets on and
    ///   `intensity` isn't light; with no `intensity` known, only when `original` had a ramp.
    ///
    /// `catalog` defaults to every exercise the app knows. The app's own adjustment passes the day's
    /// whole context (``WorkoutPlanFinisher/adjusted(_:picks:request:pool:others:context:)``).
    public static func reload(
        _ adjusted: WorkoutProgram.SessionSuggestion, original: WorkoutProgram.SessionSuggestion,
        location: WorkoutLocation, load: WorkoutLoadContext, intensity: WorkoutIntensity?,
        catalog: [ExerciseTarget]? = nil, goal: GoalType = .strength
    ) -> WorkoutProgram.SessionSuggestion {
        let context = WorkoutPlanFinisher.Context(goal: goal, intensity: intensity, location: location, load: load,
                                                  catalog: catalog)
        return WorkoutPlanFinisher.finish(adjusted, previous: original, origin: .adjustment, context: context)
    }

    // MARK: The pieces

    /// The catalog row named `name`, compared without case or extra spaces.
    static func target(named name: String, in rows: [ExerciseTarget]) -> ExerciseTarget? {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        return rows.first { WorkoutExerciseCatalog.normalizedName($0.name) == key }
    }

    /// Whether the adjusted session gets a warm-up ramp: the setting is on and the committed day isn't
    /// light — or, with no committed intensity known, the planner had given the session one.
    static func rampsToday(
        load: WorkoutLoadContext, intensity: WorkoutIntensity?, original: WorkoutProgram.SessionSuggestion
    ) -> Bool {
        guard load.warmUpSets else { return false }
        guard let intensity else { return original.exercises.contains(where: WorkoutWarmUpSets.isWarmUpSet) }
        return intensity != .light
    }
}
