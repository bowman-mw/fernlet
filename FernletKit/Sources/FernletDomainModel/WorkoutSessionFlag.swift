// WorkoutSessionFlag.swift
// FernletDomainModel
//
// The sleep and readiness flag on one logged session (the owner's G10 pick, 2026-10-20). A flag never
// pushes the bar and never cuts it: it forgives. A flagged session that falls short of a lift's trend
// counts at half weight and never toward a stall (``WorkoutTrend``), and a flagged miss holds the load
// instead of cutting it (``WorkoutLoadEngine``). A flagged session that meets the trend counts fully.
//
// Sleep: a night of 6 h or less, or 90 min or more below the person's own 14-day median. Two such
// nights in a row make the flag firmer. The old "under 7 h on average" check is retired.
// Readiness: a session logged on a light day.
//
// Built by the app from the day history (WorkoutLoadContextBuilder); never persisted.

import Foundation

/// How short the night before a session was, by the G10 rule.
public nonisolated enum SleepFlag: Equatable, Sendable {
    /// One short night: 6 h or less, or 90 min or more under the person's own 14-day median.
    case shortNight
    /// Two short nights in a row — the firmer flag.
    case shortNights
}

/// Why a logged session is flagged: the night before it, a light readiness day, or both.
public nonisolated struct WorkoutSessionFlag: Equatable, Sendable {
    public var sleep: SleepFlag?
    /// The session was logged on a light day (the readiness suggestion, or the person's pick).
    public var lightDay: Bool

    public init(sleep: SleepFlag? = nil, lightDay: Bool = false) {
        self.sleep = sleep
        self.lightDay = lightDay
    }

    /// A flag that says something; nil when neither sleep nor readiness flags the session.
    public static func make(sleep: SleepFlag?, lightDay: Bool) -> WorkoutSessionFlag? {
        guard sleep != nil || lightDay else { return nil }
        return WorkoutSessionFlag(sleep: sleep, lightDay: lightDay)
    }

    /// Two short nights in a row.
    public var isFirm: Bool { sleep == .shortNights }

    /// How far under a lift's trend line (log units, about a fraction) a flagged session may land
    /// and still meet the trend. The literature's cost of one short night — about 3 % on lower-body
    /// lifts, 1.5 % on upper-body ones (Craven 2022) — applies in full on the firmer flag; one short
    /// night or a light day gets half, because one night's reading is the least certain.
    public func trim(lowerBody: Bool) -> Double {
        let full = lowerBody ? WorkoutSessionFlags.lowerBodyTrim : WorkoutSessionFlags.upperBodyTrim
        return isFirm ? full : full / 2
    }
}

/// The G10 sleep rule over nightly hours.
public nonisolated enum WorkoutSessionFlags {

    // MARK: Approved numbers (owner, G10, 2026-10-20)

    /// A night this short or shorter is short, whatever the person's usual.
    public static let shortNightHours = 6.0
    /// A night this far under the person's own median is short too…
    public static let belowMedianHours = 1.5
    /// …the median of the nights in this window before it…
    public static let medianWindowDays = 14
    /// …once at least this many of those nights are logged.
    public static let medianMinimumNights = 5
    /// The trend trims a flagged session may fall under the line and still count fully.
    public static let lowerBodyTrim = 0.03
    public static let upperBodyTrim = 0.015

    /// Whether a night of `hours` is short against the person's `median` (nil while too few nights
    /// are logged to have one).
    public static func isShort(_ hours: Double, median: Double?) -> Bool {
        guard hours.isFinite, hours > 0 else { return false }
        if hours <= shortNightHours { return true }
        guard let median, median.isFinite else { return false }
        return hours <= median - belowMedianHours
    }

    /// The median of `nights`, or nil with fewer than ``medianMinimumNights``.
    public static func median(of nights: [Double]) -> Double? {
        let valid = nights.filter { $0.isFinite && $0 > 0 }.sorted()
        guard valid.count >= medianMinimumNights else { return nil }
        let middle = valid.count / 2
        guard valid.count.isMultiple(of: 2) else { return valid[middle] }
        return (valid[middle - 1] + valid[middle]) / 2
    }

    /// The sleep flag for a session, from the night before it and the nights before that (newest
    /// last, at most ``medianWindowDays`` of them; a missing night is absent, never short).
    /// `previousNight` is the night before last, when logged.
    public static func sleepFlag(lastNight: Double?, previousNight: Double?, earlierNights: [Double]) -> SleepFlag? {
        guard let lastNight else { return nil }
        let window = Array(earlierNights.suffix(medianWindowDays))
        let usual = median(of: window)
        guard isShort(lastNight, median: usual) else { return nil }
        guard let previousNight, isShort(previousNight, median: usual) else { return .shortNight }
        return .shortNights
    }
}
