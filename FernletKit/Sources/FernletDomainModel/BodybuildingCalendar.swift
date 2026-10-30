// BodybuildingCalendar.swift
// FernletDomainModel
//
// The pure engine behind the Bodybuilding goal's day calendar (World round 7, spec
// Docs/Handoff/World-Bodybuilding-Spec.md, approved 2026-10-29): Monday-first week and month math, one
// day's signals built from a FernletDay, and the deload suggestion rule. No store, no Health, no sealed
// data: the bathroom count, the free-meal tag, the weight and the care score are passed in, so the
// sealed and Health sources stay with their owners. Nothing here counts a streak for display.

import Foundation

/// Monday-first week and month math on `yyyy-MM-dd` day keys.
///
/// Keys are formatted from the calendar's own components (Gregorian, so the same spelling
/// `FernletDate.dayKey` writes for the calendar's time zone), which keeps tests independent of the
/// device's zone.
public nonisolated enum BodybuildingWeeks {
    /// A Gregorian calendar whose weeks start on Monday, in `timeZone`.
    public static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// The `yyyy-MM-dd` key of `date` in `calendar`.
    public static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Midnight of the day `key` names in `calendar`, or nil for a key that is not a day.
    public static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        guard BodybuildingCalendarSettings.isDayKey(key) else { return nil }
        let fields = key.split(separator: "-").compactMap { Int($0) }
        guard fields.count == 3, (1...12).contains(fields[1]), (1...31).contains(fields[2]) else { return nil }
        let parts = DateComponents(year: fields[0], month: fields[1], day: fields[2])
        guard let date = calendar.date(from: parts), dayKey(for: date, calendar: calendar) == key else { return nil }
        return date
    }

    /// The key `days` days after `key` (negative goes back), or nil for a key that is not a day.
    public static func dayKey(_ key: String, addingDays days: Int, calendar: Calendar) -> String? {
        guard let date = date(fromDayKey: key, calendar: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        return dayKey(for: moved, calendar: calendar)
    }

    /// The Monday key of the week holding `date`.
    public static func weekStartKey(for date: Date, calendar: Calendar) -> String {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let back = (weekday - calendar.firstWeekday + 7) % 7
        let monday = calendar.date(byAdding: .day, value: -back, to: day) ?? day
        return dayKey(for: monday, calendar: calendar)
    }

    /// The Monday key of the week holding the day `key`, or nil for a key that is not a day.
    public static func weekStartKey(forDayKey key: String, calendar: Calendar) -> String? {
        date(fromDayKey: key, calendar: calendar).map { weekStartKey(for: $0, calendar: calendar) }
    }

    /// The seven day keys, Monday to Sunday, of the week starting on `weekStart`; empty for a bad key.
    public static func weekDayKeys(weekStart: String, calendar: Calendar) -> [String] {
        guard date(fromDayKey: weekStart, calendar: calendar) != nil else { return [] }
        return (0..<7).compactMap { dayKey(weekStart, addingDays: $0, calendar: calendar) }
    }

    /// The month grid holding `date`: blanks before the 1st so it lands on its weekday (Monday first),
    /// the month's days, and blanks after so the last row is whole.
    public static func monthLayout(containing date: Date, calendar: Calendar) -> BodybuildingMonthLayout {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let first = calendar.date(from: parts) ?? calendar.startOfDay(for: date)
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let firstKey = dayKey(for: first, calendar: calendar)
        let keys = (0..<length).compactMap { dayKey(firstKey, addingDays: $0, calendar: calendar) }
        let trailing = (7 - (leading + keys.count) % 7) % 7
        return BodybuildingMonthLayout(firstDayKey: firstKey, leadingBlanks: leading, dayKeys: keys, trailingBlanks: trailing)
    }
}

/// One month as the grid draws it, Monday first.
public nonisolated struct BodybuildingMonthLayout: Equatable, Sendable {
    /// The key of the month's 1st.
    public let firstDayKey: String
    /// Empty cells before the 1st (0 when the 1st is a Monday, 6 when it is a Sunday).
    public let leadingBlanks: Int
    /// The month's days, in order.
    public let dayKeys: [String]
    /// Empty cells after the last day, so the last row holds seven.
    public let trailingBlanks: Int

    public init(firstDayKey: String, leadingBlanks: Int, dayKeys: [String], trailingBlanks: Int) {
        self.firstDayKey = firstDayKey
        self.leadingBlanks = leadingBlanks
        self.dayKeys = dayKeys
        self.trailingBlanks = trailingBlanks
    }

    /// The grid's rows of seven cells; nil is a blank.
    public var rows: [[String?]] {
        let cells: [String?] = Array(repeating: nil, count: leadingBlanks) + dayKeys.map { Optional($0) }
            + Array(repeating: nil, count: trailingBlanks)
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }
}

/// What a day's calendar cell needs that does not live on the day record: the sealed bathroom count and
/// free-meal tag, the weight from Health, and the day's care score. A later piece fills them from their
/// owners; the defaults show nothing.
public nonisolated struct BodybuildingDayInputs: Equatable, Sendable {
    /// Bathroom visits that day, or nil when none were counted.
    public var bathroomVisits: Int?
    /// Whether a meal that day carries the Free meal tag.
    public var freeMeal: Bool
    /// The weight read for that day, in kilograms, or nil.
    public var weightKilograms: Double?
    /// The day's care score, 0 to 100, or nil.
    public var careScore: Int?

    public init(bathroomVisits: Int? = nil, freeMeal: Bool = false, weightKilograms: Double? = nil, careScore: Int? = nil) {
        self.bathroomVisits = bathroomVisits
        self.freeMeal = freeMeal
        self.weightKilograms = weightKilograms
        self.careScore = careScore
    }

    /// Nothing known.
    public static let empty = BodybuildingDayInputs()
}

/// Where a day sits: today, the deload weeks, and the suggested week.
public nonisolated struct BodybuildingDayContext: Equatable, Sendable {
    /// Today's key.
    public var todayKey: String
    /// The marked deload weeks' Monday keys.
    public var deloadWeeks: Set<String>
    /// The suggested deload week's Monday key, while the suggestion stands.
    public var suggestedWeek: String?
    /// The calendar the week math runs in.
    public var calendar: Calendar

    public init(todayKey: String, deloadWeeks: Set<String>, suggestedWeek: String?, calendar: Calendar) {
        self.todayKey = todayKey
        self.deloadWeeks = deloadWeeks
        self.suggestedWeek = suggestedWeek
        self.calendar = calendar
    }
}
