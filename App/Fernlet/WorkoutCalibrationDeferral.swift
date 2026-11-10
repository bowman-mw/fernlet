import Foundation

/// "Not now" for the monthly strength check (w4, 2026-11-10): the moment from which Fernlet may offer
/// a strength check again.
///
/// Written two ways, both two weeks (``deferralDays``) ahead of the moment they happen:
/// - the person taps "Not now" on a strength check in the guided runner
///   (`FernletStore.guidedPutOffStrengthCheck()`);
/// - a guided run finishes with its test set (or every max attempt) skipped
///   (``noteFinished(_:at:in:)``, from the run's own finish, a Lock Screen finish included).
///
/// The planner's "is a check due" rule reads ``askAgainFrom(asOf:in:)`` and offers no check before
/// that moment. A logged test set needs no clearing here: it dates the next check four weeks on by
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

    /// Removes the stored moment: "Delete everything".
    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: askAgainFromKey)
    }
}
