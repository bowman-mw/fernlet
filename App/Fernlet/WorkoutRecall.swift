import Foundation
import FernletDomainModel

// MARK: - Recent-logged-workout recall (MOVE-08)
//
// The query behind the Log sheet's "Log it again" entry card. Deliberately separate from
// `previousWeekPlannedWorkout(for:)`, which reads PLANNED rows for the plan sheet's
// "Copy previous week" — this one reads what was actually LOGGED, so "again" means a workout
// that really happened.

/// A logged workout together with the day it was logged on — what the Log sheet's
/// "Log it again" card renders ("Wednesday · Upper strength") and copies from.
///
/// A plain value pair rather than a tuple so call sites and tests can name it.
struct RecentLoggedWorkout: Equatable {
    /// The day-record key ("yyyy-MM-dd") the workout is filed under.
    var dayKey: String
    /// The logged row itself, exactly as stored.
    var workout: Workout
}

extension FernletStore {
    /// The most recently logged workout of the given kind (strength vs. activity), or nil when
    /// nothing of that kind has ever been logged.
    ///
    /// Reads day records newest-day-first, and within a day picks the latest row by `loggedAt` —
    /// so on a two-log day "most recent" means the later one, not whichever the array happened to
    /// hold first. Today's own logs count too: asking to log a
    /// workout again is a legitimate same-day request, and the Save is still the user's call.
    ///
    /// Bounded: one pass over the loaded day dictionary (sorted keys), one pass over each
    /// matching day's workouts.
    func mostRecentLoggedWorkout(mode: WorkoutMode) -> RecentLoggedWorkout? {
        let days = loadDays()
        // Newest day first; day keys are "yyyy-MM-dd" so string order is date order.
        for key in days.keys.sorted(by: >) {
            guard let day = days[key] else { continue }
            let candidates = day.workouts.filter { $0.mode == mode }
            guard !candidates.isEmpty else { continue }
            let latest = candidates.max { $0.loggedAt < $1.loggedAt }
            if let latest { return RecentLoggedWorkout(dayKey: key, workout: latest) }
        }
        return nil
    }
}
