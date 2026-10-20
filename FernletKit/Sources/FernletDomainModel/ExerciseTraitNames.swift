// ExerciseTraitNames.swift
// FernletDomainModel
//
// Localized names for the catalog's curation tokens (2026-10-20, idea 15), first needed by the
// custom-exercise form, which asks for each field a bundled catalog row carries. The raw values stay
// the FROZEN tokens the catalog JSON, the synced custom rows and the AI prompt use; these names are
// for screens only.

import Foundation

public extension MovementPattern {
    /// The pattern's name on screen, localized. Never persisted, prompted or matched — ``rawValue``
    /// is the token.
    var displayName: String {
        switch self {
        case .push: String(localized: "movementPattern.push", defaultValue: "Push",
                           bundle: .module, comment: "Movement pattern: pressing away from the body")
        case .pull: String(localized: "movementPattern.pull", defaultValue: "Pull",
                           bundle: .module, comment: "Movement pattern: pulling toward the body")
        case .hinge: String(localized: "movementPattern.hinge", defaultValue: "Hinge",
                            bundle: .module, comment: "Movement pattern: bending at the hips, like a deadlift")
        case .squat: String(localized: "movementPattern.squat", defaultValue: "Squat",
                            bundle: .module, comment: "Movement pattern: squatting")
        case .lunge: String(localized: "movementPattern.lunge", defaultValue: "Lunge",
                            bundle: .module, comment: "Movement pattern: a split stance, one leg forward")
        case .carry: String(localized: "movementPattern.carry", defaultValue: "Carry",
                            bundle: .module, comment: "Movement pattern: walking while holding a weight")
        case .twist: String(localized: "movementPattern.twist", defaultValue: "Twist",
                            bundle: .module, comment: "Movement pattern: rotating or resisting rotation of the trunk")
        case .isolation: String(localized: "movementPattern.isolation", defaultValue: "Isolation",
                                bundle: .module, comment: "Movement pattern: a single-joint exercise, like a curl")
        case .locomotion: String(localized: "movementPattern.locomotion", defaultValue: "Moving around",
                                 bundle: .module, comment: "Movement pattern: travelling movement, like crawling or skipping")
        }
    }
}

public extension MovementPlane {
    /// The plane's name on screen, localized; ``rawValue`` is the token.
    var displayName: String {
        switch self {
        case .horizontal: String(localized: "movementPlane.horizontal", defaultValue: "Horizontal",
                                 bundle: .module, comment: "Direction of a push or pull: straight out in front, like a bench press or a row")
        case .vertical: String(localized: "movementPlane.vertical", defaultValue: "Vertical",
                               bundle: .module, comment: "Direction of a push or pull: overhead, like a shoulder press or a pull-up")
        }
    }
}

public extension ExerciseModality {
    /// The kind of training on screen, localized; ``rawValue`` is the token.
    var displayName: String {
        switch self {
        case .strength: String(localized: "exerciseModality.strength", defaultValue: "Strength",
                               bundle: .module, comment: "Kind of exercise: strength training")
        case .power: String(localized: "exerciseModality.power", defaultValue: "Power",
                            bundle: .module, comment: "Kind of exercise: explosive jumps and throws")
        case .cardio: String(localized: "exerciseModality.cardio", defaultValue: "Cardio",
                             bundle: .module, comment: "Kind of exercise: conditioning that raises the heart rate")
        case .mobility: String(localized: "exerciseModality.mobility", defaultValue: "Mobility",
                               bundle: .module, comment: "Kind of exercise: stretches and mobility work")
        case .balance: String(localized: "exerciseModality.balance", defaultValue: "Balance",
                              bundle: .module, comment: "Kind of exercise: balance drills")
        }
    }
}

public extension ExerciseDifficulty {
    /// The skill demand on screen, localized; ``rawValue`` (1–3) is the token.
    var displayName: String {
        switch self {
        case .foundational: String(localized: "exerciseDifficulty.foundational", defaultValue: "Foundational",
                                   bundle: .module, comment: "Exercise difficulty: simple to learn, good for beginners")
        case .standard: String(localized: "exerciseDifficulty.standard", defaultValue: "Standard",
                               bundle: .module, comment: "Exercise difficulty: a typical exercise")
        case .advanced: String(localized: "exerciseDifficulty.advanced", defaultValue: "Advanced",
                               bundle: .module, comment: "Exercise difficulty: needs skill and control, like a pull-up")
        }
    }
}

public extension ExerciseMeasure {
    /// How a set is counted, on screen, localized; ``rawValue`` is the token.
    var displayName: String {
        switch self {
        case .reps: String(localized: "exerciseMeasure.reps", defaultValue: "Reps",
                           bundle: .module, comment: "How an exercise's sets are counted: in repetitions")
        case .seconds: String(localized: "exerciseMeasure.seconds", defaultValue: "Seconds",
                              bundle: .module, comment: "How an exercise's sets are counted: held for time")
        }
    }
}
