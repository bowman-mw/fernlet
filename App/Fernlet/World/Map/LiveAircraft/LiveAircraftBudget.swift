import Foundation

/// How often live planes may be fetched (owner 2026-11-19, call 6 and its follow-up): every 30 s while the map shows,
/// at most 400 requests on one day (adsb.lol allows 500 per IP without a key), and a rest after adsb.lol's 429. No
/// count of people and nothing about anyone else: the cap is this iPhone's own tally. Pure.
///
/// The day's tally is the only thing kept, as a day and a number in ``WorldMapPreferences`` (cleared by the delete
/// funnel); it says nothing about where the map looked.
nonisolated struct LiveAircraftBudget: Equatable, Sendable {
    /// Seconds between fetches.
    static let interval: TimeInterval = 30
    /// The most fetches on one day.
    static let dailyCap = 400
    /// The first rest after a 429 with no `Retry-After`, in seconds.
    static let firstRest: TimeInterval = 300
    /// The longest rest after repeated 429s, in seconds.
    static let longestRest: TimeInterval = 3_600

    /// The day the tally counts (`yyyy-MM-dd` in the phone's calendar).
    var day: String
    /// Fetches made on ``day``.
    var used: Int
    /// No fetch before this moment (after a 429); nil when not resting.
    var restUntil: Date? = nil
    /// The 429s in a row, which double the rest.
    var strikes = 0

    /// The day stamp for `date` in `calendar`.
    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The tally as it stands at `now`: a new day starts again from nothing.
    func rolled(to now: Date, calendar: Calendar = .current) -> LiveAircraftBudget {
        let today = Self.dayStamp(now, calendar: calendar)
        guard today != day else { return self }
        return LiveAircraftBudget(day: today, used: 0, restUntil: restUntil, strikes: strikes)
    }

    /// Whether a fetch may go now.
    func allows(at now: Date, calendar: Calendar = .current) -> Bool {
        let current = rolled(to: now, calendar: calendar)
        if let restUntil = current.restUntil, now < restUntil { return false }
        return current.used < Self.dailyCap
    }

    /// Whether today's cap is spent (Settings shows a quiet line).
    func isSpent(at now: Date, calendar: Calendar = .current) -> Bool {
        rolled(to: now, calendar: calendar).used >= Self.dailyCap
    }

    /// The tally after a fetch is sent at `now`.
    func spending(at now: Date, calendar: Calendar = .current) -> LiveAircraftBudget {
        var next = rolled(to: now, calendar: calendar)
        next.used += 1
        return next
    }

    /// The tally after adsb.lol answered at `now`: a 429 rests for its `Retry-After` (at least 30 s) or for a rest
    /// that doubles with each 429 in a row; any other answer clears the strikes.
    func answered(_ outcome: LiveAircraftFetchOutcome, at now: Date) -> LiveAircraftBudget {
        var next = self
        guard case .rateLimited(let retryAfter) = outcome else {
            if case .planes = outcome { next.strikes = 0 }
            return next
        }
        next.strikes = min(strikes + 1, 8)
        let doubling = min(Self.firstRest * pow(2, Double(next.strikes - 1)), Self.longestRest)
        let rest = retryAfter.map { min(max($0, Self.interval), Self.longestRest * 6) } ?? doubling
        next.restUntil = now.addingTimeInterval(rest)
        return next
    }
}
