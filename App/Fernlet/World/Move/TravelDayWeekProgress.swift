import FernletDomainModel
import FernletFoundation
import Foundation

/// A week's planned sessions with travel days left out (World-Airports-Spec §13.4, screen 34: "2 of 2 sessions ·
/// Saturday was a travel day, so it's left out"), pure over the week's day records and its travel days.
///
/// - **Done:** a planned session completed this week (a logged workout carrying its plan's id).
/// - **Left out:** a planned session still not done on a travel day that has begun (today or before). It never
///   counts as missed: it is in neither the done nor the total.
/// - **Total:** done, plus every other planned session of the week (a past one not done included, which this
///   type never names as missed either).
nonisolated struct TravelDayWeekProgress: Equatable, Sendable {
    /// Planned sessions done this week.
    let done: Int
    /// Planned sessions that count this week.
    let total: Int
    /// The travel days whose planned sessions were left out, oldest first.
    let leftOutDayKeys: [String]

    /// The newest left-out day's weekday in the person's language ("Saturday"), or nil when none was.
    var leftOutWeekday: String? {
        leftOutDayKeys.last.flatMap(FernletDate.date(fromDayKey:)).map { $0.formatted(.dateTime.weekday(.wide)) }
    }

    /// The most days one week reads (a bound).
    static let maxDays = 7

    /// The week's progress, or nil when no travel day's planned session was left out (the card then isn't drawn).
    static func make(days: [FernletDay], travelDays: Set<String>, todayKey: String) -> TravelDayWeekProgress? {
        var done = 0
        var planned = 0
        var leftOut: [String] = []
        // Bounded: one week's days.
        for day in days.prefix(maxDays) {
            done += day.workouts.filter { $0.plannedWorkoutID != nil }.count
            if isForgiven(day, travelDays: travelDays, todayKey: todayKey) {
                leftOut.append(day.date)
            } else {
                planned += day.plannedWorkouts.count
            }
        }
        guard !leftOut.isEmpty else { return nil }
        return TravelDayWeekProgress(done: done, total: done + planned, leftOutDayKeys: leftOut.sorted())
    }

    /// Whether `day`'s planned sessions not done are forgiven: a travel day, today or before, with one left.
    static func isForgiven(_ day: FernletDay, travelDays: Set<String>, todayKey: String) -> Bool {
        !day.plannedWorkouts.isEmpty && day.date <= todayKey && travelDays.contains(day.date)
    }
}
