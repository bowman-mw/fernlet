// ModelColors.swift
// SwiftUI `Color` extensions stripped from Models.swift domain enums (SPM carve-up §5a).
// Re-added as extensions so the domain models stay Foundation-only / portable.

import SwiftUI
import FernletDomainModel

public extension MealType {
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
    var color: Color {
        switch self {
        case .tension: .terracotta
        case .delight: .moss
        case .friction: .goldenrod
        }
    }
}

public extension CompanionPalette {
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
