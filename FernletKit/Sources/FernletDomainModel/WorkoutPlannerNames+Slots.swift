// WorkoutPlannerNames+Slots.swift
// FernletDomainModel
//
// The localized names of the session templates' slot labels (2026-10-20, idea 16). A slot label is a
// token — the planner tells main lifts from accessories by it (`mainLabels`) and `DayPlan.droppedSlots`
// carries it — so ``WorkoutSlotSpec/label`` keeps its English and the session note ("Skipped Hinge,
// Core — no safe option here.") names each slot through this mapping.

import Foundation

/// The localized slot labels, for note text and screens only.
public nonisolated enum WorkoutSlotNames {

    /// The label to draw for a slot: its localized form when the session templates use it, else as
    /// given.
    public static func drawn(_ label: String) -> String {
        movementLabel(label) ?? muscleLabel(label) ?? label
    }

    /// Every label `drawn(_:)` can name, joined for a note: "Hinge, Core".
    static func drawnList(_ labels: [String]) -> String {
        labels.map(drawn).joined(separator: ", ")
    }

    /// The labels named for a movement.
    static func movementLabel(_ label: String) -> String? {
        switch label {
        case "Squat": String(localized: "workoutSlot.squat", defaultValue: "Squat", bundle: .module, comment: "Part of a workout session: a squat movement")
        case "Hinge": String(localized: "workoutSlot.hinge", defaultValue: "Hinge", bundle: .module, comment: "Part of a workout session: a hip hinge, like a deadlift")
        case "Lunge": String(localized: "workoutSlot.lunge", defaultValue: "Lunge", bundle: .module, comment: "Part of a workout session: a lunge")
        case "Core": String(localized: "workoutSlot.core", defaultValue: "Core", bundle: .module, comment: "Part of a workout session: core (trunk) work")
        case "Horizontal push": String(localized: "workoutSlot.horizontalPush", defaultValue: "Horizontal push", bundle: .module, comment: "Part of a workout session: pressing straight out in front, like a bench press")
        case "Horizontal pull": String(localized: "workoutSlot.horizontalPull", defaultValue: "Horizontal pull", bundle: .module, comment: "Part of a workout session: pulling toward the chest, like a row")
        case "Vertical push": String(localized: "workoutSlot.verticalPush", defaultValue: "Vertical push", bundle: .module, comment: "Part of a workout session: pressing overhead")
        case "Vertical pull": String(localized: "workoutSlot.verticalPull", defaultValue: "Vertical pull", bundle: .module, comment: "Part of a workout session: pulling down from overhead, like a pull-up")
        case "Incline push": String(localized: "workoutSlot.inclinePush", defaultValue: "Incline push", bundle: .module, comment: "Part of a workout session: an incline press")
        case "Row": String(localized: "workoutSlot.row", defaultValue: "Row", bundle: .module, comment: "Part of a workout session: a rowing movement")
        case "Row variation": String(localized: "workoutSlot.rowVariation", defaultValue: "Row variation", bundle: .module, comment: "Part of a workout session: a second, different rowing movement")
        case "Carry / loaded": String(localized: "workoutSlot.carry", defaultValue: "Carry / loaded", bundle: .module, comment: "Part of a workout session: a loaded carry, walking while holding weights")
        case "Flat press": String(localized: "workoutSlot.flatPress", defaultValue: "Flat press", bundle: .module, comment: "Part of a workout session: a flat bench press")
        case "Incline press": String(localized: "workoutSlot.inclinePress", defaultValue: "Incline press", bundle: .module, comment: "Part of a workout session: an incline bench press")
        case "Overhead press": String(localized: "workoutSlot.overheadPress", defaultValue: "Overhead press", bundle: .module, comment: "Part of a workout session: a press overhead")
        case "Dip / decline": String(localized: "workoutSlot.dip", defaultValue: "Dip / decline", bundle: .module, comment: "Part of a workout session: a dip or a decline press")
        case "Lower power": String(localized: "workoutSlot.lowerPower", defaultValue: "Lower power", bundle: .module, comment: "Part of a workout session: an explosive lower-body movement")
        case "Variant": String(localized: "workoutSlot.variant", defaultValue: "Variant", bundle: .module, comment: "Part of a workout session: a related exercise added beside a lift that has held steady for a while")
        default: nil
        }
    }

    /// The labels named for a muscle.
    static func muscleLabel(_ label: String) -> String? {
        switch label {
        case "Biceps": String(localized: "workoutSlot.biceps", defaultValue: "Biceps", bundle: .module, comment: "Part of a workout session: a biceps exercise")
        case "Triceps": String(localized: "workoutSlot.triceps", defaultValue: "Triceps", bundle: .module, comment: "Part of a workout session: a triceps exercise")
        case "Biceps 2": String(localized: "workoutSlot.biceps2", defaultValue: "Biceps 2", bundle: .module, comment: "Part of a workout session: a second biceps exercise")
        case "Triceps 2": String(localized: "workoutSlot.triceps2", defaultValue: "Triceps 2", bundle: .module, comment: "Part of a workout session: a second triceps exercise")
        case "Calves": String(localized: "workoutSlot.calves", defaultValue: "Calves", bundle: .module, comment: "Part of a workout session: a calf exercise")
        case "Side delts": String(localized: "workoutSlot.sideDelts", defaultValue: "Side delts", bundle: .module, comment: "Part of a workout session: an exercise for the side of the shoulders")
        case "Rear delts": String(localized: "workoutSlot.rearDelts", defaultValue: "Rear delts", bundle: .module, comment: "Part of a workout session: an exercise for the back of the shoulders")
        case "Front delts": String(localized: "workoutSlot.frontDelts", defaultValue: "Front delts", bundle: .module, comment: "Part of a workout session: an exercise for the front of the shoulders")
        case "Traps": String(localized: "workoutSlot.traps", defaultValue: "Traps", bundle: .module, comment: "Part of a workout session: a trapezius exercise, like a shrug")
        case "Chest isolation": String(localized: "workoutSlot.chestIsolation", defaultValue: "Chest isolation", bundle: .module, comment: "Part of a workout session: a single-joint chest exercise, like a fly")
        case "Forearms / grip": String(localized: "workoutSlot.forearms", defaultValue: "Forearms / grip", bundle: .module, comment: "Part of a workout session: forearm and grip work")
        default: nil
        }
    }
}
