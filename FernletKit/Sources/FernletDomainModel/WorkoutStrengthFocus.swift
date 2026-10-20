// WorkoutStrengthFocus.swift
// FernletDomainModel
//
// What a lifter's lifting aims at (the owner's G6 pick, 2026-10-20): Strength, Size, or Both — the
// default, which trains exactly as before. A synced Workout setup choice.
//
// - Strength: heavy main lifts, about 3–5 reps, judged on the estimated-max trend; a trained lifter's
//   main lifts follow the planned blocks (``WorkoutBlocks``).
// - Size: 6–15 reps a couple of reps short of failure (the engine already aims for two in reserve,
//   inside the research's 1–3), main lifts 6–10 and the rest 10–15, with sets added as training age
//   grows — weekly sets per muscle start around ten and grow toward 15–20. A lift progresses reps,
//   then weight, then (where the next weight is too big a jump or missing) a set. Its plateau is reps
//   stalling at the same weight and effort, which is what a flat estimated-max trend is at one weight.
// - Both: the goal's own mix.

import Foundation

/// The lifting focus: Strength, Size, or Both (G6). The raw values are FROZEN tokens — persisted in the
/// settings blob and decoded tolerantly with a parked side channel (``EnumDecodeCompat``), so a newer
/// build's focus survives an older build's re-save. Screens read ``displayName`` and ``summary``.
public nonisolated enum WorkoutStrengthFocus: String, Codable, CaseIterable, Identifiable, Sendable {
    case strength
    case size
    case both

    public var id: String { rawValue }

    /// The focus's name in Workout setup.
    public var displayName: String {
        switch self {
        case .strength: String(localized: "workoutFocus.strength", defaultValue: "Strength", bundle: .module,
                               comment: "Workout setup: the lifting focus on getting stronger — heavier weights, fewer reps")
        case .size: String(localized: "workoutFocus.size", defaultValue: "Size", bundle: .module,
                           comment: "Workout setup: the lifting focus on building muscle — moderate weights, more reps")
        case .both: String(localized: "workoutFocus.both", defaultValue: "Both", bundle: .module,
                           comment: "Workout setup: the lifting focus that mixes strength and muscle building")
        }
    }

    /// One line on what the focus does, under the picker.
    public var summary: String {
        switch self {
        case .strength: String(localized: "workoutFocus.strength.summary",
                               defaultValue: "Heavier main lifts for fewer reps, about 3 to 5.", bundle: .module,
                               comment: "Workout setup: what the Strength focus does")
        case .size: String(localized: "workoutFocus.size.summary",
                           defaultValue: "Moderate weights for more reps, about 6 to 15, with sets added over time.",
                           bundle: .module, comment: "Workout setup: what the Size focus does")
        case .both: String(localized: "workoutFocus.both.summary",
                           defaultValue: "A mix of strength and muscle-building work.", bundle: .module,
                           comment: "Workout setup: what the Both focus does")
        }
    }

    /// The rep range this focus sets for a role, as plan text the scheme reads ("3-5"); nil keeps the
    /// goal's own.
    public func reps(for role: SlotRole) -> String? {
        switch (self, role) {
        case (.strength, .main): "3-5"
        case (.size, .main): "6-10"
        case (.size, .accessory), (.size, .core): "10-15"
        case (.strength, .accessory), (.strength, .core), (.both, _): nil
        }
    }

    /// Sets this focus adds to a lift by its training age: Size grows the weekly volume, one set past
    /// six months on a lift and two past two years; the others add none.
    public func extraSets(_ tier: TrainingTier) -> Int {
        guard self == .size else { return 0 }
        switch tier {
        case .beginner: return 0
        case .intermediate: return 1
        case .advanced: return 2
        }
    }

    /// Most sets a focus's growth takes a lift to.
    public static let maxSets = 5
}
