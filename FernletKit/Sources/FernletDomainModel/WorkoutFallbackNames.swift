// WorkoutFallbackNames.swift
// FernletDomainModel
//
// The FROZEN English names of FernletScoring's AI-free fallback workouts (2026-10-20, Spanish round
// step 2): `WorkoutPlanner.suggestion`'s "Suggested Light" / "Suggested Moderate" / "Suggested Hard"
// and `WorkoutSuggestionLibrary`'s twelve templates ("Steady Care Walk", "Mood Reset", …).
//
// Each one becomes a stored `Workout.name` when the suggestion is taken — persisted, synced, written
// to Health and keyword-matched by the category inference — so it keeps its exact English spelling,
// and a screen draws it through `StoredWorkoutName` (``Workout/displayedName``), the same
// frozen/display split the activity defaults, the split defaults and the planner's session names use.
// The names live here rather than in FernletScoring because the draw-time mapping is a domain type
// and FernletScoring sits above this module.

import Foundation

/// The frozen English name of one fallback workout suggestion, and its localized form for screens.
///
/// `rawValue` is what a taken suggestion is SAVED under and must never change: it is on every synced
/// row the suggestion minted. ``displayName`` is the drawn half; never persist, export, match or
/// prompt with it. Pinned by `LocalizationBoundaryTests.frozenFallbackWorkoutNames`.
public nonisolated enum WorkoutFallbackName: String, CaseIterable, Sendable {
    case suggestedLight = "Suggested Light"
    case suggestedModerate = "Suggested Moderate"
    case suggestedHard = "Suggested Hard"
    case steadyCareWalk = "Steady Care Walk"
    case balancedStrengthCircuit = "Balanced Strength Circuit"
    case strengthBase = "Strength Base"
    case hardStrengthDay = "Hard Strength Day"
    case lowFrictionWalk = "Low Friction Walk"
    case moveAndStrength = "Move And Strength"
    case moodReset = "Mood Reset"
    case steadyMindCircuit = "Steady Mind Circuit"
    case recoveryFlow = "Recovery Flow"
    case softRebuild = "Soft Rebuild"
    case trySomethingSmall = "Try Something Small"
    case curiousChallenge = "Curious Challenge"

    /// The energy-matched session name `WorkoutPlanner.suggestion` saves.
    public static func suggested(_ intensity: WorkoutIntensity) -> WorkoutFallbackName {
        switch intensity {
        case .light: .suggestedLight
        case .moderate: .suggestedModerate
        case .hard: .suggestedHard
        }
    }

    /// The localized name for screens.
    public var displayName: String {
        suggestedName ?? templateName ?? rawValue
    }

    /// The three energy-matched names.
    private var suggestedName: String? {
        switch self {
        case .suggestedLight: String(localized: "workoutFallback.suggestedLight", defaultValue: "Suggested Light", bundle: .module, comment: "Name of a workout Fernlet suggested without AI for a low-energy day")
        case .suggestedModerate: String(localized: "workoutFallback.suggestedModerate", defaultValue: "Suggested Moderate", bundle: .module, comment: "Name of a workout Fernlet suggested without AI for a medium-energy day")
        case .suggestedHard: String(localized: "workoutFallback.suggestedHard", defaultValue: "Suggested Hard", bundle: .module, comment: "Name of a workout Fernlet suggested without AI for a high-energy day")
        default: nil
        }
    }

    /// The suggestion library's twelve template names.
    private var templateName: String? {
        switch self {
        case .steadyCareWalk: String(localized: "workoutFallback.steadyCareWalk", defaultValue: "Steady Care Walk", bundle: .module, comment: "Name of a suggested workout: an easy walk and a gentle stretch")
        case .balancedStrengthCircuit: String(localized: "workoutFallback.balancedStrengthCircuit", defaultValue: "Balanced Strength Circuit", bundle: .module, comment: "Name of a suggested workout: a moderate full-body strength circuit")
        case .strengthBase: String(localized: "workoutFallback.strengthBase", defaultValue: "Strength Base", bundle: .module, comment: "Name of a suggested workout: a repeatable strength template")
        case .hardStrengthDay: String(localized: "workoutFallback.hardStrengthDay", defaultValue: "Hard Strength Day", bundle: .module, comment: "Name of a suggested workout: a heavy strength session")
        case .lowFrictionWalk: String(localized: "workoutFallback.lowFrictionWalk", defaultValue: "Low Friction Walk", bundle: .module, comment: "Name of a suggested workout: a brisk walk that is easy to start")
        case .moveAndStrength: String(localized: "workoutFallback.moveAndStrength", defaultValue: "Move And Strength", bundle: .module, comment: "Name of a suggested workout: walking mixed with strength moves")
        case .moodReset: String(localized: "workoutFallback.moodReset", defaultValue: "Mood Reset", bundle: .module, comment: "Name of a suggested workout: an outdoor walk and breathing, to lift the mood")
        case .steadyMindCircuit: String(localized: "workoutFallback.steadyMindCircuit", defaultValue: "Steady Mind Circuit", bundle: .module, comment: "Name of a suggested workout: a predictable, calming bodyweight circuit")
        case .recoveryFlow: String(localized: "workoutFallback.recoveryFlow", defaultValue: "Recovery Flow", bundle: .module, comment: "Name of a suggested workout: gentle mobility for recovery")
        case .softRebuild: String(localized: "workoutFallback.softRebuild", defaultValue: "Soft Rebuild", bundle: .module, comment: "Name of a suggested workout: light strength work after time off")
        case .trySomethingSmall: String(localized: "workoutFallback.trySomethingSmall", defaultValue: "Try Something Small", bundle: .module, comment: "Name of a suggested workout: a short new walk and one mobility drill")
        case .curiousChallenge: String(localized: "workoutFallback.curiousChallenge", defaultValue: "Curious Challenge", bundle: .module, comment: "Name of a suggested workout: a contained experiment for a high-energy day")
        default: nil
        }
    }
}
