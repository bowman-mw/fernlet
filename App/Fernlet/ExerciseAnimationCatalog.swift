//
//  ExerciseAnimationCatalog.swift
//  Fernlet
//
//  Which approved exercise animation (revision r12, approved by the owner on 2026-10-29) belongs to
//  which bundled catalog exercise, and the generated still each one rests on. Custom exercises have
//  none and keep the demonstration tile they had.
//

import Foundation
import CoreGraphics
import FernletDomainModel

/// Which of the two approved characters draws an animation. It follows the profile's Sex setting:
/// female draws the female character, anything else the male one.
nonisolated enum ExerciseAnimationCharacter: String, CaseIterable, Sendable {
    case male
    case female

    /// The character for the profile's sex: female for `.female`, else male.
    init(sex: BiologicalSex) {
        self = sex == .female ? .female : .male
    }
}

/// One bundled exercise's approved animation: its stable ID in the animation package
/// (`exercise-NNN`), the loop length in seconds, whether it is a held pose, and the loop progress
/// its generated still shows.
nonisolated struct ExerciseAnimationEntry: Equatable, Sendable {
    /// The package's stable ID, `exercise-001` through `exercise-199`.
    let id: String
    /// The demonstration loop's length in seconds (not a workout prescription).
    let duration: Double
    /// A held pose: every progress draws the same frame.
    let hold: Bool
    /// The normalized progress (0...1) the generated still was rendered at.
    let stillProgress: Double
}

/// The approved animations this build carries, looked up by the exercise's catalog name.
nonisolated enum ExerciseAnimationCatalog {
    /// The animation for `exerciseName` (matched through `WorkoutExerciseCatalog.normalizedName`),
    /// or nil for a custom exercise.
    static func entry(forExerciseName exerciseName: String) -> ExerciseAnimationEntry? {
        nil
    }

    /// The generated still for `entry` drawn by `character`, or nil when the build lacks it.
    static func still(for entry: ExerciseAnimationEntry, character: ExerciseAnimationCharacter) -> CGImage? {
        nil
    }
}
