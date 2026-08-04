// ScoringValueTypes.swift
// SPM carve-up: pure scoring value types carved out of the app-layer Scoring.swift so domain
// types (DailyHealthScore.weightVector, WorkoutProgram.SessionSuggestion.suggestion) can hold
// them without an upward edge. The scoring LOGIC (GoalWeights, score computation,
// WorkoutSuggestionLibrary) stays in Scoring.swift. `ScoringWeights.adjustedForPeriod(_:)` also
// stays in Scoring.swift as an extension, because it depends on the period-module enum
// `PeriodSignalStrength` which lives above the domain layer.

import Foundation

/// The per-component weight vector (journal/meal/workout/sleep/hydration/hygiene) behind a daily
/// score.
///
/// Invariant: the weights sum to 1 (asserted in the memberwise `init`; note the synthesized
/// `Codable` decode path does not re-run the assert). `adjustedForSickness` zeroes workout and
/// redistributes into rest-oriented components; the period adjustment lives above the domain layer
/// as an extension in FernletScoring. Persisted on ``DailyHealthScore`` so each day's exact vector
/// is auditable.
public nonisolated struct ScoringWeights: Codable, Equatable {
    public var journalWeight: Double
    public var mealWeight: Double
    public var workoutWeight: Double
    public var sleepWeight: Double
    public var hydrationWeight: Double
    public var hygieneWeight: Double

    public init(
        journalWeight: Double,
        mealWeight: Double,
        workoutWeight: Double,
        sleepWeight: Double,
        hydrationWeight: Double,
        hygieneWeight: Double
    ) {
        self.journalWeight = journalWeight
        self.mealWeight = mealWeight
        self.workoutWeight = workoutWeight
        self.sleepWeight = sleepWeight
        self.hydrationWeight = hydrationWeight
        self.hygieneWeight = hygieneWeight
        assert(abs(total - 1.0) < 0.000_001, "scoring weights must sum to 1")
    }

    public var total: Double {
        journalWeight + mealWeight + workoutWeight + sleepWeight + hydrationWeight + hygieneWeight
    }

    public func adjustedForSickness(_ isSick: Bool) -> ScoringWeights {
        guard isSick else { return self }
        var adjusted = self
        let workout = workoutWeight
        adjusted.workoutWeight = 0
        adjusted.sleepWeight += workout * 0.5
        adjusted.hydrationWeight += workout * 0.3
        adjusted.hygieneWeight += workout * 0.2
        return adjusted
    }
}

/// A rendered workout suggestion: name, exercise text, and note copy.
///
/// The display/log bridge of the suggestion engine — held by ``WorkoutProgram``'s session
/// suggestions, and `workout(intensity:)` turns it into a loggable ``Workout`` row.
public nonisolated struct WorkoutSuggestion: Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var exercises: String
    public var notes: String

    public init(id: UUID = UUID(), name: String, exercises: String, notes: String) {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.notes = notes
    }

    public func workout(intensity: WorkoutIntensity) -> Workout {
        Workout(
            name: name,
            type: .mixed,
            mode: .strengthTraining,
            exercises: exercises,
            rpe: nil,
            notes: notes,
            duration: nil,
            intensity: intensity
        )
    }
}
