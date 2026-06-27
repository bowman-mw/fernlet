// FernletDate.swift
// FernletFoundation
//
// Layer-0 date helpers (day-key formatting, day-key enumeration, display
// formatting). Carved out of the app's Scoring.swift so lower layers can
// produce/consume the canonical "yyyy-MM-dd" day key without importing the app.

import Foundation

public nonisolated enum FernletDate {
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    public static func date(fromDayKey key: String) -> Date? {
        dayKeyFormatter.date(from: key)
    }

    public static func dayKeys(in interval: DateInterval, calendar: Calendar = .current) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)
        while day <= end {
            keys.append(dayKey(for: day))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return keys
    }

    public static func niceDate(for date: Date = .now) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    public static func shortDate(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
