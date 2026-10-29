import FernletDomainModel
import Foundation

/// The Bodybuilding goal's day calendar on the store (World round 7, spec
/// `Docs/Handoff/World-Bodybuilding-Spec.md`, approved 2026-10-29).
///
/// The calendar shows only while Bodybuilding is the chosen goal; its preferences live in
/// `settings.bodybuildingCalendar` whatever the goal, so switching away and back deletes nothing. Every
/// write goes through the `settings` forwarder, which schedules the snapshot save. A decoy session reads
/// no suggestion and writes nothing. The days come from the day records; the sealed bathroom counts and
/// free-meal tags, Health's weight and the care score arrive through the `inputs` closure, which a later
/// piece wires to their owners.
extension FernletStore {
    /// Whether the day calendar is on: the Bodybuilding goal is chosen.
    var isBodybuildingCalendarOn: Bool { settings.selectedGoal == .bodybuilding }

    /// The calendar's preferences. Setting them saves with the settings; a decoy session keeps nothing.
    var bodybuildingCalendarSettings: BodybuildingCalendarSettings {
        get { settings.bodybuildingCalendar }
        set {
            guard !duressSessionActive, newValue != settings.bodybuildingCalendar else { return }
            settings.bodybuildingCalendar = newValue
        }
    }

    /// The Monday-first calendar the week math runs in (the device's time zone).
    var bodybuildingWeekCalendar: Calendar { BodybuildingWeeks.calendar() }

    /// The Monday key of the week holding `dayKey` (today when nil).
    func bodybuildingWeekStart(of dayKey: String? = nil) -> String? {
        BodybuildingWeeks.weekStartKey(forDayKey: dayKey ?? todayKey, calendar: bodybuildingWeekCalendar)
    }

    /// Marks or clears the week starting on the Monday key `start` as a deload week ("Hold a week" →
    /// Deload week). A key that is not a Monday is moved to its week's Monday.
    func markDeloadWeek(start: String, isDeload: Bool) {
        guard let monday = bodybuildingWeekStart(of: start) else { return }
        var prefs = bodybuildingCalendarSettings
        prefs.setDeload(weekStart: monday, isDeload)
        bodybuildingCalendarSettings = prefs
    }

    /// The Monday key of the week Fernlet suggests as a deload (``BodybuildingDeloadRule``), counted from
    /// the week holding `today` (today's key when nil); nil when it suggests nothing, when the calendar is
    /// off, or in a decoy session.
    func deloadSuggestion(today: String? = nil) -> String? {
        deloadSuggestion(today: today, records: nil)
    }

    /// ``deloadSuggestion(today:)`` over `records` when the caller already loaded them.
    private func deloadSuggestion(today: String?, records: [String: FernletDay]?) -> String? {
        guard isBodybuildingCalendarOn, !duressSessionActive, let week = bodybuildingWeekStart(of: today) else { return nil }
        let counts = BodybuildingDeloadRule.workoutsByWeek(records ?? loadDays(), calendar: bodybuildingWeekCalendar)
        return BodybuildingDeloadRule.suggestion(currentWeek: week, workoutsByWeek: counts,
                                                 settings: bodybuildingCalendarSettings, calendar: bodybuildingWeekCalendar)
    }

    /// "Make next week a deload": marks the week after the one holding `today`.
    func acceptDeloadSuggestion(today: String? = nil) {
        guard !duressSessionActive, let week = bodybuildingWeekStart(of: today) else { return }
        var prefs = bodybuildingCalendarSettings
        BodybuildingDeloadRule.accept(currentWeek: week, settings: &prefs, calendar: bodybuildingWeekCalendar)
        bodybuildingCalendarSettings = prefs
    }

    /// "Not now": hides the suggestion until the same run of hard weeks is two weeks longer.
    func declineDeloadSuggestion(today: String? = nil) {
        guard !duressSessionActive, let week = bodybuildingWeekStart(of: today) else { return }
        var prefs = bodybuildingCalendarSettings
        let run = BodybuildingDeloadRule.run(currentWeek: week, workoutsByWeek: bodybuildingWorkoutsByWeek(),
                                             deloadWeeks: Set(prefs.deloadWeekStarts), calendar: bodybuildingWeekCalendar)
        BodybuildingDeloadRule.decline(run: run, settings: &prefs)
        bodybuildingCalendarSettings = prefs
    }

    /// The calendar's days for `dayKeys`, in order, from the day records. `inputs` supplies each day's
    /// bathroom count, free-meal tag, weight and care score (nothing by default); the macro targets are
    /// today's. Days still to come are empty; the suggested week is marked while the suggestion stands.
    func calendarDays(
        for dayKeys: [String],
        inputs: (String) -> BodybuildingDayInputs = { _ in .empty }
    ) -> [BodybuildingDay] {
        let targets = nutritionTargets
        let records = loadDays()
        let context = BodybuildingDayContext(
            todayKey: todayKey, deloadWeeks: Set(bodybuildingCalendarSettings.deloadWeekStarts),
            suggestedWeek: deloadSuggestion(today: nil, records: records), calendar: bodybuildingWeekCalendar)
        return BodybuildingCalendarBuilder.days(
            for: dayKeys, records: records, inputs: inputs,
            targets: Macros(protein: targets.protein, carbs: targets.carbs, fat: targets.fat), context: context)
    }

    /// The month grid holding `date` (Monday first).
    func bodybuildingMonthLayout(containing date: Date = Date()) -> BodybuildingMonthLayout {
        BodybuildingWeeks.monthLayout(containing: date, calendar: bodybuildingWeekCalendar)
    }

    /// Logged workouts per week, from every day record.
    private func bodybuildingWorkoutsByWeek() -> [String: Int] {
        BodybuildingDeloadRule.workoutsByWeek(loadDays(), calendar: bodybuildingWeekCalendar)
    }
}
