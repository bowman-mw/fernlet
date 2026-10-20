// WorkoutAdjustedLoad.swift
// FernletDomainModel
//
// The load pass, run again after "Adjust with AI" (round 2, R3, 2026-10-20). The on-device adjuster
// answers with lift names, sets and reps only — no weights and no warm-up sets — and
// ``WorkoutProgram/applyAdjustment(to:exercises:)`` drops them into the session as they came. So an
// adjusted session ran with no suggested weights and without the warm-up ramp the planner had given it.
//
// This pass gives the adjusted lifting block back what the planner's load pass gives a fresh one: each
// lift's guidance (a lift the adjuster kept with the same reps keeps the guidance it had; any other
// catalog lift is prescribed from its own history, on the location's weights), the count of compound
// lifts ahead of each (the fatigue context a result records), and the warm-up ramp before the first
// heavy main lift (``WorkoutWarmUpSets``) when warm-up sets are on and the day isn't light. The time
// budget is NOT applied again: an adjusted session runs as the adjuster shaped it. Pure and
// deterministic over its inputs.

import Foundation

/// Re-runs the load pass over a session's AI-adjusted lifting block: guidance, fatigue context and the
/// warm-up ramp, as the planner gives a fresh session.
public nonisolated enum WorkoutAdjustedLoad {

    /// `adjusted` — a session after ``WorkoutProgram/applyAdjustment(to:exercises:)`` — with its lifting
    /// block loaded again.
    ///
    /// - Any warm-up set already in the block goes first (the ramp is rebuilt for the lifts as they now
    ///   stand).
    /// - A lift that carries guidance keeps it. A lift `original` had, with the same reps, takes the
    ///   guidance it had there (never a calibration step's or a warm-up set's). Any other catalog lift is
    ///   prescribed from its own history in `load`, on `location`'s weights, for the sets and reps the
    ///   adjuster wrote (``WorkoutPlanRun``'s engine guidance). Holds and lifts the catalog does not know
    ///   get none.
    /// - Each lift's `compoundsBefore` is counted again in the new order.
    /// - The warm-up ramp goes before the first heavy main lift when `load` has warm-up sets on and
    ///   `intensity` isn't light; with no `intensity` known, only when `original` had a ramp.
    ///
    /// `catalog` defaults to every exercise the app knows. The other blocks and the note are kept; the
    /// plan text is rebuilt from the new steps.
    public static func reload(
        _ adjusted: WorkoutProgram.SessionSuggestion, original: WorkoutProgram.SessionSuggestion,
        location: WorkoutLocation, load: WorkoutLoadContext, intensity: WorkoutIntensity?,
        catalog: [ExerciseTarget]? = nil
    ) -> WorkoutProgram.SessionSuggestion {
        var steps = WorkoutWarmUpSets.removingWarmUpSets(from: adjusted.exercises.filter { $0.block == .lifting })
        guard !steps.isEmpty else { return adjusted }
        let rows = catalog ?? WorkoutExerciseCatalog.allExercises
        let targets = steps.map { target(named: $0.name, in: rows) }
        let patterns = targets.map { $0?.movementPattern }
        let kept = originalLifts(original)
        for index in steps.indices {
            steps[index].guidance = guidance(for: steps[index], target: targets[index], kept: kept,
                                             location: location, load: load)
        }
        let counts = WorkoutProgram.compoundCounts(names: steps.map(\.name), patterns: patterns)
        for index in steps.indices where index < counts.count {
            steps[index].guidance?.compoundsBefore = counts[index]
        }
        if rampsToday(load: load, intensity: intensity, original: original) {
            addWarmUpSets(&steps, patterns: patterns, location: location)
        }
        var updated = adjusted
        let before = adjusted.exercises.filter { $0.block == .warmUp || $0.block == .activation }
        let after = adjusted.exercises.filter { $0.block == .cardio || $0.block == .coolDown }
        updated.exercises = before + steps + after
        updated.suggestion = WorkoutSuggestion(
            name: adjusted.suggestion.name,
            exercises: WorkoutSessionBlocks.planText(for: updated.exercises),
            notes: adjusted.suggestion.notes
        )
        return updated
    }

    // MARK: The pieces

    /// The catalog row named `name`, compared without case or extra spaces.
    static func target(named name: String, in rows: [ExerciseTarget]) -> ExerciseTarget? {
        let key = WorkoutExerciseCatalog.normalizedName(name)
        return rows.first { WorkoutExerciseCatalog.normalizedName($0.name) == key }
    }

    /// `session`'s lifting steps that carry plain guidance — not a warm-up set, not a calibration step —
    /// by normalized name, the first of each.
    static func originalLifts(_ session: WorkoutProgram.SessionSuggestion) -> [String: PrescribedExercise] {
        var byName: [String: PrescribedExercise] = [:]
        for step in session.exercises where step.block == .lifting {
            guard let guidance = step.guidance, guidance.calibration == nil, !guidance.warmUp else { continue }
            let key = WorkoutExerciseCatalog.normalizedName(step.name)
            if byName[key] == nil { byName[key] = step }
        }
        return byName
    }

    /// One adjusted step's guidance: what it carries, else what the original lift had at the same reps,
    /// else the engine's prescription from history; nil for a hold, a non-catalog step and a lift the
    /// catalog does not know.
    static func guidance(
        for step: PrescribedExercise, target: ExerciseTarget?, kept: [String: PrescribedExercise],
        location: WorkoutLocation, load: WorkoutLoadContext
    ) -> LoadGuidance? {
        if let existing = step.guidance { return existing }
        guard step.fromCatalog, step.holdSeconds == nil else { return nil }
        if let original = kept[WorkoutExerciseCatalog.normalizedName(step.name)], original.reps == step.reps,
           let guidance = original.guidance {
            return guidance
        }
        guard let target else { return nil }
        return WorkoutPlanRun.engineGuidance(for: target, reps: step.reps, sets: step.sets, location: location,
                                             load: load, inventory: location.weights)
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

    /// The warm-up ramp in front of the first heavy main lift in `steps`, on the location's own loads
    /// for its gear when they are set — that lift or none (``WorkoutWarmUpSets/firstHeavyMainLift(in:patterns:)``).
    static func addWarmUpSets(_ steps: inout [PrescribedExercise], patterns: [MovementPattern?], location: WorkoutLocation) {
        guard let index = WorkoutWarmUpSets.firstHeavyMainLift(in: steps, patterns: patterns),
              index < patterns.count, let pattern = patterns[index] else { return }
        let lift = steps[index]
        let ladder = lift.guidance.flatMap { WorkoutProgram.loadLadder(for: $0, at: location) }
        steps.insert(contentsOf: WorkoutWarmUpSets.steps(for: lift, pattern: pattern, ladder: ladder), at: index)
    }
}
