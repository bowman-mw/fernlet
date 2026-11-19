import Foundation

/// How often live planes may be fetched (owner 2026-11-19, call 6 and its follow-up): every 30 s while the map shows,
/// at most 400 requests on one day (adsb.lol allows 500 per IP without a key), a rest after adsb.lol's 429, and a
/// rest that doubles after each failed fetch in a row (release review 2026-11-18, F9: an outage must not mean a
/// failing request every 30 s until the cap). The back-off only ever spaces fetches further apart: the 30 s pace and
/// the daily cap stay the most that can be sent. No count of people and nothing about anyone else: the cap is this
/// iPhone's own tally. Pure.
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
    /// The longest rest after repeated failed fetches (no network, a timeout, a 403 or 5xx, a body that isn't the
    /// feed), in seconds. The rest starts at ``interval`` and doubles: 30 s, 1, 2, 4, 8 min, then 15 min each time.
    static let longestFailureRest: TimeInterval = 900
    /// The most answers in a row counted; past this the rests are already at their longest.
    static let maxStrikes = 8

    /// The day the tally counts (`yyyy-MM-dd` in the phone's calendar).
    var day: String
    /// Fetches made on ``day``.
    var used: Int
    /// No fetch before this moment (after a 429 or a failed fetch); nil when not resting.
    var restUntil: Date? = nil
    /// The answers in a row that brought no planes (429s and failed fetches), which double the rest.
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

    /// The tally after adsb.lol answered at `now`. Planes clear the strikes. A 429 rests for its `Retry-After` (at
    /// least 30 s) or for a rest that doubles with each strike, from ``firstRest`` to ``longestRest``. A failed fetch
    /// rests for ``interval`` doubled with each strike, up to ``longestFailureRest``. A fetch the switch refused
    /// changes nothing.
    func answered(_ outcome: LiveAircraftFetchOutcome, at now: Date) -> LiveAircraftBudget {
        var next = self
        let struck = min(max(strikes, 0), Self.maxStrikes - 1) + 1   // clamped first: a stored tally can be any Int
        switch outcome {
        case .planes:
            next.strikes = 0
        case .notPermitted:
            break
        case .rateLimited(let retryAfter):
            next.strikes = struck
            let told = retryAfter.flatMap { $0.isFinite ? min(max($0, Self.interval), Self.longestRest * 6) : nil }
            next.restUntil = now.addingTimeInterval(told ?? Self.rest(from: Self.firstRest, strikes: struck, longest: Self.longestRest))
        case .failed:
            next.strikes = struck
            next.restUntil = now.addingTimeInterval(Self.rest(from: Self.interval, strikes: struck, longest: Self.longestFailureRest))
        }
        return next
    }

    /// A rest of `first` seconds doubled for each strike after the first, `longest` at most.
    static func rest(from first: TimeInterval, strikes: Int, longest: TimeInterval) -> TimeInterval {
        let doublings = min(max(strikes - 1, 0), maxStrikes)
        return min(first * pow(2, Double(doublings)), longest)
    }
}
