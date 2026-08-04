// FernletDate.swift
// FernletFoundation
//
// Layer-0 date helpers (day-key formatting, day-key enumeration, display
// formatting). Carved out of the app's Scoring.swift so lower layers can
// produce/consume the canonical "yyyy-MM-dd" day key without importing the app.

import Foundation

/// Layer-0 date helpers producing and parsing the canonical `"yyyy-MM-dd"` day key, plus the
/// shared display formats.
///
/// The day key is the primary key for one day of user data across Fernlet — day records, derived
/// signals, scoring, and sync payloads all join on it — so its format is pinned to an
/// `en_US_POSIX`/Gregorian formatter and must never vary with user locale (a locale-dependent key
/// would split one user's history across differently-spelled days). Carved out of the app's
/// Scoring.swift so lower layers (persistence, scoring, catalogs) can produce and consume day
/// keys without importing the app. All members are static; the enum is `nonisolated` and safe to
/// call from any executor.
public nonisolated enum FernletDate {
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Returns the canonical `"yyyy-MM-dd"` day key for `date` in the device's current time zone.
    public static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    /// Parses a canonical day key back to a `Date` (midnight of that day), or `nil` if the string
    /// is not a valid `"yyyy-MM-dd"` key.
    public static func date(fromDayKey key: String) -> Date? {
        dayKeyFormatter.date(from: key)
    }

    /// Enumerates the day keys covering `interval`, inclusive of both endpoint days.
    ///
    /// Steps one calendar day at a time from `calendar.startOfDay` of the interval's start
    /// through the start of its end day, so a partial final day still contributes its key.
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

    /// Formats a date for headline display (wide weekday, wide month, day), localized to the
    /// user's locale — unlike the day key, display strings are meant to follow locale.
    public static func niceDate(for date: Date = .now) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    /// Formats a date for compact display (abbreviated month + day), localized to the user's
    /// locale.
    public static func shortDate(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}
