// AmbientRemindersTests.swift
// FernletTests
//
// Home's gentle reminders (G8, 2026-11-15): the forgotten good things (recipe, calm tool, the meal
// chips and the workout nudge) and the seasonal rhythms (soup, walks, workouts, water). The pure
// finders and the caps are tested with the clock injected; the device-local record against a
// private UserDefaults suite; and CAP-2 as a source scan, since Home is not behind the lock.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletSocial
@testable import Fernlet

/// Fixed UTC calendar and dates, so a season boundary never moves with the machine's time zone.
private enum AmbientFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    /// `count` events, one a day from `start`.
    static func daily(from start: Date, count: Int, amount: Double = 1) -> [AmbientDatedAmount] {
        (0..<count).map { AmbientDatedAmount(date: start.addingTimeInterval(Double($0) * 86_400), amount: amount) }
    }

    /// A Northern autumn day well past the one-year gate.
    static let autumnNow = date(2026, 11, 15)
}

// MARK: - Seasons

struct AmbientSeasonTests {
    @Test func meteorologicalSeasonsTurnWithTheHemisphere() {
        #expect(AmbientSeason.season(forMonth: 3, southern: false) == .spring)
        #expect(AmbientSeason.season(forMonth: 7, southern: false) == .summer)
        #expect(AmbientSeason.season(forMonth: 11, southern: false) == .autumn)
        #expect(AmbientSeason.season(forMonth: 1, southern: false) == .winter)
        #expect(AmbientSeason.season(forMonth: 12, southern: false) == .winter)
        #expect(AmbientSeason.season(forMonth: 11, southern: true) == .spring)
        #expect(AmbientSeason.season(forMonth: 1, southern: true) == .summer)
        #expect(AmbientSeason.season(forMonth: 6, southern: true) == .winter)
    }

    @Test func theHemisphereComesFromTheRegion() {
        #expect(AmbientSeason.isSouthern(region: "AU"))
        #expect(AmbientSeason.isSouthern(region: "nz"))
        #expect(!AmbientSeason.isSouthern(region: "US"))
        #expect(!AmbientSeason.isSouthern(region: "ES"))
        #expect(!AmbientSeason.isSouthern(region: nil), "no region reads as Northern")
    }

    @Test func theWindowIsLastYearsSeasonAndTheMonthsAfterIt() throws {
        let now = AmbientFixture.autumnNow
        let window = try #require(AmbientSeasonWindow.around(now, now: now, southern: false, calendar: AmbientFixture.calendar))
        #expect(window.season == .autumn)
        #expect(window.lastYear.start == AmbientFixture.calendar.date(from: DateComponents(year: 2025, month: 9, day: 1)))
        #expect(window.lastYear.end == AmbientFixture.calendar.date(from: DateComponents(year: 2025, month: 12, day: 1)))
        #expect(window.restOfYear.end <= now.addingTimeInterval(-30 * 86_400), "the comparison stops a month before today")
        #expect(window.restOfYear.end <= AmbientFixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)) ?? now,
                "and before this season starts")
    }
}

// MARK: - Forgotten good things

struct AmbientForgottenTests {
    private let now = AmbientFixture.autumnNow

    private func use(_ name: String, daysAgo: [Int]) -> AmbientRecipeUse {
        AmbientRecipeUse(id: UUID(), name: name, dates: daysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) })
    }

    @Test func aRecipeMadeTwiceAndNotForSixtyDaysComesBack() {
        let soup = use("Lemon orzo soup", daysAgo: [120, 61])
        let reminder = AmbientReminderFinder.forgottenRecipe([soup], now: now)
        #expect(reminder == AmbientReminder(kind: .forgottenRecipe, subject: .recipe(id: soup.id, name: "Lemon orzo soup")))
    }

    @Test func aRecipeMadeOnceOrLatelyStaysQuiet() {
        #expect(AmbientReminderFinder.forgottenRecipe([use("Once", daysAgo: [200])], now: now) == nil)
        #expect(AmbientReminderFinder.forgottenRecipe([use("Lately", daysAgo: [200, 59])], now: now) == nil)
    }

    @Test func theRecipeMadeMostIsTheOneOffered() {
        let few = use("Few", daysAgo: [100, 90])
        let many = use("Many", daysAgo: [300, 200, 100])
        #expect(AmbientReminderFinder.forgottenRecipe([few, many], now: now)?.subject == .recipe(id: many.id, name: "Many"))
    }

    @Test func aCalmToolFinishedThreeTimesAndNotForAMonthComesBack() {
        let old = [90, 60, 31].map { now.addingTimeInterval(-Double($0) * 86_400) }
        #expect(AmbientReminderFinder.forgottenCalm([.boxBreathing: old], now: now)?.subject == .calm(.boxBreathing))
        #expect(AmbientReminderFinder.forgottenCalm([.grounding: Array(old.prefix(2))], now: now) == nil, "twice is not yet a habit")
        let recent = old + [now.addingTimeInterval(-3 * 86_400)]
        #expect(AmbientReminderFinder.forgottenCalm([.relaxBreathing: recent], now: now) == nil, "used lately")
    }

    @MainActor @Test func breathingPresetsMapToTheirTools() {
        #expect(AmbientCalmTool(breathingPresetID: BreathingPreset.box.id) == .boxBreathing)
        #expect(AmbientCalmTool(breathingPresetID: BreathingPreset.relax.id) == .relaxBreathing)
        #expect(AmbientCalmTool.boxBreathing.breathingPresetID == BreathingPreset.box.id)
        #expect(AmbientCalmTool.relaxBreathing.breathingPresetID == BreathingPreset.relax.id)
        #expect(AmbientCalmTool(breathingPresetID: "unknown") == nil)
        #expect(AmbientCalmTool.grounding.breathingPresetID == nil)
    }
}

// MARK: - Seasonal rhythm

struct AmbientSeasonalTests {
    private let now = AmbientFixture.autumnNow
    private let calendar = AmbientFixture.calendar

    /// Soup on six days of last October, once in March: autumn clearly stood out.
    private var soupyLastAutumn: AmbientHistory {
        var history = AmbientHistory()
        history.firstDataDate = AmbientFixture.date(2025, 8, 1)
        history.soupDays = AmbientFixture.daily(from: AmbientFixture.date(2025, 10, 1), count: 6)
            + [AmbientDatedAmount(date: AmbientFixture.date(2026, 3, 10), amount: 1)]
        return history
    }

    private func seasonal(_ history: AmbientHistory, at date: Date? = nil) -> [AmbientReminder] {
        AmbientReminderFinder.seasonal(history, now: date ?? now, southern: false, calendar: calendar)
    }

    @Test func lastAutumnsSoupComesBackAsTheSeasonTurns() {
        #expect(seasonal(soupyLastAutumn) == [AmbientReminder(kind: .seasonalSoup, subject: .season(.autumn))])
    }

    @Test func nothingSeasonalBeforeAboutAYear() {
        var young = soupyLastAutumn
        young.firstDataDate = now.addingTimeInterval(-300 * 86_400)
        #expect(seasonal(young).isEmpty)
        young.firstDataDate = nil
        #expect(seasonal(young).isEmpty)
    }

    @Test func aSeasonThatOnlyMatchedTheRestOfTheYearSaysNothing() {
        var even = soupyLastAutumn
        // Twenty more soups spread over the following months: autumn no longer stood out.
        let start = AmbientFixture.date(2025, 12, 5)
        even.soupDays += (0..<20).map { AmbientDatedAmount(date: start.addingTimeInterval(Double($0) * 13 * 86_400), amount: 1) }
        #expect(seasonal(even).isEmpty)
    }

    @Test func belowTheMinimumSaysNothing() {
        var few = soupyLastAutumn
        few.soupDays = AmbientFixture.daily(from: AmbientFixture.date(2025, 10, 1), count: 3)
        #expect(seasonal(few).isEmpty)
    }

    @Test func itNeverComparesWithNow() {
        // Whatever happens this season — lots of soup, or none — last year's answer is the same.
        var busyNow = soupyLastAutumn
        busyNow.soupDays += AmbientFixture.daily(from: AmbientFixture.date(2026, 9, 1), count: 70)
        #expect(seasonal(busyNow) == seasonal(soupyLastAutumn))
        var quietLastYearBusyNow = AmbientHistory()
        quietLastYearBusyNow.firstDataDate = AmbientFixture.date(2025, 8, 1)
        quietLastYearBusyNow.soupDays = AmbientFixture.daily(from: AmbientFixture.date(2026, 9, 1), count: 70)
            + AmbientFixture.daily(from: now.addingTimeInterval(-29 * 86_400), count: 29)
        #expect(seasonal(quietLastYearBusyNow).isEmpty, "this season's data is never read")
    }

    @Test func walksAndWorkoutsFollowTheSameRule() {
        var history = AmbientHistory()
        history.firstDataDate = AmbientFixture.date(2025, 8, 1)
        history.walks = AmbientFixture.daily(from: AmbientFixture.date(2025, 9, 10), count: 8)
        history.workouts = AmbientFixture.daily(from: AmbientFixture.date(2025, 9, 10), count: 12)
        #expect(seasonal(history).map(\.kind) == [.seasonalWalks, .seasonalWorkouts])
    }

    @Test func warmDaysAheadOnlyAsSummerComes() {
        var history = AmbientHistory()
        history.firstDataDate = AmbientFixture.date(2025, 3, 1)
        history.water = AmbientFixture.daily(from: AmbientFixture.date(2025, 6, 1), count: 90, amount: 4)
            + AmbientFixture.daily(from: AmbientFixture.date(2025, 9, 1), count: 200, amount: 1)
        let lateSpring = AmbientFixture.date(2026, 5, 20)
        #expect(seasonal(history, at: lateSpring) == [AmbientReminder(kind: .seasonalWater, subject: .season(.summer))])
        #expect(seasonal(history, at: AmbientFixture.date(2026, 8, 10)).isEmpty, "late summer is not 'ahead'")
        #expect(seasonal(history, at: AmbientFixture.date(2026, 2, 10)).isEmpty)
    }

    @Test func theSeasonalCopyNeverCountsOrCompares() {
        let reminders = AmbientSeason.allCases.flatMap { season in
            [AmbientReminderKind.seasonalSoup, .seasonalWalks, .seasonalWorkouts, .seasonalWater].map {
                AmbientReminder(kind: $0, subject: .season(season))
            }
        }
        for reminder in reminders {
            let text = (AmbientReminderCopy.title(for: reminder) ?? "") + " " + (AmbientReminderCopy.body(for: reminder) ?? "")
            #expect(!text.isEmpty)
            #expect(text.rangeOfCharacter(from: .decimalDigits) == nil, "\(reminder.kind) shows a number")
            for word in ["more than", "less than", "fewer", "than this", "streak", "goal", "best", "missed"] {
                #expect(!text.lowercased().contains(word), "\(reminder.kind) says \(word)")
            }
        }
    }
}

// MARK: - Caps

struct AmbientReminderScheduleTests {
    private let day1 = AmbientFixture.date(2026, 11, 15)
    private func later(_ days: Double) -> Date { day1.addingTimeInterval(days * 86_400) }
    private func key(_ date: Date) -> String {
        let parts = AmbientFixture.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @Test func atMostTwoADay() {
        var schedule = AmbientReminderSchedule()
        let shown = schedule.choose(from: [.forgottenRecipe, .forgottenCalm, .forgottenMeal], dayKey: key(day1), now: day1)
        #expect(shown == [.forgottenRecipe, .forgottenCalm])
        #expect(schedule.choose(from: [.forgottenRecipe, .forgottenCalm, .forgottenMeal], dayKey: key(day1), now: day1) == shown,
                "the same day keeps its two")
    }

    @Test func eachKindAtMostOnceAMonth() {
        var schedule = AmbientReminderSchedule()
        #expect(schedule.choose(from: [.forgottenRecipe], dayKey: key(day1), now: day1) == [.forgottenRecipe])
        #expect(schedule.choose(from: [.forgottenRecipe], dayKey: key(later(1)), now: later(1)).isEmpty, "the next day it rests")
        #expect(schedule.choose(from: [.forgottenRecipe], dayKey: key(later(29)), now: later(29)).isEmpty)
        #expect(schedule.choose(from: [.forgottenRecipe], dayKey: key(later(30)), now: later(30)) == [.forgottenRecipe])
    }

    @Test func oneSeasonalCardAMonthInAll() {
        var schedule = AmbientReminderSchedule()
        #expect(schedule.choose(from: [.seasonalSoup, .seasonalWalks], dayKey: key(day1), now: day1) == [.seasonalSoup])
        #expect(schedule.choose(from: [.seasonalWalks], dayKey: key(later(10)), now: later(10)).isEmpty)
        #expect(schedule.choose(from: [.seasonalWalks], dayKey: key(later(31)), now: later(31)) == [.seasonalWalks])
    }

    @Test func notNowHidesForAMonthAndStillCountsToday() {
        var schedule = AmbientReminderSchedule()
        _ = schedule.choose(from: [.forgottenRecipe, .forgottenCalm], dayKey: key(day1), now: day1)
        schedule.hide(.forgottenRecipe, now: day1)
        #expect(schedule.choose(from: [.forgottenRecipe, .forgottenCalm, .forgottenMeal], dayKey: key(day1), now: day1) == [.forgottenCalm],
                "a dismissed card still counts toward today's two")
        #expect(schedule.isHidden(.forgottenRecipe, now: later(29)))
        #expect(!schedule.isHidden(.forgottenRecipe, now: later(31)))
    }

    @Test func theExistingCardsCountUnderTheSameCaps() {
        var schedule = AmbientReminderSchedule()
        #expect(schedule.choose(from: [.forgottenMeal, .forgottenWorkout, .seasonalSoup], dayKey: key(day1), now: day1)
                == [.forgottenMeal, .forgottenWorkout])
        #expect(schedule.choose(from: [.forgottenMeal, .forgottenWorkout, .seasonalSoup], dayKey: key(later(1)), now: later(1))
                == [.seasonalSoup])
    }

    @Test func candidatesComeInPriorityOrder() {
        let history = AmbientHistory(recipeUses: [AmbientRecipeUse(id: UUID(), name: "Stew", dates: [day1.addingTimeInterval(-90 * 86_400), day1.addingTimeInterval(-80 * 86_400)])])
        let found = AmbientReminderFinder.candidates(history: history, calmFinishes: [:], hasForgottenMeals: true,
                                                     hasForgottenWorkout: true, now: day1, southern: false,
                                                     calendar: AmbientFixture.calendar)
        #expect(found.map(\.kind) == [.forgottenRecipe, .forgottenMeal, .forgottenWorkout])
    }

    @Test func aScheduleFromALaterBuildStillDecodes() throws {
        let json = #"{"dayKey":"2026-11-15","shownToday":["somethingNew"],"lastShown":{},"hiddenUntil":{}}"#
        var schedule = try JSONDecoder().decode(AmbientReminderSchedule.self, from: Data(json.utf8))
        #expect(schedule.choose(from: [.forgottenRecipe], dayKey: "2026-11-15", now: day1) == [.forgottenRecipe])
    }
}

// MARK: - Gathering the history

struct AmbientHistoryGatherTests {
    private let now = AmbientFixture.autumnNow

    private func meal(_ name: String, fromRecipe: Bool = false) -> Meal {
        let macros = Macros(protein: 10, carbs: 20, fat: 5)
        var meal = Meal(name: name, mealType: .dinner, macros: macros, macroSnapshot: macros, calorieSnapshot: 165,
                        micronutrientSnapshot: Micronutrients(), quality: .good, confidence: "high", note: "", source: "manual")
        if fromRecipe { meal.mealSource = .recipe }
        return meal
    }

    private func dayKey(_ daysAgo: Int) -> String {
        FernletDate.dayKey(for: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    /// Stored, not computed: one recipe id across both gathers.
    private let recipe = RecipeDefinition(name: "Lemon Orzo Soup", servings: 2, ingredients: [], notes: "", source: "manual",
                                          createdAt: AmbientFixture.autumnNow, updatedAt: AmbientFixture.autumnNow)

    private func days(journals: [JournalEntry] = []) -> [String: FernletDay] {
        var walk = Workout(name: "Walk", type: .cardio, exercises: "", rpe: nil, notes: "", duration: 30, intensity: .light)
        walk.activityType = .walking
        let lift = Workout(name: "Lift", type: .upper, exercises: "", rpe: nil, notes: "", duration: 40, intensity: .moderate)
        return [
            dayKey(400): FernletDay(date: dayKey(400), meals: [meal("lemon orzo soup", fromRecipe: true)], journals: journals),
            dayKey(100): FernletDay(date: dayKey(100), meals: [meal("Lemon Orzo Soup", fromRecipe: true), meal("Toast")],
                                    workouts: [walk, lift], journals: journals, bottleCount: 3),
            dayKey(5): FernletDay(date: dayKey(5), meals: [meal("Caldo de pollo")], journals: journals),
        ]
    }

    @Test func recipesSoupsWalksAndWaterAreGathered() {
        let history = AmbientHistory.gather(days: days(), recipes: [recipe], now: now)
        #expect(history.recipeUses.count == 1)
        #expect(history.recipeUses.first?.dates.count == 2, "matched by name, case-blind")
        #expect(history.soupDays.count == 3, "the recipe soup twice and a Spanish caldo")
        #expect(history.walks.count == 1)
        #expect(history.workouts.count == 2)
        #expect(history.water.map(\.amount) == [3])
        #expect(history.firstDataDate.map { FernletDate.dayKey(for: $0) } == dayKey(400))
    }

    @Test func journalsNeverChangeTheHistory() {
        let journals = [JournalEntry(text: "a quiet soup day", tag: .good)]
        #expect(AmbientHistory.gather(days: days(journals: journals), recipes: [recipe], now: now)
                == AmbientHistory.gather(days: days(), recipes: [recipe], now: now))
        let onlyJournal = [dayKey(600): FernletDay(date: dayKey(600), journals: journals)]
        #expect(AmbientHistory.gather(days: onlyJournal, recipes: [], now: now).firstDataDate == nil,
                "a journal-only day does not start the one-year clock")
    }

    @Test func soupWordsMatchWholeWordsAcrossLanguages() {
        #expect(AmbientSoupWords.isSoup("Chicken noodle soup"))
        #expect(AmbientSoupWords.isSoup("Consomé de res"))
        #expect(AmbientSoupWords.isSoup("Beef STEW"))
        #expect(!AmbientSoupWords.isSoup("Soupçon salad"))
        #expect(!AmbientSoupWords.isSoup("Toast"))
    }
}

// MARK: - The device-local record

struct AmbientReminderMemoryTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AmbientReminderMemoryTests.\(UUID().uuidString)") ?? .standard
    }

    @Test func finishesKeepOnlyTheNewestTwenty() {
        let defaults = makeDefaults()
        for offset in 0..<25 {
            AmbientReminderMemory.recordCalmFinish(.grounding, at: Date(timeIntervalSince1970: Double(offset) * 1_000), in: defaults)
        }
        AmbientReminderMemory.recordCalmFinish(.boxBreathing, at: Date(timeIntervalSince1970: 5), in: defaults)
        let finishes = AmbientReminderMemory.calmFinishes(in: defaults)
        #expect(finishes[.grounding]?.count == AmbientReminderMemory.finishCap)
        #expect(finishes[.grounding]?.first == Date(timeIntervalSince1970: 5_000), "the oldest went first")
        #expect(finishes[.boxBreathing]?.count == 1)
    }

    @Test func theScheduleRoundTrips() {
        let defaults = makeDefaults()
        var schedule = AmbientReminderSchedule()
        _ = schedule.choose(from: [.forgottenRecipe], dayKey: "2026-11-15", now: Date(timeIntervalSince1970: 1_800_000_000))
        AmbientReminderMemory.save(schedule, in: defaults)
        #expect(AmbientReminderMemory.schedule(in: defaults) == schedule)
    }

    @Test func deleteEverythingClearsBothKeys() {
        let defaults = makeDefaults()
        AmbientReminderMemory.recordCalmFinish(.relaxBreathing, in: defaults)
        var schedule = AmbientReminderSchedule()
        schedule.hide(.seasonalSoup, now: Date())
        AmbientReminderMemory.save(schedule, in: defaults)
        AmbientReminderMemory.clearAll(in: defaults)
        #expect(defaults.object(forKey: AmbientReminderMemory.calmFinishesKey) == nil)
        #expect(defaults.object(forKey: AmbientReminderMemory.scheduleKey) == nil)
        #expect(AmbientReminderMemory.schedule(in: defaults) == AmbientReminderSchedule())
    }

    @Test func theWipeFunnelCallsTheClear() throws {
        let store = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        #expect(store.contains("AmbientReminderMemory.clearAll()"), "Delete everything must clear the gentle reminders' record")
    }

    @Test func theSwitchDefaultsOnAndOlderRecordsDecodeOn() throws {
        #expect(FernletSettings().gentleRemindersEnabled)
        var off = FernletSettings()
        off.gentleRemindersEnabled = false
        let encoded = try JSONEncoder().encode(off)
        #expect(try JSONDecoder().decode(FernletSettings.self, from: encoded).gentleRemindersEnabled == false)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "gentleRemindersEnabled")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(FernletSettings.self, from: older).gentleRemindersEnabled)
    }
}

// MARK: - Friend nudges

struct AmbientFriendNudgeTests {
    private let day1 = AmbientFixture.date(2026, 11, 15)
    private func later(_ days: Double) -> Date { day1.addingTimeInterval(days * 86_400) }
    private func key(_ date: Date) -> String {
        let parts = AmbientFixture.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func friend(_ fingerprint: String, low: Bool = false, metDaysAgo: Double = 20, ready: Bool = true,
                        at now: Date? = nil) -> AmbientFriend {
        AmbientFriend(fingerprint: fingerprint, firstName: "Name\(fingerprint)", lastVibeWasLow: low,
                      lastMetAt: (now ?? day1).addingTimeInterval(-metDaysAgo * 86_400), canReceiveHeart: ready)
    }

    private func nudges(_ friends: [AmbientFriend], on date: Date) -> [AmbientFriendNudge] {
        AmbientFriendNudgeFinder.candidates(friends: friends, dayKey: key(date), now: date)
    }

    @Test func aLowVibeFriendGetsADraftThatHoldsAllDay() {
        let first = nudges([friend("aa", low: true)], on: day1)
        #expect(first.map(\.kind) == [.lowVibe])
        #expect(nudges([friend("aa", low: true)], on: day1) == first, "the same friend and day keep their words")
        let draft = AmbientFriendNudgeFinder.lowVibeDraft(fingerprint: "aa", dayKey: key(day1))
        #expect(first.first?.draft == draft)
        #expect(AmbientFriendNudgeFinder.lowVibeDraft(fingerprint: "aa", dayKey: key(day1)) == draft)
    }

    @Test func theLowVibeDraftsRotateThroughABAndC() {
        let drafts = Set((0..<60).map { AmbientFriendNudgeFinder.lowVibeDraft(fingerprint: "friend\($0)", dayKey: "2026-11-15") })
        #expect(drafts == [.a, .b, .c], "all three drafts come round, and never D")
    }

    @Test func onlyFriendsWhoCanReceiveAHeart() {
        #expect(nudges([friend("aa", low: true, ready: false), friend("bb", metDaysAgo: 2, ready: false)], on: day1).isEmpty)
    }

    @Test func metThisWeekIsOnlyForAMeetingInTheLastSevenDays() {
        let found = nudges([friend("aa", metDaysAgo: 3), friend("bb", metDaysAgo: 8), friend("cc", low: true, metDaysAgo: 2)], on: day1)
        #expect(found.map(\.kind) == [.lowVibe, .metThisWeek], "low vibe first, one card per friend")
        #expect(found.last?.fingerprint == "aa")
        #expect(found.last?.draft == .d)
        #expect(!found.contains { $0.fingerprint == "bb" }, "eight days ago is not this week")
    }

    @Test func metThisWeekShowsAtMostOnceAWeek() {
        var schedule = AmbientReminderSchedule()
        #expect(schedule.chooseFriend(from: nudges([friend("aa", metDaysAgo: 1)], on: day1), dayKey: key(day1), now: day1)?.fingerprint == "aa")
        let soon = later(3)
        #expect(schedule.chooseFriend(from: nudges([friend("bb", metDaysAgo: 1, at: soon)], on: soon), dayKey: key(soon), now: soon) == nil,
                "a different friend still waits for the week")
        let week = later(7)
        #expect(schedule.chooseFriend(from: nudges([friend("bb", metDaysAgo: 1, at: week)], on: week), dayKey: key(week), now: week)?.fingerprint == "bb")
    }

    @Test func aLowVibeCardRestsAMonthPerFriend() {
        var schedule = AmbientReminderSchedule()
        let both = [friend("aa", low: true, metDaysAgo: 2), friend("bb", low: true, metDaysAgo: 5)]
        #expect(schedule.chooseFriend(from: nudges(both, on: day1), dayKey: key(day1), now: day1)?.fingerprint == "aa")
        #expect(schedule.chooseFriend(from: nudges(both, on: later(1)), dayKey: key(later(1)), now: later(1))?.fingerprint == "bb",
                "the next day it is the other friend's turn")
        #expect(schedule.chooseFriend(from: nudges(both, on: later(2)), dayKey: key(later(2)), now: later(2)) == nil)
        #expect(schedule.chooseFriend(from: nudges(both, on: later(30)), dayKey: key(later(30)), now: later(30))?.fingerprint == "aa")
    }

    @Test func notNowHidesThatFriendForAMonth() {
        var schedule = AmbientReminderSchedule()
        let both = [friend("aa", low: true, metDaysAgo: 2), friend("bb", metDaysAgo: 3)]
        #expect(schedule.chooseFriend(from: nudges(both, on: day1), dayKey: key(day1), now: day1)?.fingerprint == "aa")
        schedule.hideFriend("aa", now: day1)
        #expect(schedule.chooseFriend(from: nudges(both, on: day1), dayKey: key(day1), now: day1) == nil,
                "a put-away card still counts as today's friend card")
        #expect(schedule.isFriendHidden("aa", now: later(29)))
        #expect(!schedule.isFriendHidden("bb", now: later(1)), "only that friend")
        #expect(schedule.chooseFriend(from: nudges(both, on: later(1)), dayKey: key(later(1)), now: later(1))?.fingerprint == "bb")
        #expect(!schedule.isFriendHidden("aa", now: later(31)))
    }

    @Test func friendCardsShareTheTwoADayLimit() {
        var full = AmbientReminderSchedule()
        _ = full.choose(from: [.forgottenRecipe, .forgottenCalm], dayKey: key(day1), now: day1)
        #expect(full.chooseFriend(from: nudges([friend("aa", low: true)], on: day1), dayKey: key(day1), now: day1) == nil)

        var schedule = AmbientReminderSchedule()
        #expect(schedule.chooseFriend(from: nudges([friend("aa", low: true)], on: day1), dayKey: key(day1), now: day1) != nil)
        #expect(schedule.choose(from: [.forgottenRecipe, .forgottenCalm], dayKey: key(day1), now: day1) == [.forgottenRecipe],
                "the friend card took one of today's two")
        #expect(schedule.chooseFriend(from: nudges([friend("aa", low: true)], on: day1), dayKey: key(day1), now: day1)?.fingerprint == "aa",
                "the same day keeps its friend card")
    }

    @Test func oneFriendCardADay() {
        var schedule = AmbientReminderSchedule()
        let both = [friend("aa", low: true, metDaysAgo: 2), friend("bb", low: true, metDaysAgo: 5)]
        #expect(schedule.chooseFriend(from: nudges(both, on: day1), dayKey: key(day1), now: day1)?.fingerprint == "aa")
        #expect(schedule.shownToday.count == 1)
    }

    @Test func expiredFriendEntriesAreDropped() {
        var schedule = AmbientReminderSchedule()
        _ = schedule.chooseFriend(from: nudges([friend("aa", low: true)], on: day1), dayKey: key(day1), now: day1)
        schedule.hideFriend("aa", now: day1)
        schedule.pruneFriendTokens(now: later(31))
        #expect(!schedule.hiddenUntil.keys.contains { $0.contains("aa") })
        #expect(!schedule.lastShown.keys.contains { $0.contains("aa") })
    }

    @Test func theCopyNeverMentionsHowAnyoneFeels() {
        let words: Set<String> = ["mood", "moods", "vibe", "vibes", "low", "sad", "struggling", "down", "upset", "tired", "okay", "bad"]
        var lines: [String] = []
        for draft in AmbientFriendNudgeDraft.allCases {
            lines.append(AmbientReminderCopy.friendTitle(draft, name: "Ana", companion: "Sprout"))
            lines.append(AmbientReminderCopy.friendBody(draft, name: "Ana", companion: "Sprout"))
        }
        lines += [AmbientReminderCopy.friendSend, AmbientReminderCopy.friendSentTitle, AmbientReminderCopy.friendSentBody(name: "Ana")]
        for line in lines {
            let tokens = line.lowercased().split { !$0.isLetter }.map(String.init)
            #expect(Set(tokens).isDisjoint(with: words), "\(line)")
        }
        #expect(AmbientReminderCopy.friendTitle(.c, name: "Ana", companion: "Pip") == "Pip has an idea", "the companion's own name")
        #expect(AmbientReminderCopy.friendBody(.c, name: "Ana", companion: "Pip") == "Pip thinks Ana would love a heart today.")
    }

    @MainActor @Test func heartOnItsWayOnlyWhenTheQueueAcceptedIt() {
        let refused: [HeartDropService.QueueOutcome] = [.rateLimited, .backlogFull, .dailyLimitReached, .disabled, .storageUnavailable, .failed]
        #expect(AmbientCardsView.friendNudgeOutcome(for: .queued, firstName: "Ana") == .sent)
        for outcome in refused {
            let shown = AmbientCardsView.friendNudgeOutcome(for: outcome, firstName: "Ana")
            #expect(shown == .refused(AwayHeartsCopy.queueLine(for: outcome, firstName: "Ana", problem: nil)), "\(outcome)")
        }
    }

    @Test func theSwitchHidesTheFriendCardsToo() throws {
        let cards = try RepoRoot.source("App/Fernlet/AmbientCards.swift")
        let start = try #require(cards.range(of: "private func chooseFriendNudge"))
        let body = cards[start.lowerBound...].prefix(400)
        #expect(body.contains("guard store.settings.gentleRemindersEnabled else { return nil }"))
    }
}

// MARK: - CAP-2: never the sealed stores

struct AmbientRemindersSealedBoundaryTests {
    /// The files the gentle reminders are made of.
    static let files = [
        "App/Fernlet/AmbientReminders.swift", "App/Fernlet/AmbientReminderFinder.swift",
        "App/Fernlet/AmbientReminderMemory.swift", "App/Fernlet/AmbientReminderCopy.swift",
        "App/Fernlet/AmbientFriendNudges.swift", "App/Fernlet/AmbientPlaces.swift",
        "App/Fernlet/AmbientShortDays.swift", readerFile
    ]

    /// Names of sealed or Private-hub stores and reads that must never appear in their code. Since P1-A the
    /// World map's own names are on it too, so the one exception below is the only way in.
    static let forbidden = [
        "journal", "lookBackJournal", "worry", "cycle", "period", "intimacy", "hubContentKey", "hubKey",
        "worldPlace", "PlaceLog", "decrypt", "sealed", "mood", "emotion",
        "WorldMapStore", "worldMapVault", "Vault", "PlaceRecord", "PlaceDeviceState", "PlaceStop", "KnownPlace",
        "EatingPlace", "placeID"
    ]

    /// CAP-2's one named exception (owner's P1-A, 2026-11-27): Home's place summary, read only through this
    /// type, and only from ``readerFile``.
    static let allowedReader = "PlaceVisitSummaryReader"
    /// The one file that may use ``allowedReader``.
    static let readerFile = "App/Fernlet/FernletStore+AmbientPlaces.swift"
    /// Exactly what ``readerFile`` may write to reach the reader; everything else in it is scanned as usual.
    static let readerFragments = ["import WorldMapStore", "PlaceVisitSummaryReader(vault: worldMapVault)"]

    /// `source` without its comment lines (the comments say what is never read, by name).
    static func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .map { $0.components(separatedBy: " //").first ?? String($0) }
            .joined(separator: "\n")
    }

    /// The scanned code of every reminder file and Home's choosing code, by path (the reader file without
    /// its allowed fragments).
    static func scannedCode() throws -> [String: String] {
        var scanned: [String: String] = [:]
        for file in files {
            var source = code(try RepoRoot.source(file))
            if file == readerFile {
                for fragment in readerFragments { source = source.replacingOccurrences(of: fragment, with: "") }
            }
            scanned[file] = source
        }
        let cards = try RepoRoot.source("App/Fernlet/AmbientCards.swift")
        let start = try #require(cards.range(of: "private func chooseReminders"))
        let end = try #require(cards.range(of: "// MARK: - Weather-aware recovery"))
        scanned["AmbientCards.chooseReminders"] = code(String(cards[start.lowerBound..<end.lowerBound]))
        return scanned
    }

    @Test func theRemindersNeverNameASealedStore() throws {
        let scanned = try Self.scannedCode()
        #expect(scanned.count == Self.files.count + 1, "a reminder file moved")
        for (file, source) in scanned {
            let lowered = source.lowercased()
            for name in Self.forbidden {
                #expect(!lowered.contains(name.lowercased()), "\(file) names \(name)")
            }
        }
    }

    /// The named exception is exactly one reader in exactly one file: no other reminder file names it,
    /// and the reader file uses each allowed fragment once.
    @Test func onlyTheNamedReaderReachesThePlaceSummary() throws {
        let scanned = try Self.scannedCode()
        for (file, source) in scanned {
            #expect(!source.contains(Self.allowedReader), "\(file) names \(Self.allowedReader) outside its one allowed use")
        }
        let reader = Self.code(try RepoRoot.source(Self.readerFile))
        for fragment in Self.readerFragments {
            #expect(reader.components(separatedBy: fragment).count == 2, "the reader file uses \(fragment) once")
        }
    }

    /// The reader itself can read only the summary: no hub key, no other file, and it never writes.
    @Test func theNamedReaderReadsOnlyTheSummary() throws {
        let source = try RepoRoot.source("FernletKit/Sources/WorldMapStore/PlaceVisitSummary.swift")
        let start = try #require(source.range(of: "public final class PlaceVisitSummaryReader"))
        let reader = Self.code(String(source[start.lowerBound...]))
        #expect(reader.contains("WorldMapVault.File.placeSummary"))
        for banned in ["sealedWith", "hubKey", ".places)", ".placesDevice", ".placeMarks", "write(", "remove("] {
            #expect(!reader.contains(banned), "the reader uses \(banned)")
        }
        let file = try RepoRoot.source("FernletKit/Sources/WorldMapStore/WorldMapVault.swift")
        #expect(file.contains("placeSummary = File(name: \"places-summary.bin\""))
        #expect(file.contains("role: .buffer, context: Data(\"placeSummary\".utf8)"), "the summary is under the buffer key, its own context")
    }
}
