// WorkoutPlannerNames.swift
// FernletDomainModel
//
// Draw-time names for the planner's FROZEN English names (2026-10-20, idea 16): session titles
// ("Full Body A", "Morning · Easy cardio"), split names and day titles ("Push / Pull / Legs", "Day 2"),
// and slot labels ("Horizontal push").
//
// Each of these is a token as well as a name, which is why none is translated where it is stored:
// a session's name is the `Workout.name` its guided log is saved under, and the rotation
// (`WorkoutProgram.matchedDayIndex`) and the guided reconciliation match logged names against it; a
// split's name is the trainer export's `splitName`; a day title is what the 48-hour guard's tests
// and the plan's eyebrow read; a slot label is how the planner tells main lifts from accessories.
// So each keeps its exact English spelling, and a screen draws it through one of these mappings, the
// same frozen/display split `StoredWorkoutName` applies to stored workout names.

import Foundation

/// The localized names of the planner's session titles, for screens and note text only.
///
/// `displayTitle(_:)` knows every title ``WorkoutSessions`` and the planner's fallbacks write;
/// ``drawn(_:)`` also reads a timed session's name ("Morning · Easy cardio"). Anything else comes back
/// as given. Never persist, export, match or prompt with what these return.
public nonisolated enum WorkoutSessionNames {

    /// The name to draw for a stored or planned session name: its localized form when it is one the
    /// planner writes, else `name` unchanged.
    public static func drawn(_ name: String) -> String {
        displayed(name) ?? name
    }

    /// The localized form of a session name the planner writes — a session title, or a time label
    /// and a title ("Morning · Easy cardio") — or nil for any other name.
    public static func displayed(_ name: String) -> String? {
        if let title = displayTitle(name) { return title }
        for time in SessionTime.timedCases {
            let prefix = "\(time.label) · "
            guard name.hasPrefix(prefix), let title = displayTitle(String(name.dropFirst(prefix.count))) else { continue }
            return String(localized: "workoutSession.timed", defaultValue: "\(time.displayLabel) · \(title)", bundle: .module,
                          comment: "A session's name in a day with two sessions. Arguments: the time of day (e.g. 'Morning'), then the session's name (e.g. 'Easy cardio').")
        }
        return nil
    }

    /// The localized form of one session title, or nil when `title` is not one the planner writes.
    public static func displayTitle(_ title: String) -> String? {
        strengthTitle(title) ?? otherTitle(title)
    }

    /// The lifting sessions' titles.
    static func strengthTitle(_ title: String) -> String? {
        switch title {
        case "Full Body A": String(localized: "workoutSession.fullBodyA", defaultValue: "Full Body A", bundle: .module, comment: "Workout session name: the first of three full-body sessions")
        case "Full Body B": String(localized: "workoutSession.fullBodyB", defaultValue: "Full Body B", bundle: .module, comment: "Workout session name: the second of three full-body sessions")
        case "Full Body C": String(localized: "workoutSession.fullBodyC", defaultValue: "Full Body C", bundle: .module, comment: "Workout session name: the third of three full-body sessions")
        case "Upper": String(localized: "workoutSession.upper", defaultValue: "Upper", bundle: .module, comment: "Workout session name: upper body")
        case "Lower": String(localized: "workoutSession.lower", defaultValue: "Lower", bundle: .module, comment: "Workout session name: lower body")
        case "Push": String(localized: "workoutSession.push", defaultValue: "Push", bundle: .module, comment: "Workout session name: pushing movements (chest, shoulders, triceps)")
        case "Pull": String(localized: "workoutSession.pull", defaultValue: "Pull", bundle: .module, comment: "Workout session name: pulling movements (back, biceps)")
        case "Legs": String(localized: "workoutSession.legs", defaultValue: "Legs", bundle: .module, comment: "Workout session name: legs")
        case "Chest": String(localized: "workoutSession.chest", defaultValue: "Chest", bundle: .module, comment: "Workout session name: a chest day")
        case "Back": String(localized: "workoutSession.back", defaultValue: "Back", bundle: .module, comment: "Workout session name: a back day (the body part)")
        case "Shoulders": String(localized: "workoutSession.shoulders", defaultValue: "Shoulders", bundle: .module, comment: "Workout session name: a shoulder day")
        case "Arms": String(localized: "workoutSession.arms", defaultValue: "Arms", bundle: .module, comment: "Workout session name: an arm day")
        case "Chest & Back": String(localized: "workoutSession.chestAndBack", defaultValue: "Chest & Back", bundle: .module, comment: "Workout session name: chest and back together")
        case "Shoulders & Arms": String(localized: "workoutSession.shouldersAndArms", defaultValue: "Shoulders & Arms", bundle: .module, comment: "Workout session name: shoulders and arms together")
        case "Sport conditioning": String(localized: "workoutSession.sportConditioning", defaultValue: "Sport conditioning", bundle: .module, comment: "Workout session name: sport-specific conditioning with some strength work")
        default: nil
        }
    }

    /// The cardio and mobility sessions' titles, and the names of the planner's fallback sessions.
    static func otherTitle(_ title: String) -> String? {
        switch title {
        case "Easy cardio": String(localized: "workoutSession.easyCardio", defaultValue: "Easy cardio", bundle: .module, comment: "Workout session name: a gentle cardio session")
        case "Intervals": String(localized: "workoutSession.intervals", defaultValue: "Intervals", bundle: .module, comment: "Workout session name: interval cardio, hard and easy in turns")
        case "Steady cardio": String(localized: "workoutSession.steadyCardio", defaultValue: "Steady cardio", bundle: .module, comment: "Workout session name: a longer cardio session at an even pace")
        case "Mobility": String(localized: "workoutSession.mobility", defaultValue: "Mobility", bundle: .module, comment: "Workout session name: mobility and stretching")
        case "Move": String(localized: "workoutSession.move", defaultValue: "Move", bundle: .module, comment: "Workout session name of the fallback day: just move")
        case "Easy full body": String(localized: "workoutSession.easyFullBody", defaultValue: "Easy full body", bundle: .module, comment: "Workout session name: the fallback full-body circuit offered when nothing else could be planned")
        case "Rest": String(localized: "workoutSession.rest", defaultValue: "Rest", bundle: .module, comment: "Workout plan day name on a day the person marked themselves unwell")
        case "Gentle movement": String(localized: "workoutSession.gentleMovement", defaultValue: "Gentle movement", bundle: .module, comment: "Workout session name on a rest day: optional gentle movement")
        default: nil
        }
    }
}

public extension SessionTime {
    /// The times that name a session ("Morning · Easy cardio"); `.any` adds nothing to a name.
    static var timedCases: [SessionTime] { [.morning, .midday, .evening] }

    /// The time of day on screen, localized. ``label`` stays the frozen English that is part of a
    /// stored session name ("Morning · Easy cardio"); never put this in a name that is saved.
    var displayLabel: String {
        switch self {
        case .any: ""
        case .morning: String(localized: "sessionTime.morning", defaultValue: "Morning", bundle: .module,
                              comment: "Time of day of a workout session, in a day with two sessions")
        case .midday: String(localized: "sessionTime.midday", defaultValue: "Midday", bundle: .module,
                             comment: "Time of day of a workout session, in a day with two sessions")
        case .evening: String(localized: "sessionTime.evening", defaultValue: "Evening", bundle: .module,
                              comment: "Time of day of a workout session, in a day with two sessions")
        }
    }
}

public extension WorkoutSplitDay {
    /// The day's title on screen, localized: "Day 2", "Push A", or the session title it shares
    /// ("Push", "Chest & Back"). ``title`` stays the frozen English.
    var displayTitle: String {
        WorkoutSplitDayNames.displayed(title) ?? title
    }
}

/// The localized forms of the split days' titles and the day plan's own fallback names.
public nonisolated enum WorkoutSplitDayNames {
    /// The localized form of a day title the split catalog or the planner writes, or nil.
    public static func displayed(_ title: String) -> String? {
        if title.hasPrefix("Day "), let number = Int(title.dropFirst(4)), number > 0 {
            return String(localized: "workoutSplitDay.numbered", defaultValue: "Day \(number)", bundle: .module,
                          comment: "A day of a weekly workout split, numbered from 1, e.g. 'Day 2'")
        }
        return lettered(title) ?? WorkoutSessionNames.displayTitle(title)
    }

    /// The six-day split's lettered days ("Push A").
    static func lettered(_ title: String) -> String? {
        switch title {
        case "Push A": String(localized: "workoutSplitDay.pushA", defaultValue: "Push A", bundle: .module, comment: "A day of the six-day split: the first push day")
        case "Pull A": String(localized: "workoutSplitDay.pullA", defaultValue: "Pull A", bundle: .module, comment: "A day of the six-day split: the first pull day")
        case "Legs A": String(localized: "workoutSplitDay.legsA", defaultValue: "Legs A", bundle: .module, comment: "A day of the six-day split: the first legs day")
        case "Push B": String(localized: "workoutSplitDay.pushB", defaultValue: "Push B", bundle: .module, comment: "A day of the six-day split: the second push day")
        case "Pull B": String(localized: "workoutSplitDay.pullB", defaultValue: "Pull B", bundle: .module, comment: "A day of the six-day split: the second pull day")
        case "Legs B": String(localized: "workoutSplitDay.legsB", defaultValue: "Legs B", bundle: .module, comment: "A day of the six-day split: the second legs day")
        default: nil
        }
    }
}

public extension TrainingSplit {
    /// The split's name on screen, localized. ``name`` stays the frozen English: it is the trainer
    /// export's `splitName` and the day plan's `splitName`.
    var displayName: String {
        TrainingSplitNames.displayed(id: id) ?? name
    }

    /// The localized form of a split NAME, for a day plan that carries only the name; nil for a name
    /// no catalog split has (the rest day's "Rest day" has its own key).
    static func displayName(forName name: String) -> String? {
        if name == restDayName {
            return String(localized: "trainingSplit.restDay", defaultValue: "Rest day", bundle: .module,
                          comment: "The plan's heading on a day the person marked themselves unwell")
        }
        return WorkoutSplitCatalog.all.first { $0.name == name }?.displayName
    }

    /// The frozen split name of the app's rest-day plan.
    static var restDayName: String { "Rest day" }
}

/// The localized split names, by the split's stable id.
nonisolated enum TrainingSplitNames {
    /// The name for a catalog split id, or nil for an id the catalog does not have.
    static func displayed(id: String) -> String? {
        switch id {
        case "daily-move": String(localized: "trainingSplit.dailyMove", defaultValue: "Daily Movement", bundle: .module, comment: "Workout split name: easy full-body days and walks")
        case "full-body-2": String(localized: "trainingSplit.fullBody2", defaultValue: "Full Body ×2", bundle: .module, comment: "Workout split name: two full-body sessions a week")
        case "recovery-flow": String(localized: "trainingSplit.recoveryFlow", defaultValue: "Recovery Flow", bundle: .module, comment: "Workout split name: mobility and easy movement")
        case "full-body-3": String(localized: "trainingSplit.fullBody3", defaultValue: "Full Body ×3", bundle: .module, comment: "Workout split name: three full-body sessions a week")
        case "upper-lower-full-3": String(localized: "trainingSplit.upperLowerFull3", defaultValue: "Upper / Lower / Full", bundle: .module, comment: "Workout split name: an upper-body day, a lower-body day and a full-body day")
        case "upper-lower-4": String(localized: "trainingSplit.upperLower4", defaultValue: "Upper / Lower", bundle: .module, comment: "Workout split name: four days alternating upper and lower body")
        case "ppl-3": String(localized: "trainingSplit.ppl3", defaultValue: "Push / Pull / Legs", bundle: .module, comment: "Workout split name: push, pull and legs days")
        case "cardio-strength-4": String(localized: "trainingSplit.cardioStrength4", defaultValue: "Cardio + Strength", bundle: .module, comment: "Workout split name: morning cardio and evening lifting")
        case "sport-prep": String(localized: "trainingSplit.sportPrep", defaultValue: "Sport Prep", bundle: .module, comment: "Workout split name: conditioning for a sport plus strength work")
        case "ppl-ul-5": String(localized: "trainingSplit.pplUL5", defaultValue: "PPL + Upper / Lower", bundle: .module, comment: "Workout split name: push, pull, legs, then upper and lower days. 'PPL' abbreviates push / pull / legs.")
        case "ppl-6": String(localized: "trainingSplit.ppl6", defaultValue: "Push / Pull / Legs ×2", bundle: .module, comment: "Workout split name: push, pull and legs, twice a week")
        case "bro-5": String(localized: "trainingSplit.bro5", defaultValue: "Bro Split", bundle: .module, comment: "Workout split name: one body part per day (gym slang)")
        case "arnold-6": String(localized: "trainingSplit.arnold6", defaultValue: "Arnold Split", bundle: .module, comment: "Workout split name: chest and back, shoulders and arms, legs, twice a week (named after Arnold Schwarzenegger)")
        case "two-a-day": String(localized: "trainingSplit.twoADay", defaultValue: "Two-a-Day Strength", bundle: .module, comment: "Workout split name: two strength sessions a day")
        default: nil
        }
    }
}

public extension WorkoutProgram.DayPlan {
    /// The split's name on screen ("Push / Pull / Legs"); ``splitName`` stays the frozen English.
    var displayedSplitName: String {
        TrainingSplit.displayName(forName: splitName) ?? splitName
    }

    /// The day's title on screen ("Day 2", "Push"); ``dayTitle`` stays the frozen English.
    var displayedDayTitle: String {
        WorkoutSplitDayNames.displayed(dayTitle) ?? dayTitle
    }
}

public extension WorkoutProgram.SessionSuggestion {
    /// The session's name on screen. `suggestion.name` stays the frozen English it is logged and
    /// reconciled under.
    var displayedName: String {
        WorkoutSessionNames.drawn(suggestion.name)
    }
}
