//
//  GuidedRunSpokenCues.swift
//  Fernlet
//
//  Opt-in spoken cues for the guided workout runner (comparison report idea 11, 2026-10-20).
//
//  Shred's voice coach says the next exercise and the last weight used, and reviewers singled it out
//  because it let them set up without looking at the phone; NTC's and Shred's coach audio also draws
//  complaints for fighting the person's music. So "Spoken cues" is off until the person turns it on
//  (Workout setup › Cues during a workout, ``WorkoutCuePreferences``), says the same short, calm words
//  the screen shows, and plays over the music without pausing it (FernletUI's `FernletSpeaker`).
//
//  This file is the words: pure functions of the run state for each moment the runner already cues.
//  `GuidedRunCueDirector` decides WHEN — the same moments, the same app-is-in-front rule, the same
//  lateness guard as the haptics — and `FernletSpeaker` decides HOW: aloud when VoiceOver is off, and
//  through the VoiceOver announcer when it is on, adding only what VoiceOver's own runner lines
//  (`GuidedRunAnnouncement`) do not already say, so nothing is said twice.
//
//  Every phrase is catalog text, spoken as the screen shows it. An exercise's name is the run's own
//  (`GuidedWorkoutRunState.Exercise.name`, as drawn on the runner card); a weight is formatted by the
//  same helper the Live Activity speaks it with (`WorkoutActivityLoadText`). No praise, no counts, no
//  sealed content.
//

import Foundation
import FernletUI

/// What the guided runner says aloud when spoken cues are on, for each moment it cues.
///
/// Pure: run states and events in, a resolved sentence out (nil for a moment that says nothing).
/// Checked in `GuidedRunSpokenCueTests` against real ``GuidedWorkoutRunState`` transitions.
enum GuidedRunSpokenCue {

    /// The words for a moment on the run's own clock — a rest's end, a hold's start or end — or nil
    /// for an event the clock never cues.
    ///
    /// A cardio segment's start says its pace ("Go — hard.", VoiceOver's own segment line), and its
    /// end says a timed part ran out rather than a hold.
    ///
    /// - Parameters:
    ///   - event: The cue the director is playing.
    ///   - state: The run as it is now.
    static func timed(_ event: FernletFeedbackEvent, in state: GuidedWorkoutRunState?) -> String? {
        let paceRaw = state?.currentExercise?.segment?.paceRaw
        switch event {
        case .restEnded:
            return restOver
        case .holdStarted:
            guard let paceRaw else { return String(localized: GuidedRunAnnouncement.holdStartedLine) }
            return String(localized: GuidedSegmentWords.goLine(paceRaw))
        case .holdEnded:
            return paceRaw == nil ? holdDone : partDone
        // A zone drift (idea 9) speaks through the zone director's own VoiceOver line, not here.
        case .setLogged, .blockChanged, .workoutFinished, .zoneDrift:
            return nil
        }
    }

    /// The words for an in-app move from `before` to `after`, or nil when the move says nothing.
    ///
    /// Only a live run's real move speaks, in this order: a natural finish ("Workout done."), then a
    /// new step (its name and side, or an interval's pace and round, with a lift's suggested weight
    /// and last time), then a hold that ran out without moving on ("Hold's done."). A skipped rest, a
    /// logged set that starts a rest, and an abandon say nothing. A hold that ran out INTO a new step
    /// says only the new step — "Next: …" already says the hold is over.
    static func move(
        from before: GuidedWorkoutRunState?,
        to after: GuidedWorkoutRunState?,
        cause: GuidedRunCuePlan.Cause
    ) -> String? {
        guard let before, before.isWorking || before.isResting, let after, after != before else { return nil }
        if after.isFinishedNaturally { return workoutDone }
        guard !after.isDone else { return nil }
        if after.isWorking, after.exerciseIndex != before.exerciseIndex, let exercise = after.currentExercise {
            return stepLine(exercise, in: after, first: false)
        }
        guard cause == .holdRanOut else { return nil }
        return before.currentExercise?.segment == nil ? holdDone : partDone
    }

    /// The words at Start (round 2, R4): the run's first step, said once as the run begins so the
    /// person can set up without looking — "First: Goblet squat. Suggested weight 35 pounds …", a
    /// warm-up set's own "Warm-up set 1 of 3: Back squat. …", a one-sided step's side, or an interval's
    /// pace and round. Nil for a run that is not working on a step.
    static func start(_ run: GuidedWorkoutRunState) -> String? {
        guard run.isWorking, let exercise = run.currentExercise else { return nil }
        return stepLine(exercise, in: run, first: true)
    }

    /// The new lift's suggested weight and last time for a move onto it — the one thing spoken cues
    /// add to VoiceOver's own "Next exercise: …" line — or nil for any other move.
    static func loadClause(from before: GuidedWorkoutRunState?, to after: GuidedWorkoutRunState?) -> String? {
        guard let before, let after, after.isWorking, after.exerciseIndex != before.exerciseIndex else { return nil }
        return loadClause(for: after)
    }

    /// The current step's weight — "Suggested weight 105 pounds" while it is still the suggestion,
    /// "Weight 110 pounds" once the lifter picked their own — and last time's numbers, as one clause in
    /// the locale's list format; nil for a timed step or a lift with neither.
    ///
    /// The range is left out on purpose: the cue is for setting up a bar, and one number does that.
    static func loadClause(for run: GuidedWorkoutRunState) -> String? {
        guard let load = run.currentLoad else { return nil }
        let clauses = [WorkoutActivityLoadText.spokenWeight(load), WorkoutActivityLoadText.spokenLastTime(load)]
            .compactMap { $0 }
        guard !clauses.isEmpty else { return nil }
        return clauses.formatted(.list(type: .and, width: .narrow))
    }

    /// Two spoken sentences as one line, in the order the locale writes them — or the first alone.
    static func sentences(_ first: String, _ second: String?) -> String {
        guard let second, !second.isEmpty else { return first }
        return String(localized: "workout.spoken.sentences", defaultValue: "\(first) \(second)",
                      comment: "Guided workout, spoken cues and VoiceOver: two spoken sentences joined into one line, e.g. 'Next: Bench press.' then 'Suggested weight 105 pounds, last time 3 by 8 at 100 pounds'. Change only the separator or the order.")
    }

    // MARK: The new step

    /// "Next: Cat-cow, left side.", "Next: Row. Suggested weight …", a warm-up set's "Warm-up set 1 of
    /// 3: Back squat. Suggested weight 95 pounds …", or an interval's "Hard, round 3 of 8." — VoiceOver's
    /// own words for the same step, minus its set count. At Start (`first`) the step is "First: …".
    private static func stepLine(
        _ exercise: GuidedWorkoutRunState.Exercise, in run: GuidedWorkoutRunState, first: Bool
    ) -> String {
        if let segment = exercise.segment {
            return segmentLine(segment, seconds: exercise.holdSeconds ?? 0)
        }
        if let warmUp = run.warmUpPosition {
            let line = GuidedWarmUpWords.setLine(index: warmUp.index, count: warmUp.count, name: exercise.name)
            return sentences(String(localized: line), loadClause(for: run))
        }
        let named = first ? firstName(exercise) : nextName(exercise)
        return sentences(named, loadClause(for: run))
    }

    /// "Next: Squat.", with the side for a one-sided step.
    private static func nextName(_ exercise: GuidedWorkoutRunState.Exercise) -> String {
        switch exercise.sideRaw {
        case "left": String(localized: "Next: \(exercise.name), left side.")
        case "right": String(localized: "Next: \(exercise.name), right side.")
        default: String(localized: "Next: \(exercise.name).")
        }
    }

    /// "First: Goblet squat." — the run's first step, said at Start — with the side for a one-sided step.
    private static func firstName(_ exercise: GuidedWorkoutRunState.Exercise) -> String {
        switch exercise.sideRaw {
        case "left":
            String(localized: "First: \(exercise.name), left side.",
                   comment: "Guided workout, spoken cue at Start: the run's first step, one-sided, e.g. 'First: Cat-cow, left side.'")
        case "right":
            String(localized: "First: \(exercise.name), right side.",
                   comment: "Guided workout, spoken cue at Start: the run's first step, one-sided, e.g. 'First: Cat-cow, right side.'")
        default:
            String(localized: "First: \(exercise.name).",
                   comment: "Guided workout, spoken cue at Start: the run's first step, e.g. 'First: Goblet squat.' A suggested weight may follow.")
        }
    }

    /// An interval part's pace and round ("Hard, round 3 of 8."), or a steady segment's pace and length
    /// in VoiceOver's own words ("Steady pace for 20 minutes.").
    private static func segmentLine(_ segment: GuidedWorkoutRunState.Segment, seconds: Int) -> String {
        guard let round = segment.round, let rounds = segment.rounds else {
            return String(localized: GuidedSegmentWords.changeLine(segment, seconds: seconds))
        }
        switch segment.paceRaw {
        case GuidedWorkoutRunState.PaceToken.hard:
            return String(localized: "Hard, round \(round) of \(rounds).",
                          comment: "Guided cardio, spoken cue: an interval's hard part begins — its round and the rounds in all, e.g. 'Hard, round 3 of 8.' Hard for this person, not all-out.")
        case GuidedWorkoutRunState.PaceToken.easy:
            return String(localized: "Easy, round \(round) of \(rounds).",
                          comment: "Guided cardio, spoken cue: an interval's easy (recovery) part begins — its round and the rounds in all, e.g. 'Easy, round 3 of 8.'")
        default:
            return String(localized: "Round \(round) of \(rounds).",
                          comment: "Guided cardio, spoken cue: an interval part with no named pace begins — its round and the rounds in all, e.g. 'Round 3 of 8.'")
        }
    }

    // MARK: Fixed lines

    /// A rest's timer reached zero. The rest still waits for the person; this only says time's up.
    private static var restOver: String {
        String(localized: "Rest's over.",
               comment: "Guided workout, spoken cue: a rest's timer reached zero. Gentle — the rest waits for the person; this only says the timer ran out.")
    }

    /// A timed hold (a stretch, a plank, a carry) ran out.
    private static var holdDone: String {
        String(localized: "Hold's done.",
               comment: "Guided workout, spoken cue: a timed hold (a stretch, a plank, a carry) ran out.")
    }

    /// One timed part of a cardio session ran out.
    private static var partDone: String {
        String(localized: "Time's up on this part.",
               comment: "Guided cardio, spoken cue: one timed part of a cardio session (an interval's hard or easy part, or a stretch of steady cardio) ran out.")
    }

    /// The run finished and was logged.
    private static var workoutDone: String {
        String(localized: "Workout done.",
               comment: "Guided workout, spoken cue: the last step is done and the workout was logged. Calm and factual — no praise.")
    }
}
