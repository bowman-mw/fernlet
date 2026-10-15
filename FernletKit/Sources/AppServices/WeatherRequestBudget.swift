import Foundation

/// The device-local daily ceiling on WeatherKit requests: at most ``dailyLimit`` calls per local
/// calendar day, counted before each call is made.
///
/// WeatherKit bills the developer per call, and Fernlet's weather is ambience — a sky bucket, a
/// daylight flag, a gentle walk offer — so a fixed small budget costs the user nothing they would
/// notice. ``WeatherKitService`` spends it: one unit per WeatherKit call, success or failure, and
/// none for a location fix or a cache hit. Spent means "weather simply absent until tomorrow", the
/// same `nil` every other failure already resolves to.
///
/// A pure value: ``WeatherRequestBudgetStore`` persists it, so a relaunch cannot reset the count.
/// The day key follows `AICallQuota.dayKey(for:calendar:)` in `AIContext` (Gregorian, POSIX
/// locale, the device's current time zone), which AppServices cannot import; the rollover rule is
/// the same, so a stale day's tally never carries into today.
public struct WeatherRequestBudget: Equatable, Sendable {
    /// WeatherKit calls allowed per local calendar day.
    public static let dailyLimit = 10

    /// The `yyyy-MM-dd` local day ``count`` belongs to.
    public let dayKey: String
    /// WeatherKit calls made on ``dayKey``.
    public let count: Int

    /// Rehydrates a budget from its persisted parts (the store's decode path).
    public init(dayKey: String, count: Int) {
        self.dayKey = dayKey
        self.count = count
    }

    /// An unspent budget anchored to the day holding `now`.
    public init(now: Date, calendar: Calendar = WeatherRequestBudget.dayKeyCalendar) {
        self.dayKey = Self.dayKey(for: now, calendar: calendar)
        self.count = 0
    }

    /// Gregorian with a POSIX locale, so a calendar-preference change cannot mint a new key and
    /// silently reset the count; the time zone is the device's current one, read fresh each time.
    public static var dayKeyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .current
        return calendar
    }

    /// Formats `date` as the `yyyy-MM-dd` day key used to detect rollover.
    public static func dayKey(for date: Date, calendar: Calendar = WeatherRequestBudget.dayKeyCalendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The count in effect at `now`: a budget left over from an earlier day has rolled over to zero.
    public func effectiveCount(now: Date, calendar: Calendar = WeatherRequestBudget.dayKeyCalendar) -> Int {
        dayKey == Self.dayKey(for: now, calendar: calendar) ? count : 0
    }

    /// Whether one more WeatherKit call fits in the day holding `now`.
    public func allowsRequest(now: Date, calendar: Calendar = WeatherRequestBudget.dayKeyCalendar) -> Bool {
        effectiveCount(now: now, calendar: calendar) < Self.dailyLimit
    }

    /// This budget with one call recorded, rolling the day over first if `now` is a new day.
    public func recordingRequest(now: Date, calendar: Calendar = WeatherRequestBudget.dayKeyCalendar) -> WeatherRequestBudget {
        let today = Self.dayKey(for: now, calendar: calendar)
        let spent = dayKey == today ? count : 0
        return WeatherRequestBudget(dayKey: today, count: spent + 1)
    }
}

/// Persists ``WeatherRequestBudget`` in `UserDefaults` as ONE dictionary value, so the day and its
/// count land together or not at all (two keys could pair today's day with yesterday's count after a
/// kill between the writes — the lesson `UserDefaultsAICallQuotaStore` records).
///
/// Device-local and never synced: device A's weather use never spends device B's budget. It holds a
/// day and a count, no location or conditions. "Delete everything" clears it through
/// ``WeatherKitService/clearRequestHistory()`` (Docs/PrivacyWipeCoverage.md).
///
/// Not locked: its one owner, ``WeatherKitService``, is `@MainActor`, so every read-modify-write is
/// already serialized.
public struct WeatherRequestBudgetStore {
    private let defaults: UserDefaults
    private let pairDefaultsKey: String

    private static let dayKeyField = "d"
    private static let countField = "c"

    /// - Parameters:
    ///   - defaults: The suite holding the pair; `.standard` in production, a private suite in tests.
    ///   - pairDefaultsKey: The one key the pair lives under.
    public init(
        defaults: UserDefaults = .standard,
        pairDefaultsKey: String = "fernlet.weather.requestBudget"
    ) {
        self.defaults = defaults
        self.pairDefaultsKey = pairDefaultsKey
    }

    /// The persisted budget, or an unspent one anchored to `now` when nothing usable is stored.
    public func load(now: Date) -> WeatherRequestBudget {
        guard let pair = defaults.dictionary(forKey: pairDefaultsKey),
              let dayKey = pair[Self.dayKeyField] as? String,
              let count = pair[Self.countField] as? Int else {
            return WeatherRequestBudget(now: now)
        }
        return WeatherRequestBudget(dayKey: dayKey, count: count)
    }

    /// Records one WeatherKit call at `now` and returns the updated budget.
    @discardableResult
    public func recordRequest(now: Date) -> WeatherRequestBudget {
        let updated = load(now: now).recordingRequest(now: now)
        defaults.set(
            [Self.dayKeyField: updated.dayKey, Self.countField: updated.count] as [String: Any],
            forKey: pairDefaultsKey
        )
        return updated
    }

    /// Removes the stored pair (the wipe's leg; a plain removal with no failure signal).
    public func reset() {
        defaults.removeObject(forKey: pairDefaultsKey)
    }
}
