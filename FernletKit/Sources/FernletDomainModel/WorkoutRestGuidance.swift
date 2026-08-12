// WorkoutRestGuidance.swift
// FernletDomainModel
//
// How long to rest between sets, per exercise. This replaces the old coarse
// `WorkoutSessionRunner.restSeconds(role:goal:)` (compound 150 / accessory 75 / core 60, ±15 by goal)
// with an evidence-based table keyed by the movement's *demand* (heavy compound vs compound vs
// isolation vs core) AND the training goal — the two axes the exercise-science literature actually
// separates rest by.
//
// The numbers below are the app's DEFAULTS. Every value is overridable per exercise: the guided run
// bakes a concrete `restSeconds` into each step (see the app's run-state builder), the in-app editor
// can change it, and the future coach app can prescribe its own — so this table only ever seeds a
// starting point, never a hard rule.
//
// Evidence base (see Docs/Workout-Rest-Guidance-Research-2026-07-19.md for the full cited report):
//   • Maximal strength / power: long rests (≈3–5 min for heavy multi-joint) preserve load and quality
//     across sets (NSCA position stand; de Salles 2009; Grgic 2018).
//   • Hypertrophy: the old "keep it short (60 s)" advice is outdated — ≥2 min on compounds grows more
//     muscle than 1 min; ~60–90 s is fine for isolation (Schoenfeld 2016; Grgic 2017 meta-analysis).
//   • Endurance / metabolic / gentle goals: short rests (≤60 s) are appropriate and keep a session
//     brisk (ACSM).
//   • Large muscle groups / heavy compounds need more rest than small-muscle isolation work
//     (de Salles 2009 review).

import Foundation

/// Evidence-based default rest intervals between sets, keyed by movement demand and training goal.
///
/// Replaces the old coarse role-only rests with the two axes the literature actually separates
/// rest by (see the header citations and Docs/Workout-Rest-Guidance-Research-2026-07-19.md).
/// Defaults only: every value is per-exercise overridable (`PrescribedExercise.restSecondsOverride`
/// baked into the guided run) and clamped into ``editableRange``.
public nonisolated enum WorkoutRestGuidance {

    /// The rest-relevant *demand* of a movement: heavy multi-joint work needs the most recovery,
    /// single-joint isolation the least. Derived from the exercise's role and (when known) its
    /// movement pattern — the compound-vs-isolation signal the literature keys rest off.
    public enum Demand {
        case heavyCompound   // squat / hinge, or a main (heaviest) push/pull/lunge/carry
        case compound        // other multi-joint accessory work
        case isolation       // single-joint / small-muscle accessory work
        case core            // trunk
    }

    /// Absolute clamps. The floor keeps even the gentlest prescription usable as a timer; the ceiling
    /// is the editable maximum the UI (and coach app) should offer.
    public static let minimumSeconds = 20
    public static let maximumSeconds = 300

    /// Rest a coach/editor is allowed to dial an exercise to.
    public static let editableRange: ClosedRange<Int> = minimumSeconds...maximumSeconds

    /// Classify a prescribed movement's rest demand from its role and (optional) movement pattern.
    public static func demand(role: SlotRole, movementPattern: MovementPattern?) -> Demand {
        if role == .core { return .core }
        switch movementPattern {
        case .squat, .hinge:
            return .heavyCompound
        case .push, .pull, .lunge, .carry:
            // The heaviest slot of a session (main) rests like a heavy compound; the same pattern as
            // an accessory rests a touch less.
            return role == .main ? .heavyCompound : .compound
        case .twist:
            return .core
        case .isolation:
            return .isolation
        case .locomotion, .none:
            // No catalog pattern (a non-catalog line, or an unmapped name): fall back to role.
            switch role {
            case .main: return .heavyCompound
            case .accessory: return .isolation
            case .core: return .core
            }
        }
    }

    /// Recommended rest, in seconds, for a demand tier under a training goal.
    // NOTE: numbers below are the tuned defaults from the rest-interval research (2026-07-19). If the
    // evidence base changes, this is the ONE place to update.
    public static func restSeconds(demand: Demand, goal: GoalType) -> Int {
        let value: Int
        switch goal {
        // Maximal strength: longest rests to preserve load across sets. ACSM ≥2–3 min for heavy core
        // lifts (3–5 min optimum for trained lifters); assistance work 1–2 min.
        case .strength:
            switch demand {
            case .heavyCompound: value = 180   // 3 min (ACSM core lifts; up to 5 min for trained)
            case .compound:      value = 120   // 2 min
            case .isolation:     value = 90    // ACSM assistance 1–2 min
            case .core:          value = 60
            }
        // Power / sport prep: long rests preserve bar speed. ACSM ≥2–3 min heavy core / 3–5 min
        // light-load fast-velocity; assistance 1–2 min.
        case .sportsPrep:
            switch demand {
            case .heavyCompound: value = 180
            case .compound:      value = 120
            case .isolation:     value = 90
            case .core:          value = 60
            }
        // Hypertrophy-leaning everyday goals: ~2 min on compounds, 60–90 s isolation (updated
        // evidence — the small >60 s benefit is volume-load driven; never default below 60 s).
        case .weightManagement, .wellness, .exploring:
            switch demand {
            case .heavyCompound: value = 120   // 2 min
            case .compound:      value = 90
            case .isolation:     value = 75    // 60–90 s band; kept clear of the 60 s floor
            case .core:          value = 45
            }
        // Mental-health sessions: brisk and unintimidating, but still enough to finish a set well.
        case .mentalHealth:
            switch demand {
            case .heavyCompound: value = 90
            case .compound:      value = 75
            case .isolation:     value = 60
            case .core:          value = 40
            }
        // Recovery: gentlest — short, easy pacing.
        case .recovery:
            switch demand {
            case .heavyCompound: value = 75
            case .compound:      value = 60
            case .isolation:     value = 45
            case .core:          value = 30
            }
        }
        return clamp(value)
    }

    /// Rest for an exercise, resolving its movement pattern from the catalog by name when it's a
    /// catalog movement. Non-catalog lines (conditioning finishers) fall back to the role-only tier.
    public static func restSeconds(
        forExerciseNamed name: String,
        role: SlotRole,
        goal: GoalType,
        catalog: [ExerciseTarget] = WorkoutExerciseCatalog.allExercises
    ) -> Int {
        let pattern = movementPattern(forExerciseNamed: name, catalog: catalog)
        return restSeconds(demand: demand(role: role, movementPattern: pattern), goal: goal)
    }

    /// Look up an exercise's movement pattern by name (case-insensitive exact match), or nil.
    public static func movementPattern(
        forExerciseNamed name: String,
        catalog: [ExerciseTarget] = WorkoutExerciseCatalog.allExercises
    ) -> MovementPattern? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return catalog.first { $0.name.lowercased() == needle }?.movementPattern
    }

    public static func clamp(_ seconds: Int) -> Int {
        min(maximumSeconds, max(minimumSeconds, seconds))
    }
}
