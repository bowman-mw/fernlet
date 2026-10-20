// WorkoutFuelCheck.swift
// FernletDomainModel
//
// The one optional question before a long, high-volume lifting session (G12, 2026-10-20): "Eaten in
// the last few hours?" Carbohydrate before training matters only for sessions of more than about 45
// minutes of high-volume work started without food, and there it tops up volume — the later sets —
// not the top set or the max. So a "no" changes how the session is READ, never what it prescribes:
// a shortfall only in the later sets is held rather than counted as a miss (``LoadChange/heldUnfueled``),
// the trend scores the top set alone (``WorkoutTrend/sessionScore(of:in:)``), and no weight changes.
// A "yes", or no answer at all, reads the session as always. The answer rides on each lift's result
// (``ExerciseResult/unfueled``) and nowhere else.

import Foundation

/// When the runner asks about food before a session (G12).
public nonisolated enum WorkoutFuelCheck {

    /// Sessions longer than this many minutes…
    public static let longSessionMinutes = 45
    /// …with at least this many working sets of tracked lifts.
    public static let highVolumeSets = 15

    /// Working sets of the session's tracked lifts: the lifting block's steps with load guidance and a
    /// rep target, warm-up sets left out.
    public static func workingSets(_ steps: [PrescribedExercise]) -> Int {
        steps.filter { step in
            step.block == .lifting && step.guidance != nil && step.holdSeconds == nil
                && !WorkoutWarmUpSets.isWarmUpSet(step)
        }
        .reduce(0) { $0 + max(0, $1.sets) }
    }

    /// Whether the runner asks before these steps: the food-aware switch on (G13), a goal that
    /// follows its main lifts (G7 — the gentler goals and weight management are never asked), and a
    /// session over ``longSessionMinutes`` with ``highVolumeSets`` or more working sets.
    public static func asks(_ steps: [PrescribedExercise], goal: GoalType, foodAware: Bool) -> Bool {
        guard foodAware, PlateauTracking.forGoal(goal) == .mainLifts else { return false }
        return workingSets(steps) >= highVolumeSets
            && WorkoutSessionBudget.minutes(of: steps, goal: goal) > longSessionMinutes
    }
}
