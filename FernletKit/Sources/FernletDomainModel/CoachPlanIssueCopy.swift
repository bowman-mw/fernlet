// CoachPlanIssueCopy.swift
// FernletDomainModel
//
// Every sentence a pasted coach plan's decode and validation can show on the review screen
// (2026-10-20, Spanish round step 2), as `String(localized:…, bundle: .module)` keys under
// `coachPlan.decode.*` and `coachPlan.issue.*`.
//
// These are DISPLAY: `CoachPlanIssue.detail` and `CoachPlanDecodeError.message` are drawn by the
// review and paste screens and read by nothing else. What stays English is everything around them
// that is a token: `CoachPlanIssue.subject` (never drawn; a test and the grouping read it), the
// author's own text quoted back (names, titles, the unrecognised token), and the vocabularies listed
// after "Expected one of:", which are the plan's wire tokens (`CoachPlanTokens`).
//
// Whole sentences only. Where a sentence used to splice an English fallback label ("a planned
// workout", "Day 3 session", "an edit") into itself, the unnamed case is its own sentence. A count
// that can be zero or one is a plural-ruled count phrase; the "accepts up to" limits and the counts
// that exceed them are always several, so they are plain numbers.

import Foundation

/// The coach-plan decode and validation sentences. Stateless and `nonisolated`: validation runs from
/// nonisolated code.
nonisolated enum CoachPlanIssueCopy {

    // MARK: - Decode bounds (always more than the limit, so never singular)

    static func tooManyDays(_ count: Int) -> String {
        String(localized: "coachPlan.decode.tooManyDays", defaultValue: "This plan has \(count) days. Fernlet accepts up to \(CoachPlanLimits.maxDays).", bundle: .module,
               comment: "Pasted coach plan refused. Arguments: how many days it has (always more than the limit), then the limit.")
    }

    static func tooManySessions(dayIndex: Int, count: Int) -> String {
        String(localized: "coachPlan.decode.tooManySessions", defaultValue: "Day \(dayIndex) has \(count) sessions. Fernlet accepts up to \(CoachPlanLimits.maxSessionsPerDay) per day.", bundle: .module,
               comment: "Pasted coach plan refused. Arguments: the plan day, how many sessions it has (always more than the limit), then the limit.")
    }

    static func tooManyExercises(sessionTitle: String, count: Int) -> String {
        guard sessionTitle != CoachPlanDecodeError.unnamedEditTitle else {
            return String(localized: "coachPlan.decode.tooManyEditExercises", defaultValue: "\"an edit\" has \(count) exercises. Fernlet accepts up to \(CoachPlanLimits.maxExercisesPerSession) per session.", bundle: .module,
                          comment: "Pasted coach plan refused: one of its changes to a planned workout lists too many exercises. Arguments: how many (always more than the limit), then the limit.")
        }
        return String(localized: "coachPlan.decode.tooManyExercises", defaultValue: "\"\(sessionTitle)\" has \(count) exercises. Fernlet accepts up to \(CoachPlanLimits.maxExercisesPerSession) per session.", bundle: .module,
                      comment: "Pasted coach plan refused. Arguments: the session's title as the plan wrote it, how many exercises it lists (always more than the limit), then the limit.")
    }

    static func tooManyNewExercises(_ count: Int) -> String {
        String(localized: "coachPlan.decode.tooManyNewExercises", defaultValue: "This plan defines \(count) new exercises. Fernlet accepts up to \(CoachPlanLimits.maxNewExercises).", bundle: .module,
               comment: "Pasted coach plan refused. Arguments: how many new exercises it defines (always more than the limit), then the limit.")
    }

    static func tooManyEdits(_ count: Int) -> String {
        String(localized: "coachPlan.decode.tooManyEdits", defaultValue: "This plan changes \(count) workouts you'd already planned. Fernlet accepts up to \(CoachPlanLimits.maxEdits).", bundle: .module,
               comment: "Pasted coach plan refused. Arguments: how many planned workouts it changes (always more than the limit), then the limit.")
    }

    static func tooManyMuscles(exerciseName: String, count: Int) -> String {
        String(localized: "coachPlan.decode.tooManyMuscles", defaultValue: "\"\(exerciseName)\" lists \(count) muscles. Fernlet knows \(MuscleGroup.allCases.count).", bundle: .module,
               comment: "Pasted coach plan refused. Arguments: the exercise's name as the plan wrote it, how many muscles it lists (always more than Fernlet knows), then how many Fernlet knows.")
    }

    // MARK: - Exercise definitions

    static var definitionHasNoName: String {
        String(localized: "coachPlan.issue.definitionHasNoName", defaultValue: "An exercise definition has no name.", bundle: .module,
               comment: "Coach plan review problem: a new exercise the plan defines has no name")
    }

    static var definitionNameTooLong: String {
        String(localized: "coachPlan.issue.definitionNameTooLong", defaultValue: "That exercise name is too long.", bundle: .module,
               comment: "Coach plan review problem: a new exercise's name is longer than Fernlet accepts")
    }

    static func definitionHasNoPrimaryMuscles(_ name: String) -> String {
        String(localized: "coachPlan.issue.definitionHasNoPrimaryMuscles", defaultValue: "\"\(name)\" lists no primary muscles, so Fernlet can't check it against the muscles you avoid.", bundle: .module,
               comment: "Coach plan review problem. Argument: the new exercise's name as the plan wrote it.")
    }

    static func unknownMuscle(_ token: String) -> String {
        String(localized: "coachPlan.issue.unknownMuscle", defaultValue: "Unknown muscle \"\(token)\". Expected one of: \(CoachPlanTokens.muscleVocabulary)", bundle: .module,
               comment: "Coach plan review problem. Arguments: the muscle word the plan used, then the plan format's muscle words, which are code and stay in English.")
    }

    static func unknownEquipment(_ token: String) -> String {
        String(localized: "coachPlan.issue.unknownEquipment", defaultValue: "Unknown equipment \"\(token)\". Expected one of: \(CoachPlanTokens.equipmentVocabulary)", bundle: .module,
               comment: "Coach plan review problem. Arguments: the equipment word the plan used, then the plan format's equipment words, which are code and stay in English.")
    }

    static func unknownMovementPattern(_ token: String) -> String {
        String(localized: "coachPlan.issue.unknownMovementPattern", defaultValue: "Unknown movement pattern \"\(token)\". Expected one of: \(CoachPlanTokens.movementVocabulary)", bundle: .module,
               comment: "Coach plan review problem. Arguments: the movement word the plan used, then the plan format's movement words, which are code and stay in English.")
    }

    // MARK: - The plan as a whole

    static func newerFormat(_ version: Int) -> String {
        String(localized: "coachPlan.issue.newerFormat", defaultValue: "This plan uses a newer format (version \(version)). Update Fernlet to open it.", bundle: .module,
               comment: "Coach plan review problem. Argument: the plan format's version number.")
    }

    static var notAFernletPlan: String {
        String(localized: "coachPlan.issue.notAFernletPlan", defaultValue: "This doesn't look like a Fernlet workout plan.", bundle: .module,
               comment: "Coach plan review problem: the pasted JSON is not in Fernlet's plan format")
    }

    static var planIsEmpty: String {
        String(localized: "coachPlan.issue.planIsEmpty", defaultValue: "This plan has no days and changes nothing.", bundle: .module,
               comment: "Coach plan review problem: the plan proposes nothing at all")
    }

    // MARK: - Days

    static func dayOutOfRange(_ dayIndex: Int) -> String {
        String(localized: "coachPlan.issue.dayOutOfRange", defaultValue: "Day numbers must run from 1 to \(CoachPlanLimits.maxDays); found \(dayIndex).", bundle: .module,
               comment: "Coach plan review problem. Arguments: the highest day number allowed, then the day number the plan used.")
    }

    static func dayRepeated(_ dayIndex: Int) -> String {
        String(localized: "coachPlan.issue.dayRepeated", defaultValue: "Day \(dayIndex) appears more than once.", bundle: .module,
               comment: "Coach plan review problem. Argument: the plan day number that appears twice.")
    }

    static func dayTreatedAsRest(_ dayIndex: Int) -> String {
        String(localized: "coachPlan.issue.dayTreatedAsRest", defaultValue: "Day \(dayIndex) has no sessions and isn't marked a rest day; it will be treated as rest.", bundle: .module,
               comment: "Coach plan review note (the plan still imports). Argument: the plan day number.")
    }

    // MARK: - Changes to planned workouts

    static func unknownChangeType(_ token: String) -> String {
        let vocabulary = CoachPlanEditAction.allCases.map(\.rawValue).joined(separator: ", ")
        return String(localized: "coachPlan.issue.unknownChangeType", defaultValue: "Unknown change type \"\(token)\". Expected one of: \(vocabulary)", bundle: .module,
                      comment: "Coach plan review problem. Arguments: the change word the plan used, then the plan format's change words, which are code and stay in English.")
    }

    static var duplicateChangeTarget: String {
        String(localized: "coachPlan.issue.duplicateChangeTarget", defaultValue: "Two changes target the same planned workout; Fernlet can't apply both.", bundle: .module,
               comment: "Coach plan review problem: two changes in the plan name the same planned workout")
    }

    static var replacementListsNothing: String {
        String(localized: "coachPlan.issue.replacementListsNothing", defaultValue: "A replacement has to say what the workout becomes, and this one lists no exercises.", bundle: .module,
               comment: "Coach plan review problem: a change replaces a planned workout but lists no exercises")
    }

    /// `title` is the change's workout title, nil when the plan gave none.
    static func changeAltersNothing(title: String?) -> String {
        guard let title else {
            return String(localized: "coachPlan.issue.changeAltersNothingUntitled", defaultValue: "A change to \"a planned workout\" alters nothing; it will be skipped.", bundle: .module,
                          comment: "Coach plan review note (the plan still imports): a change to an unnamed planned workout changes nothing")
        }
        return String(localized: "coachPlan.issue.changeAltersNothing", defaultValue: "A change to \"\(title)\" alters nothing; it will be skipped.", bundle: .module,
                      comment: "Coach plan review note (the plan still imports). Argument: the planned workout's title as the plan wrote it.")
    }

    /// `title` as in ``changeAltersNothing(title:)``.
    static func changeHasUnnamedExercise(title: String?) -> String {
        guard let title else {
            return String(localized: "coachPlan.issue.changeHasUnnamedExerciseUntitled", defaultValue: "A change to \"a planned workout\" has an exercise with no name.", bundle: .module,
                          comment: "Coach plan review problem: a change to an unnamed planned workout lists an exercise without a name")
        }
        return String(localized: "coachPlan.issue.changeHasUnnamedExercise", defaultValue: "A change to \"\(title)\" has an exercise with no name.", bundle: .module,
                      comment: "Coach plan review problem. Argument: the planned workout's title as the plan wrote it.")
    }

    // MARK: - Sessions and exercises

    static func undefinedExercise(_ name: String) -> String {
        String(localized: "coachPlan.issue.undefinedExercise", defaultValue: "\"\(name)\" isn't in your exercise list and the plan doesn't define it. Ask for its muscles, equipment, and movement pattern, then paste again.", bundle: .module,
               comment: "Coach plan review problem. Argument: the exercise's name as the plan wrote it.")
    }

    static func unknownSessionKind(_ token: String) -> String {
        String(localized: "coachPlan.issue.unknownSessionKind", defaultValue: "Unknown session kind \"\(token)\"; treating it as strength.", bundle: .module,
               comment: "Coach plan review note (the plan still imports). Argument: the session kind word the plan used, which is code.")
    }

    /// `title` is the session's title, empty when the plan gave none (then the sentence names its day).
    static func sessionPrescribesNothing(title: String, dayIndex: Int) -> String {
        guard !title.isEmpty else {
            return String(localized: "coachPlan.issue.sessionPrescribesNothingUntitled", defaultValue: "\"Day \(dayIndex) session\" has no exercises and no conditioning description.", bundle: .module,
                          comment: "Coach plan review problem: an untitled session prescribes nothing. Argument: the plan day number.")
        }
        return String(localized: "coachPlan.issue.sessionPrescribesNothing", defaultValue: "\"\(title)\" has no exercises and no conditioning description.", bundle: .module,
                      comment: "Coach plan review problem. Argument: the session's title as the plan wrote it.")
    }

    /// `title` as in ``sessionPrescribesNothing(title:dayIndex:)``.
    static func sessionHasUnnamedExercise(title: String, dayIndex: Int) -> String {
        guard !title.isEmpty else {
            return String(localized: "coachPlan.issue.sessionHasUnnamedExerciseUntitled", defaultValue: "\"Day \(dayIndex) session\" has an exercise with no name.", bundle: .module,
                          comment: "Coach plan review problem: an untitled session lists an exercise without a name. Argument: the plan day number.")
        }
        return String(localized: "coachPlan.issue.sessionHasUnnamedExercise", defaultValue: "\"\(title)\" has an exercise with no name.", bundle: .module,
                      comment: "Coach plan review problem. Argument: the session's title as the plan wrote it.")
    }

    /// "Squat: 0 sets is outside 1-20; it will be clamped." The set count can be zero or negative, so
    /// it is a plural-ruled count phrase.
    static func setsClamped(name: String, sets: Int) -> String {
        let count = String(localized: "coachPlan.count.sets", defaultValue: "\(sets) sets", bundle: .module,
                           comment: "A number of sets, e.g. '0 sets', placed inside a coach plan review note. Needs a plural variation.")
        return String(localized: "coachPlan.issue.setsClamped", defaultValue: "\(name): \(count) is outside 1-\(CoachPlanLimits.maxSets); it will be clamped.", bundle: .module,
                      comment: "Coach plan review note (the plan still imports). Arguments: the exercise's name, its set count (e.g. '0 sets'), then the most sets Fernlet accepts.")
    }

    static func exerciseHasNoReps(_ name: String) -> String {
        String(localized: "coachPlan.issue.exerciseHasNoReps", defaultValue: "\(name) has no reps.", bundle: .module,
               comment: "Coach plan review problem. Argument: the exercise's name as the plan wrote it.")
    }

    /// "Row: 1200s rest is outside 0-900; it will be clamped." `s` is the seconds symbol.
    static func restClamped(name: String, seconds: Int) -> String {
        String(localized: "coachPlan.issue.restClamped", defaultValue: "\(name): \(seconds)s rest is outside 0-\(CoachPlanLimits.maxRestSeconds); it will be clamped.", bundle: .module,
               comment: "Coach plan review note (the plan still imports). Arguments: the exercise's name, its rest in seconds ('s' is the seconds symbol), then the most Fernlet accepts.")
    }

    // MARK: - Free-text length (always longer than the limit, so never singular)

    /// "That plan title is 95 characters. Fernlet accepts up to 80." One whole sentence per field.
    static func tooLong(_ field: CoachPlanTextField, count: Int, limit: Int) -> String {
        switch field {
        case .planTitle: String(localized: "coachPlan.issue.tooLong.planTitle", defaultValue: "That plan title is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem. Arguments: the length (always over the limit), then the limit.")
        case .coachName: String(localized: "coachPlan.issue.tooLong.coachName", defaultValue: "That coach name is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: the name the plan gives its author is too long. Arguments: the length (always over the limit), then the limit.")
        case .planNotes: String(localized: "coachPlan.issue.tooLong.planNotes", defaultValue: "That plan notes is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: the plan's notes are too long. Arguments: the length (always over the limit), then the limit.")
        case .dayTitle: String(localized: "coachPlan.issue.tooLong.dayTitle", defaultValue: "That day title is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem. Arguments: the length (always over the limit), then the limit.")
        case .workoutTitle: String(localized: "coachPlan.issue.tooLong.workoutTitle", defaultValue: "That workout title is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: a change's new workout title is too long. Arguments: the length (always over the limit), then the limit.")
        case .notes: String(localized: "coachPlan.issue.tooLong.notes", defaultValue: "That notes is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: a change's notes are too long. Arguments: the length (always over the limit), then the limit.")
        case .conditioning: String(localized: "coachPlan.issue.tooLong.conditioning", defaultValue: "That conditioning is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: a conditioning description (e.g. '20 min easy run') is too long. Arguments: the length (always over the limit), then the limit.")
        case .sessionTitle: String(localized: "coachPlan.issue.tooLong.sessionTitle", defaultValue: "That session title is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem. Arguments: the length (always over the limit), then the limit.")
        case .sessionNotes: String(localized: "coachPlan.issue.tooLong.sessionNotes", defaultValue: "That session notes is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: a session's notes are too long. Arguments: the length (always over the limit), then the limit.")
        case .exerciseName: String(localized: "coachPlan.issue.tooLong.exerciseName", defaultValue: "That exercise name is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem. Arguments: the length (always over the limit), then the limit.")
        case .reps: String(localized: "coachPlan.issue.tooLong.reps", defaultValue: "That reps is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: an exercise's reps text (e.g. '8-10') is too long. Arguments: the length (always over the limit), then the limit.")
        case .guidance: String(localized: "coachPlan.issue.tooLong.guidance", defaultValue: "That guidance is \(count) characters. Fernlet accepts up to \(limit).", bundle: .module, comment: "Coach plan review problem: an exercise's guidance text is too long. Arguments: the length (always over the limit), then the limit.")
        }
    }
}

/// The plan's free-text fields a length check can name, one whole sentence each in
/// ``CoachPlanIssueCopy/tooLong(_:count:limit:)`` (they used to be English nouns spliced into one).
nonisolated enum CoachPlanTextField: Sendable {
    case planTitle, coachName, planNotes, dayTitle, workoutTitle, notes, conditioning
    case sessionTitle, sessionNotes, exerciseName, reps, guidance
}
