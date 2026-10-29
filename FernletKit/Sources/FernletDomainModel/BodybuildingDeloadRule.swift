// BodybuildingDeloadRule.swift
// FernletDomainModel
//
// The suggested deload week (`bb-deload-suggest`, owner's answer 1 of 2026-10-29: "Suggest, I decide").
// The rule is built now; the card that shows it waits for approval.

import Foundation

/// When Fernlet suggests a deload week, and what "Make next week a deload" and "Not now" change.
///
/// **Weeks.** A week runs Monday to Sunday (``BodybuildingWeeks``) and is named by its Monday key. The
/// *current week* is the one holding today; *next week* is the calendar week straight after it.
///
/// **A hard week** has at least ``hardWeekWorkouts`` (3) logged workouts and is not a marked deload
/// week.
///
/// **The run** is the number of hard weeks in a row that end now:
/// - if the current week is a deload week, the run is 0 (a deload resets it);
/// - otherwise the current week counts if it is already hard (workouts only add, so it can't un-become
///   hard), and is skipped if not, because it is still in progress and can't break the run yet;
/// - then each earlier week counts while it is hard, stopping at the first week that is not (too few
///   workouts, or a deload), at most ``maxLookbackWeeks`` back.
///
/// **The suggestion** targets next week when the run holds at least ``suggestAfterHardWeeks`` (6) weeks
/// and next week is not already a deload. So six finished hard weeks suggest a deload next week, and so
/// do five finished plus a current week that already has three workouts.
///
/// **Make next week a deload** marks next week (``accept(currentWeek:settings:calendar:)``). The
/// suggestion then stands down by itself, because its target is a deload.
///
/// **Not now** hides it and remembers the run it was said to: its first week and its length
/// (``decline(run:settings:)``). While that same run continues (its first week is unchanged or earlier),
/// the suggestion returns only once the run is ``askAgainAfterMoreHardWeeks`` (2) weeks longer than it
/// was. Once the run breaks or a deload resets it, the "Not now" no longer applies and a new run must
/// reach six on its own.
///
/// Nothing here is shown as a count: the run exists only to decide whether to ask.
public nonisolated enum BodybuildingDeloadRule {
    /// Workouts that make a week hard.
    public static let hardWeekWorkouts = 3
    /// Hard weeks in a row before Fernlet suggests a deload.
    public static let suggestAfterHardWeeks = 6
    /// More hard weeks, in the same run, before a "Not now" lets the suggestion return.
    public static let askAgainAfterMoreHardWeeks = 2
    /// How far back a run is counted: ten years of weeks.
    public static let maxLookbackWeeks = 520

    /// A run of hard weeks ending now.
    public struct Run: Equatable, Sendable {
        /// The Monday key of its first week, or nil when it is empty.
        public let start: String?
        /// How many hard weeks it holds.
        public let length: Int

        public init(start: String?, length: Int) {
            self.start = start
            self.length = length
        }
    }

    /// Logged workouts per week, keyed by Monday key, from the day records.
    public static func workoutsByWeek(_ days: [String: FernletDay], calendar: Calendar) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (key, day) in days where !day.workouts.isEmpty {
            guard let week = BodybuildingWeeks.weekStartKey(forDayKey: key, calendar: calendar) else { continue }
            counts[week, default: 0] += day.workouts.count
        }
        return counts
    }

    /// Whether the week starting `week` is hard.
    public static func isHard(_ week: String, workoutsByWeek: [String: Int], deloadWeeks: Set<String>) -> Bool {
        !deloadWeeks.contains(week) && (workoutsByWeek[week] ?? 0) >= hardWeekWorkouts
    }

    /// The run of hard weeks ending in the week starting `currentWeek` (see the type's rule).
    public static func run(currentWeek: String, workoutsByWeek: [String: Int], deloadWeeks: Set<String>,
                           calendar: Calendar) -> Run {
        guard !deloadWeeks.contains(currentWeek) else { return Run(start: nil, length: 0) }
        var start: String?
        var length = 0
        if isHard(currentWeek, workoutsByWeek: workoutsByWeek, deloadWeeks: deloadWeeks) {
            start = currentWeek
            length = 1
        }
        var week = BodybuildingWeeks.dayKey(currentWeek, addingDays: -7, calendar: calendar)
        for _ in 0..<maxLookbackWeeks {
            guard let candidate = week,
                  isHard(candidate, workoutsByWeek: workoutsByWeek, deloadWeeks: deloadWeeks) else { break }
            start = candidate
            length += 1
            week = BodybuildingWeeks.dayKey(candidate, addingDays: -7, calendar: calendar)
        }
        return Run(start: start, length: length)
    }

    /// The Monday key of the week Fernlet suggests as a deload, or nil when it suggests nothing.
    public static func suggestion(currentWeek: String, workoutsByWeek: [String: Int],
                                  settings: BodybuildingCalendarSettings, calendar: Calendar) -> String? {
        let deloads = Set(settings.deloadWeekStarts)
        let current = Self.run(currentWeek: currentWeek, workoutsByWeek: workoutsByWeek, deloadWeeks: deloads,
                               calendar: calendar)
        guard current.length >= suggestAfterHardWeeks,
              let target = BodybuildingWeeks.dayKey(currentWeek, addingDays: 7, calendar: calendar),
              !deloads.contains(target) else { return nil }
        if let decline = settings.deloadSuggestionDecline, let start = current.start, start <= decline.runStart,
           current.length < decline.runLength + askAgainAfterMoreHardWeeks {
            return nil
        }
        return target
    }

    /// "Make next week a deload": marks the week after `currentWeek` and forgets any "Not now".
    public static func accept(currentWeek: String, settings: inout BodybuildingCalendarSettings, calendar: Calendar) {
        guard let target = BodybuildingWeeks.dayKey(currentWeek, addingDays: 7, calendar: calendar) else { return }
        settings.setDeload(weekStart: target, true)
        settings.deloadSuggestionDecline = nil
    }

    /// "Not now": remembers `run` so the suggestion waits for two more hard weeks of it. An empty run
    /// (nothing to decline) changes nothing.
    public static func decline(run: Run, settings: inout BodybuildingCalendarSettings) {
        guard let start = run.start, run.length > 0 else { return }
        settings.deloadSuggestionDecline = BodybuildingDeloadDecline(runStart: start, runLength: run.length)
    }
}
