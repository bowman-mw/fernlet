// WorkoutPlannerCopy+DayNote.swift
// FernletDomainModel
//
// What the plan's note says about the plan sheet's "Anything else?" (the owner's fix e3, 2026-11-10):
// one sentence for each thing the planner applied from it, or one that says nothing could be applied
// and points to Equipment & limits. They replace "Noted: …", which echoed the text back whether or
// not anything had been done with it. The reading itself is ``WorkoutDayNote``.

import Foundation

extension WorkoutPlannerCopy {

    // MARK: - "Anything else?" (WorkoutDayNote)

    /// "Going easy on your knee today."
    static func dayNoteEasing(_ areas: String) -> String {
        String(localized: "workoutNote.dayNote.easing", defaultValue: "Going easy on your \(areas) today.", bundle: .module,
               comment: "Workout session note: the person typed that a body area is sore in the plan sheet's 'Anything else?' field, so today's plan trains around it (lighter, supported moves). The argument is the area or areas in lowercase, e.g. 'knee', 'knee and shoulder'.")
    }

    /// "Already leaving out work for your knee."
    static func dayNoteAlreadyLeftOut(_ areas: String) -> String {
        String(localized: "workoutNote.dayNote.alreadyLeftOut", defaultValue: "Already leaving out work for your \(areas).", bundle: .module,
               comment: "Workout session note: the person typed a body area in the plan sheet's 'Anything else?' field, and their saved limits already leave that area's exercises out entirely, so nothing more was needed. The argument is the area or areas in lowercase, e.g. 'knee'.")
    }

    /// "Kept to about 20 minutes, as you asked."
    static func dayNoteShortened(minutes: Int) -> String {
        String(localized: "workoutNote.dayNote.shortened", defaultValue: "Kept to about \(minutes) minutes, as you asked.", bundle: .module,
               comment: "Workout session note: the person typed that they are short on time in the plan sheet's 'Anything else?' field, so the session was fitted into a shorter length. The argument is that length in minutes (20, 30, 45 or 60).")
    }

    /// "Picked to match your note: Kettlebell swing."
    static func dayNoteMatched(_ exercises: String) -> String {
        String(localized: "workoutNote.dayNote.matched", defaultValue: "Picked to match your note: \(exercises).", bundle: .module,
               comment: "Workout session note: exercises in the plan whose names share a word with what the person typed in the plan sheet's 'Anything else?' field. The argument is a comma-separated list of exercise names.")
    }

    /// Nothing in the text could be applied; where lasting limits and equipment are set.
    static var dayNoteNothingApplied: String {
        String(localized: "workoutNote.dayNote.nothingApplied",
               defaultValue: "Nothing in your note could be applied to this plan. Lasting limits and equipment are set in Equipment & limits.",
               bundle: .module,
               comment: "Workout session note: the planner could not apply anything the person typed in the plan sheet's 'Anything else?' field. 'Equipment & limits' is the name of the button on the same sheet that opens Workout setup; translate it exactly as that button is translated.")
    }
}
