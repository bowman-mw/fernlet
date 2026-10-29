import FernletDomainModel
import Foundation
import PrivateHealthStore

/// The Day calendar's loads on the store (World round 7, piece C): the visible days with their sealed
/// tallies, care scores and the weights the page read, wired into the wave-1 engine
/// (``calendarDays(for:inputs:)``). No stored property; a decoy session reads only what the decoy store
/// holds (its tallies read empty, and the page reads no weight).
extension FernletStore {
    /// One load of the calendar for the month and week holding today, with `weights` (kilograms by day
    /// key, from ``BodyWeightReader``). Next week joins the grid when it is a deload or the suggested week.
    func bodybuildingCalendarSnapshot(weights: [String: Double]) -> BodybuildingCalendarSnapshot {
        let calendar = bodybuildingWeekCalendar
        let today = BodybuildingWeeks.date(fromDayKey: todayKey, calendar: calendar) ?? Date()
        let layout = bodybuildingMonthLayout(containing: today)
        guard let thisWeek = bodybuildingWeekStart() else { return .empty }
        let weekKeys = BodybuildingWeeks.weekDayKeys(weekStart: thisWeek, calendar: calendar)
        let suggested = deloadSuggestion()
        var nextWeek: [String] = []
        if let next = BodybuildingWeeks.dayKey(thisWeek, addingDays: 7, calendar: calendar),
           suggested == next || bodybuildingCalendarSettings.isDeload(weekStart: next) {
            nextWeek = BodybuildingWeeks.weekDayKeys(weekStart: next, calendar: calendar)
        }
        let rows = BodybuildingCalendarGrid.rows(layout: layout, extraWeek: nextWeek)
        let keys = BodybuildingCalendarGrid.visibleKeys(rows: rows, weekKeys: weekKeys)
        let days = bodybuildingDays(for: keys, weights: weights)
        return BodybuildingCalendarSnapshot(layout: layout, gridRows: rows, weekKeys: weekKeys,
                                            days: Dictionary(days.map { ($0.dateKey, $0) }, uniquingKeysWith: { first, _ in first }),
                                            weights: weights, suggestedWeek: suggested, todayKey: todayKey)
    }

    /// The calendar's days for `keys` (sorted), each with its bathroom count, live free-meal tag, care
    /// score and weight.
    func bodybuildingDays(for keys: [String], weights: [String: Double]) -> [BodybuildingDay] {
        guard let first = keys.first, let last = keys.last else { return [] }
        let records = loadDays()
        let tallies = bodyTallies(from: first, through: last)
        let visits = tallies.mapValues(\.bathroomVisits)
        let tags = tallies.mapValues(\.freeMealIDs)
        var scores: [String: Int] = [:]
        for key in keys.prefix(BodybuildingCalendarBuilder.maxDays) where key <= todayKey {
            guard let record = records[key] else { continue }
            scores[key] = BodybuildingCalendarInputs.carePercent(dailyHealthScore(for: key, day: record).score)
        }
        return calendarDays(for: keys) { key in
            BodybuildingCalendarInputs.inputs(for: key, bathroomVisits: visits, freeMealTags: tags, records: records,
                                              weights: weights, careScores: scores)
        }
    }
}
