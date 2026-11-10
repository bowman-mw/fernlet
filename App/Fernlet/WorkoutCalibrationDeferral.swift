import FernletDomainModel
import Foundation

/// "Not now" for the monthly strength check (w4, 2026-11-10): the moment from which Fernlet may offer
/// a strength check again.
///
/// Written three ways, each two weeks (``deferralDays``) ahead of the moment it happens:
/// - the person taps "Not now" on a strength check in the guided runner
///   (`FernletStore.guidedPutOffStrengthCheck()`);
/// - a guided run finishes with its test set (or every max attempt) skipped
///   (``noteFinished(_:at:in:)``, from the run's own finish, a Lock Screen finish included);
/// - the person logs by hand, today, the lift today's plan had turned into a strength check
///   (``noteHandLogged(_:plan:at:in:)``, from `FernletStore.addWorkout(_:date:)`).
///
/// The planner's "is a check due" rule reads it (`FernletStore.strengthCheckAskAgainFrom` →
/// `WorkoutLoadContextBuilder` → `WorkoutCalibration.isDue`) and offers no check before that day. A logged test set needs no clearing here: it dates the next check four weeks on by
/// itself, which is always later than a deferral written before it.
///
/// **Device-local `UserDefaults`, never synced**, beside ``WorkoutCuePreferences``: putting a check
/// off is about the session in hand on this phone, and the check it puts off is planned on this
/// phone. "Delete everything" clears it (``clear(in:)``, `Docs/PrivacyWipeCoverage.md`): it is a trace
/// of what the person did on a day, not a preference. The key is a FROZEN persisted token, spelled
/// once here and read and written only through this type, so the wipe wall resolves every access to
/// its literal.
enum WorkoutCalibrationDeferral {
    /// `Double`, unset by default: seconds since 1970 of the moment a strength check may be offered
    /// again. Only a value no further ahead than ``deferralDays`` (and a day's slack) is read back.
    static let askAgainFromKey = "fernlet.workoutCalibration.askAgainFrom"

    /// Days a "Not now" puts the strength check off for (owner, 2026-11-10: "asks again in 2 weeks").
    static let deferralDays = 14

    /// The moment a strength check may be offered again, or nil when none is stored — or the stored
    /// one is not a moment a "Not now" could have written: not finite, or further ahead of `now` than
    /// ``deferralDays`` plus a day (a clock that was set forward and back must never put the check off
    /// for longer than two weeks). A moment already past is returned as it is; it defers nothing.
    ///
    /// - Parameter now: The reading moment; the planner may pass the start of today.
    static func askAgainFrom(asOf now: Date = Date(), in defaults: UserDefaults = .standard) -> Date? {
        guard let seconds = defaults.object(forKey: askAgainFromKey) as? Double, seconds.isFinite else { return nil }
        let stored = Date(timeIntervalSince1970: seconds)
        let latest = now.addingTimeInterval(TimeInterval(deferralDays + 1) * 86_400)
        return stored <= latest ? stored : nil
    }

    /// Whether a strength check is put off at `now`: a stored moment that has not come yet.
    static func isPutOff(asOf now: Date = Date(), in defaults: UserDefaults = .standard) -> Bool {
        askAgainFrom(asOf: now, in: defaults).map { now < $0 } ?? false
    }

    /// Puts the strength check off for ``deferralDays`` from `now` and returns the moment it may be
    /// offered again. Never moves an already-stored later moment earlier.
    @discardableResult
    static func putOff(from now: Date = Date(), in defaults: UserDefaults = .standard) -> Date {
        let proposed = now.addingTimeInterval(TimeInterval(deferralDays) * 86_400)
        let kept = askAgainFrom(asOf: now, in: defaults).map { max($0, proposed) } ?? proposed
        defaults.set(kept.timeIntervalSince1970, forKey: askAgainFromKey)
        return kept
    }

    /// A finished guided run: when its strength check went untested
    /// (``GuidedWorkoutRunState/strengthCheckWasSkipped``), that counts as "not now" from the run's
    /// finish (`finishedAt`, else `now`). Any other run changes nothing. Returns whether it wrote.
    @discardableResult
    static func noteFinished(
        _ run: GuidedWorkoutRunState, at now: Date = Date(), in defaults: UserDefaults = .standard
    ) -> Bool {
        guard run.isFinishedNaturally, run.strengthCheckWasSkipped else { return false }
        putOff(from: run.finishedAt ?? now, in: defaults)
        return true
    }

    /// A workout logged by hand: when today's plan had turned a lift into a strength check and this
    /// workout logs that lift, the check was passed over — "not now" from `now` (w4). A guided row
    /// never counts here (its own finish does, ``noteFinished(_:at:in:)``), nor a workout that leaves
    /// the check's lift out, nor one logged while a check is already put off (so a habitual hand
    /// logger is asked again every two weeks, never pushed back forever). Returns whether it wrote.
    @discardableResult
    static func noteHandLogged(
        _ workout: Workout, plan: WorkoutProgram.DayPlan?, at now: Date = Date(), in defaults: UserDefaults = .standard
    ) -> Bool {
        guard workout.loggedFromGuidedSession != true, !isPutOff(asOf: now, in: defaults),
              let plan, !workout.isHealthImported else { return false }
        let due = strengthCheckLifts(in: plan)
        guard !due.isEmpty, !due.isDisjoint(with: loggedLifts(in: workout)) else { return false }
        putOff(from: now, in: defaults)
        return true
    }

    /// The lifts `plan` turned into a strength check: its test sets and max attempts, by normalized
    /// name. Bounded by the plan's steps.
    static func strengthCheckLifts(in plan: WorkoutProgram.DayPlan) -> Set<String> {
        var lifts: Set<String> = []
        for session in plan.sessions {
            for step in session.exercises where step.guidance?.calibration == .test || step.guidance?.calibration == .attempt {
                lifts.insert(WorkoutExerciseCatalog.normalizedName(step.name))
            }
        }
        return lifts
    }

    /// The lifts a hand-logged workout records, by normalized name: its set-by-set results and the
    /// lifts its lines name.
    static func loggedLifts(in workout: Workout) -> Set<String> {
        var lifts = Set((workout.exerciseResults ?? []).map { WorkoutExerciseCatalog.normalizedName($0.name) })
        for line in workout.exerciseLines {
            guard let parsed = ExerciseLineParser.parse(line) else { continue }
            lifts.insert(WorkoutExerciseCatalog.normalizedName(parsed.name))
        }
        return lifts
    }

    /// Removes the stored moment: "Delete everything".
    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: askAgainFromKey)
    }
}

extension FernletStore {
    /// The moment a put-off strength check may be offered again on this device, or nil when none is
    /// put off (``WorkoutCalibrationDeferral/askAgainFrom(asOf:in:)``) — what the planner's load
    /// context reads (w4).
    var strengthCheckAskAgainFrom: Date? {
        WorkoutCalibrationDeferral.askAgainFrom(in: calibrationDeferralDefaults)
    }
}
