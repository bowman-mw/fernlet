import Foundation
import Testing
import AppServices

/// The daily WeatherKit budget: ten calls per local day, persisted so a relaunch cannot reset it,
/// rolled over at midnight, and held for ``WeatherKitService/failureRetryInterval`` after a failed
/// call. The WeatherKit call itself is not reachable from a test; the gate it passes through
/// (``WeatherKitService/mayAttemptFetch(budget:lastFailedAttemptAt:now:)``) and the store it spends
/// are, and these cells pin both. `@MainActor` because the gate and its intervals are members of
/// the main-actor service.
@Suite @MainActor struct WeatherRequestBudgetTests {

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    private func date(_ calendar: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h)))
    }

    /// A private defaults suite per cell, so parallel cells and the device's `.standard` never meet.
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = "WeatherRequestBudgetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: - The value

    @Test func theLimitIsTenAndTheCacheSpansAWakingDayInsideIt() {
        #expect(WeatherRequestBudget.dailyLimit == 10)
        // Someone who keeps the app open from 7:00 to 22:00 refreshes once per cache interval; ten
        // calls, each fresh for one interval, have to cover that, or the evening goes without weather.
        let wakingDay: TimeInterval = 15 * 60 * 60
        #expect(WeatherKitService.cacheInterval * Double(WeatherRequestBudget.dailyLimit) >= wakingDay)
    }

    @Test func recordingRollsOverAtTheDayBoundary() throws {
        let cal = utc
        let budget = WeatherRequestBudget(dayKey: WeatherRequestBudget.dayKey(for: try date(cal, 2026, 10, 14), calendar: cal), count: 9)
        let same = budget.recordingRequest(now: try date(cal, 2026, 10, 14, 23), calendar: cal)
        #expect(same.count == 10)
        let next = budget.recordingRequest(now: try date(cal, 2026, 10, 15, 0), calendar: cal)
        #expect(next.count == 1)
        #expect(next.dayKey == "2026-10-15")
    }

    @Test func theTenthCallIsTheLastOneADayAllows() throws {
        let cal = utc
        let today = try date(cal, 2026, 10, 14)
        let key = WeatherRequestBudget.dayKey(for: today, calendar: cal)
        #expect(WeatherRequestBudget(dayKey: key, count: 9).allowsRequest(now: today, calendar: cal))
        #expect(!WeatherRequestBudget(dayKey: key, count: 10).allowsRequest(now: today, calendar: cal))
        // Yesterday's spent budget is today's empty one.
        let tomorrow = try date(cal, 2026, 10, 15)
        #expect(WeatherRequestBudget(dayKey: key, count: 10).allowsRequest(now: tomorrow, calendar: cal))
        #expect(WeatherRequestBudget(dayKey: key, count: 10).effectiveCount(now: tomorrow, calendar: cal) == 0)
    }

    // MARK: - The store

    @Test func aSpentBudgetSurvivesARelaunchAndTheWipeClearsIt() throws {
        try withSuite { defaults in
            let noon = try date(WeatherRequestBudget.dayKeyCalendar, 2026, 10, 14)
            let store = WeatherRequestBudgetStore(defaults: defaults)
            #expect(store.load(now: noon).count == 0)
            // R2: bounded by the daily limit.
            for _ in 0..<WeatherRequestBudget.dailyLimit {
                store.recordRequest(now: noon)
            }
            // A second store on the same suite is the next launch reading the same defaults.
            let relaunched = WeatherRequestBudgetStore(defaults: defaults)
            #expect(relaunched.load(now: noon).count == WeatherRequestBudget.dailyLimit)
            #expect(!relaunched.load(now: noon).allowsRequest(now: noon))
            relaunched.reset()
            #expect(store.load(now: noon).count == 0)
            #expect(defaults.object(forKey: "fernlet.weather.requestBudget") == nil)
        }
    }

    @Test func aMalformedStoredPairReadsAsAnUnspentBudget() throws {
        try withSuite { defaults in
            let noon = try date(WeatherRequestBudget.dayKeyCalendar, 2026, 10, 14)
            defaults.set(["d": 7, "c": "ten"] as [String: Any], forKey: "fernlet.weather.requestBudget")
            let budget = WeatherRequestBudgetStore(defaults: defaults).load(now: noon)
            #expect(budget.count == 0)
            #expect(budget.dayKey == WeatherRequestBudget.dayKey(for: noon))
        }
    }

    // MARK: - The gate

    @Test func aFailedCallHoldsTheNextOneForTheRetryInterval() throws {
        let cal = WeatherRequestBudget.dayKeyCalendar
        let failedAt = try date(cal, 2026, 10, 14)
        let budget = WeatherRequestBudget(now: failedAt)
        let hold = WeatherKitService.failureRetryInterval
        #expect(!WeatherKitService.mayAttemptFetch(budget: budget, lastFailedAttemptAt: failedAt,
                                                   now: failedAt.addingTimeInterval(6)))
        #expect(!WeatherKitService.mayAttemptFetch(budget: budget, lastFailedAttemptAt: failedAt,
                                                   now: failedAt.addingTimeInterval(hold - 1)))
        #expect(WeatherKitService.mayAttemptFetch(budget: budget, lastFailedAttemptAt: failedAt,
                                                  now: failedAt.addingTimeInterval(hold)))
        #expect(WeatherKitService.mayAttemptFetch(budget: budget, lastFailedAttemptAt: nil, now: failedAt))
    }

    @Test func aSpentBudgetRefusesEvenWithNoFailureOnRecord() throws {
        let cal = WeatherRequestBudget.dayKeyCalendar
        let noon = try date(cal, 2026, 10, 14)
        let spent = WeatherRequestBudget(dayKey: WeatherRequestBudget.dayKey(for: noon), count: WeatherRequestBudget.dailyLimit)
        #expect(!WeatherKitService.mayAttemptFetch(budget: spent, lastFailedAttemptAt: nil, now: noon))
        let nextMorning = try date(cal, 2026, 10, 15, 7)
        #expect(WeatherKitService.mayAttemptFetch(budget: spent, lastFailedAttemptAt: nil, now: nextMorning))
    }
}
