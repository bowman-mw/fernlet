import Foundation

/// The length a finished guided run logs, worked out from the run's own timestamps.
///
/// Wall clock from ``GuidedWorkoutRunState/startedAt`` to ``GuidedWorkoutRunState/finishedAt``. The
/// runner has no pause, and time with the phone locked or the app in the background is still session
/// time (rests run on the Lock Screen), so nothing is subtracted.
///
/// Stored where a hand-logged workout keeps its length, `Workout.duration`, in whole minutes rounded the
/// way the Log and Edit sheets round their field (`WorkoutSheetRules.durationMinutes`), and never less
/// than one minute (a zero-length Health workout is no record of a session). Capped at
/// ``capMinutes``: a run left open overnight logs three hours and says so in its notes
/// (``cappedNote``) instead of claiming eleven. The run state's timestamps persist as whole seconds,
/// so a run resumed after a relaunch is off by under a second.
///
/// The Apple Health copy follows from the row: `HealthKitService.saveWorkout` ends the `HKWorkout` at
/// `completedAt` (the run's finish) and starts it `duration` minutes earlier, so its start is the real
/// start to within half a minute, and its duration always equals the one the log shows.
enum GuidedRunDuration {
    /// The longest a guided session logs, in minutes: three hours. ``cappedNote`` names the same
    /// figure in words, so the two change together (a test pins this value).
    nonisolated static let capMinutes = 180

    /// A finished run's logged minutes, and whether the cap cut them short.
    ///
    /// - Returns: nil when either timestamp is missing (a run persisted before durations were
    ///   recorded, which logs without one, as every guided run used to) or when the clock ran
    ///   backwards between them (a manual clock change), rather than guessing.
    static func minutes(startedAt: Date?, finishedAt: Date?) -> (minutes: Int, capped: Bool)? {
        guard let startedAt, let finishedAt else { return nil }
        let seconds = finishedAt.timeIntervalSince(startedAt)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let rounded = (seconds / 60).rounded()
        guard rounded <= Double(capMinutes) else { return (capMinutes, true) }
        return (max(1, Int(rounded)), false)
    }

    /// The line a capped run's notes end with, so the three hours read as a ceiling rather than a
    /// measurement, and the Edit sheet's duration field is where to put the real time.
    static var cappedNote: String {
        String(
            localized: "workout.guided.durationCappedNote",
            defaultValue: "This session was open for more than 3 hours, so it's logged as 3. Edit the duration if you know the real time.",
            comment: "Added to the notes of a guided workout whose runner was left open for more than three hours (for example overnight). The logged duration is capped at 3 hours; the sentence tells the person they can correct it in the Edit sheet. Keep the number 3 in step with the cap."
        )
    }

    /// The notes a guided run logs: the plan's own notes, followed by ``cappedNote`` when the cap
    /// applied.
    static func notes(_ planNotes: String, capped: Bool) -> String {
        guard capped else { return planNotes }
        let trimmed = planNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? cappedNote : trimmed + "\n\n" + cappedNote
    }
}
