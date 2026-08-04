// ModelColors.swift
// SwiftUI `Color` extensions stripped from Models.swift domain enums (SPM carve-up §5a).
// Re-added as extensions so the domain models stay Foundation-only / portable.

import SwiftUI
import FernletDomainModel

public extension MealType {
    /// The design-system accent color for this meal slot (meal chips, diary rows, food summaries).
    var color: Color {
        switch self {
        case .breakfast: .goldenrod
        case .lunch: .fern
        case .dinner: .slate
        case .snack: .softTaupe
        case .preWorkout: .goldenrod
        case .postWorkout: .dustyRose
        }
    }
}

public extension WorkoutSplit {
    /// The design-system accent color for this workout split, used by plan/split pickers and cards.
    var color: Color {
        switch self {
        case .workout: .terracotta
        case .upper, .push, .pull: .moss
        case .lower, .legs: .goldenrod
        case .fullBody, .recovery: .dustyRose
        case .cardio: .terracotta
        }
    }
}

public extension WorkoutType {
    /// The design-system accent color for this workout type, used by logged-workout rows and badges.
    var color: Color {
        switch self {
        case .upper, .armsBack, .mixed:
            .moss
        case .lower:
            .goldenrod
        case .fullBody:
            .dustyRose
        case .cardio, .run, .hike:
            .terracotta
        }
    }
}

public extension FeelingTag {
    /// The design-system tint for this journal feeling tag (chips and journal summaries).
    var color: Color {
        switch self {
        case .bright: .sun
        case .good: .fern
        case .neutral: .softTaupe
        case .quiet: .slate
        case .tired: .dustyRose
        case .hard: .terracotta
        }
    }
}

public extension TextureTag {
    /// The design-system tint for this journal texture tag (chips and journal summaries).
    var color: Color {
        switch self {
        case .tension: .terracotta
        case .delight: .moss
        case .friction: .goldenrod
        }
    }
}

public extension CompanionPalette {
    /// Resolves this user-chosen companion palette to a concrete tint; `.state` follows the
    /// companion's current wellness color, the fixed cases override it.
    func color(for state: CompanionState) -> Color {
        switch self {
        case .state: state.color
        case .fern: .fern
        case .rose: .dustyRose
        case .sun: .sun
        case .slate: .slate
        }
    }
}

public extension CompanionAssetColor {
    /// Resolves a companion asset's declared color slot to a concrete tint; `.state` follows the
    /// companion's current wellness color, the named cases are fixed design-system tokens.
    func color(for state: CompanionState) -> Color {
        switch self {
        case .state: state.color
        case .moss: .moss
        case .fern: .fern
        case .rose: .dustyRose
        case .sun: .sun
        case .slate: .slate
        case .terracotta: .terracotta
        case .cream: .cream
        case .bark: .bark
        }
    }
}

public extension CompanionState {
    /// The wellness tint for this companion state — the base color the avatar and state chips wear.
    var color: Color {
        switch self {
        case .thriving: .moss
        case .okay: .goldenrod
        case .tired: .dustyRose
        case .resting: .slate
        case .sick: .terracotta
        }
    }
}
